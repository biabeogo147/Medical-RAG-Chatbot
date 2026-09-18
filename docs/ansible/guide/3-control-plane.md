# Ansible guide — Part 3: The control plane: kubeadm init and join (steps 6–7)

[← Part 2](2-runtime.md) · [Index](../guide.md) · [Part 4 →](4-network-and-kubectl.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 2 done on all three nodes. If the cluster stack was destroyed since, run `make infra` and `make cluster` first.

**Done when:** step 7 — three control planes, and etcd lists three members.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 6 — The `kubeadm_init` role

**Goal:** the first control plane, reachable through the internal load balancer.

Create `infra/ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2`:
```yaml
# Written to /etc/kubernetes/kubeadm-config.yaml on the first node. v1beta4 is the configuration API
# of Kubernetes 1.36.
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v{{ kubernetes_version }}

# The internal load balancer, not this machine. Every kubelet, every join and every kubectl talks to
# this name, so a control-plane node can be replaced without anything being reconfigured.
controlPlaneEndpoint: "{{ control_plane_endpoint }}:6443"

apiServer:
  certSANs:
    - "{{ control_plane_endpoint }}"
    # kubectl on the workstation reaches the API through an SSM port-forward, so the certificate has
    # to be valid for the local end of that tunnel as well. kubeadm does not add these by itself.
    - "127.0.0.1"
    - "localhost"

networking:
  podSubnet: "{{ pod_cidr }}"
  serviceSubnet: "{{ service_cidr }}"
```

Create `infra/ansible/roles/kubeadm_init/tasks/main.yml`:
```yaml
---
# Creates the cluster on the first node. Runs once; every later run finds admin.conf and skips.

- name: Check whether this node is already a control plane
  ansible.builtin.stat:
    path: /etc/kubernetes/admin.conf
  register: kubeadm_admin_conf

- name: Write the kubeadm configuration
  ansible.builtin.template:
    src: kubeadm-config.yaml.j2
    dest: /etc/kubernetes/kubeadm-config.yaml
    mode: '0600'

- name: Initialise the control plane
  # --upload-certs stores the control-plane certificates in a Secret for two hours, which is how the
  # other two nodes get them without any file being copied around.
  ansible.builtin.command: kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
  when: not kubeadm_admin_conf.stat.exists
  register: kubeadm_init_result
  changed_when: kubeadm_init_result.rc == 0

- name: Give root a kubeconfig
  ansible.builtin.file:
    path: /root/.kube
    state: directory
    mode: '0700'

- name: Copy admin.conf into place
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: /root/.kube/config
    remote_src: true
    mode: '0600'

- name: Wait until the API server answers through the load balancer
  # This proves three things at once: the API is up, the NLB has marked this node healthy, and the
  # node can reach the NLB. /readyz is readable without credentials.
  ansible.builtin.uri:
    url: "https://{{ control_plane_endpoint }}:6443/readyz"
    validate_certs: false
    status_code: 200
  register: kubeadm_readyz
  retries: 30
  delay: 10
  until: kubeadm_readyz.status | default(0) == 200
  changed_when: false
```

Add a new play to `site.yml`, after *Prepare every node*:
```yaml
- name: Create the cluster on the first node
  hosts: first_node
  become: true
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  roles:
    - kubeadm_init
```

**Why:**

- **`controlPlaneEndpoint` is the load balancer, never a node address.** It is written into every
  kubeconfig and into each kubelet's configuration. Pointing it at one machine would make that
  machine impossible to replace.
- **`certSANs` includes `127.0.0.1`.** In [step 9](4-network-and-kubectl.md#step-9--kubectl-on-the-workstation) kubectl reaches the API through an SSM tunnel whose
  local end is `https://127.0.0.1:6443`. kubeadm does not add that name by itself, and a certificate
  without it would force `--insecure-skip-tls-verify` on every command from then on.
- **`--upload-certs`** puts the control-plane certificates into a Secret that expires after two
  hours, which is how the other two nodes get them in step 7 without any file being copied.

**Run:**
```bash
make cluster
```
`kubeadm init` pulls the control-plane images through the NAT gateway before it starts them, so this
is the slowest task of the run.

**Verify:**
```bash
cd ~/Medical-RAG-Chatbot
make kubectl CMD="get nodes"
```
One node, `NotReady` — correct, because there is no pod network yet. And the load balancer:
```bash
TG=$(aws elbv2 describe-target-groups --names medical-rag-api --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].TargetHealth.State'
```
One target `healthy`, two `unhealthy` — the other two nodes have not joined yet.

**Commit:** `git add infra/ansible && git commit -m "Add the kubeadm_init role"`

---

## Step 7 — The `kubeadm_join` role

**Goal:** three control planes and a three-member etcd.

Create `infra/ansible/roles/kubeadm_join/tasks/main.yml`:
```yaml
---
# Adds the other two nodes as control planes. The play runs them one at a time (serial: 1), because
# each join adds an etcd member and etcd only tolerates one membership change at a time.

- name: Check whether this node is already a working control plane
  # kubelet.conf appears half-way through the join; the etcd manifest only once the machine has been
  # added to the etcd cluster. Using the later marker means a join that died in between is retried,
  # instead of being skipped for ever on a node that is not really a control plane.
  ansible.builtin.stat:
    path: /etc/kubernetes/manifests/etcd.yaml
  register: kubeadm_joined

- name: Create a short-lived join token on the first node
  # Made per joining node and valid for 15 minutes, so nothing long-lived is left behind.
  ansible.builtin.command: kubeadm token create --ttl 15m --print-join-command
  delegate_to: "{{ first_control_plane }}"
  register: kubeadm_join_command
  when: not kubeadm_joined.stat.exists
  changed_when: false
  no_log: true

- name: Re-upload the control-plane certificates and read the certificate key
  # The Secret from `init --upload-certs` expires after two hours, so it is refreshed here. The last
  # line of the output is the key that decrypts it.
  ansible.builtin.command: kubeadm init phase upload-certs --upload-certs
  delegate_to: "{{ first_control_plane }}"
  register: kubeadm_certificate_key
  when: not kubeadm_joined.stat.exists
  changed_when: false
  no_log: true

- name: Stage the join command in a root-only file
  # Keeping the token and the certificate key off the command line means the join task itself does
  # not need no_log, so when a join fails you can actually read why.
  ansible.builtin.copy:
    content: |
      {{ kubeadm_join_command.stdout }} --control-plane --certificate-key {{ kubeadm_certificate_key.stdout_lines[-1] | trim }}
    dest: /root/kubeadm-join.sh
    mode: '0700'
  when: not kubeadm_joined.stat.exists
  no_log: true

- name: Join as an additional control plane
  ansible.builtin.command: /bin/bash /root/kubeadm-join.sh
  when: not kubeadm_joined.stat.exists
  register: kubeadm_join_result
  changed_when: kubeadm_join_result.rc == 0

- name: Remove the staged join command
  ansible.builtin.file:
    path: /root/kubeadm-join.sh
    state: absent

- name: Give root a kubeconfig here too
  ansible.builtin.file:
    path: /root/.kube
    state: directory
    mode: '0700'

- name: Copy admin.conf into place
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: /root/.kube/config
    remote_src: true
    mode: '0600'
```

Add a new play to `site.yml`, after the previous one:
```yaml
- name: Add the other control planes, one at a time
  hosts: other_nodes
  become: true
  # etcd accepts one membership change at a time; two joins at once can lose quorum.
  serial: 1
  roles:
    - kubeadm_join
```

**Why:**

- **The token is created per joining node and lives 15 minutes.** Nothing long-lived is left behind,
  and because the task is skipped once the node has joined, a second playbook run creates no token
  at all.
- **`no_log: true`** on the three tasks that handle the token and the certificate key. Without it,
  both would be printed in full and end up in the terminal scrollback and in any log.
- **Nothing is written to the repo.** The join command exists only as a registered fact, for the few
  seconds between the two tasks.

**Run:**
```bash
make cluster
```

**Verify:**
```bash
make kubectl CMD="get nodes"
make kubectl CMD="get pods -n kube-system -o wide"
```
Three nodes, all `NotReady`, and one `etcd-…`, `kube-apiserver-…`, `kube-controller-manager-…` and
`kube-scheduler-…` pod per node, plus a `kube-proxy-…` on each. Then check etcd itself:
```bash
make kubectl CMD="exec -n kube-system etcd-medical-rag-node-1 -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list -w table"
```
Three members, all started.

**Commit:** `git add infra/ansible && git commit -m "Add the kubeadm_join role"`

---

[← Part 2](2-runtime.md) · [Index](../guide.md) · [Part 4 →](4-network-and-kubectl.md) · [Troubleshooting](troubleshooting.md)
