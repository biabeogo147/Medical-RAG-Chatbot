# Ansible guide — Part 4: Pod network and kubectl on the workstation (steps 8–9)

[← Part 3](3-control-plane.md) · [Index](../guide.md) · [Part 5 →](5-prove-and-extend.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 3 done: three control planes joined.

**Done when:** step 9 — three nodes `Ready`, a test pod runs, and `kubectl get nodes` works on the workstation through `make tunnel`.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 8 — The `cni_calico` and `untaint_control_plane` roles

**Goal:** all three nodes `Ready`, and workloads allowed on them.

Create `infra/ansible/roles/cni_calico/templates/installation.yaml.j2`:
```yaml
# The only custom resource the operator needs. Calico's own sample file also creates an API server,
# a flow aggregator and a web UI; on 8 GB nodes that memory is better spent on workloads.
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: "{{ pod_cidr }}"
        # VXLAN, not the operator default IPIP: the three nodes sit in three different subnets,
        # and VXLAN crosses them unchanged over UDP 4789.
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
```

Create `infra/ansible/roles/cni_calico/tasks/main.yml`:
```yaml
---
# The pod network. Until a CNI plugin is installed every node stays NotReady.
# All tasks run on the first node, using the kubeconfig kubeadm wrote there.

- name: Install the Calico operator CRDs
  # --server-side is required, not a preference: the CRD manifest is about 3 MB, and a client-side
  # apply stores the whole file in an annotation, which the API server rejects as too long.
  ansible.builtin.command: >-
    kubectl apply --server-side --force-conflicts
    -f https://raw.githubusercontent.com/projectcalico/calico/{{ calico_version }}/manifests/operator-crds.yaml
  # A server-side apply prints the same output every run, so there is nothing to detect a change
  # from. The Installation resource below is the one that carries the state.
  changed_when: false

- name: Install the Calico operator
  ansible.builtin.command: >-
    kubectl apply --server-side --force-conflicts
    -f https://raw.githubusercontent.com/projectcalico/calico/{{ calico_version }}/manifests/tigera-operator.yaml
  changed_when: false

- name: Write the Calico installation resource
  ansible.builtin.template:
    src: installation.yaml.j2
    dest: /etc/kubernetes/calico-installation.yaml
    mode: '0644'

- name: Apply it
  # Server-side as well, and for a second reason: the operator writes its own defaults back into
  # this resource, and a client-side apply would overwrite them on every run and always report a
  # change.
  ansible.builtin.command: >-
    kubectl apply --server-side --force-conflicts --field-manager=ansible
    -f /etc/kubernetes/calico-installation.yaml
  changed_when: false

- name: Wait for the operator to start
  ansible.builtin.command: kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s
  changed_when: false

- name: Wait until the operator has created the calico-node daemonset
  # `kubectl wait` fails immediately when the object does not exist yet, and right after the
  # Installation is applied neither the namespace nor the daemonset exists. So poll for it.
  ansible.builtin.command: kubectl -n calico-system get daemonset calico-node
  register: calico_daemonset
  until: calico_daemonset.rc == 0
  retries: 60
  delay: 5
  failed_when: false
  changed_when: false

- name: Say something useful if it never appeared
  ansible.builtin.assert:
    that: calico_daemonset.rc == 0
    fail_msg: >-
      The operator did not create calico-system/calico-node. Look at
      `kubectl -n tigera-operator logs deploy/tigera-operator`.

- name: Wait until Calico is running on every node
  ansible.builtin.command: kubectl -n calico-system rollout status ds/calico-node --timeout=600s
  changed_when: false

- name: Wait until every node reports Ready
  ansible.builtin.command: kubectl wait --for=condition=Ready nodes --all --timeout=300s
  changed_when: false
```

Create `infra/ansible/roles/untaint_control_plane/tasks/main.yml`:
```yaml
---
# kubeadm taints control-plane nodes so that no workload is scheduled on them. This cluster has three
# machines and no separate workers, so the taint is removed and all three run workloads.

- name: Allow workloads on the control-plane nodes
  ansible.builtin.command: kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
  register: untaint
  # Once the taint is gone kubectl exits non-zero with "taint ... not found", which is the state we
  # want, not an error.
  failed_when: untaint.rc != 0 and 'not found' not in untaint.stderr
  changed_when: "'untainted' in untaint.stdout"
```

Add a new play to `site.yml`:
```yaml
- name: Install the pod network and open the nodes for scheduling
  hosts: first_node
  become: true
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  roles:
    - cni_calico
    - untaint_control_plane
```

**Why:**

- **192.168.0.0/16 for pods.** It must not overlap the cluster VPC (10.10.0.0/16), the workstation
  VPC (10.20.0.0/24) or the Service range (10.96.0.0/12). An overlap shows up as traffic that
  disappears, not as an error.
- **VXLAN, not the operator's default IPIP.** The three nodes are in three different subnets, one per
  availability zone, and VXLAN crosses them unchanged over UDP 4789.
- **Removing the control-plane taint** is what makes this a 3-machine cluster rather than a
  3-machine control plane with nowhere to run anything.

**Run:**
```bash
make cluster
```

**Verify:**
```bash
make kubectl CMD="get nodes -o wide"
make kubectl CMD="get pods -n calico-system"
```
Three nodes `Ready`, running `v1.36.4`. Then prove that a pod actually schedules and that its
network works:
```bash
make kubectl CMD="run netcheck --image=busybox:1.36 --restart=Never --command -- sleep 300"
make kubectl CMD="wait --for=condition=Ready pod/netcheck --timeout=180s"
make kubectl CMD="get pod netcheck -o wide"
make kubectl CMD="exec netcheck -- nslookup kubernetes.default.svc.cluster.local"
make kubectl CMD="delete pod netcheck"
```
`get pod` must show `Running` on one of the three nodes, and `nslookup` must answer from
`10.96.0.10` (CoreDNS) with `Address: 10.96.0.1`, the API server's Service address inside
`10.96.0.0/12`.

Use the full name. busybox's `nslookup` ignores the `search` list in the pod's `/etc/resolv.conf`,
so the short `kubernetes.default` comes back `NXDOMAIN` even when DNS works. An `NXDOMAIN` still
proves the pod reached CoreDNS; a broken DNS path shows `connection timed out` instead.

**Commit:** `git add infra/ansible && git commit -m "Add the Calico and untaint roles"`

---

## Step 9 — kubectl on the workstation

**Goal:** run kubectl on the workstation instead of through a node.

Add the last play to `site.yml`:
```yaml
- name: Put a kubeconfig on the workstation
  hosts: first_node
  become: true
  tasks:
    - name: Read admin.conf
      ansible.builtin.slurp:
        src: /etc/kubernetes/admin.conf
      register: admin_conf

    - name: Make sure ~/.kube exists on the workstation
      # `copy` does not create the parent directory; it fails with "Destination directory does not
      # exist".
      ansible.builtin.file:
        path: "{{ lookup('env', 'HOME') }}/.kube"
        state: directory
        mode: '0700'
      delegate_to: localhost
      become: false

    - name: Write it to ~/.kube/config, pointing at the local end of the SSM tunnel
      # `make tunnel` forwards 127.0.0.1:6443 to the internal load balancer. The API server
      # certificate lists 127.0.0.1 as well, so no TLS verification has to be switched off.
      ansible.builtin.copy:
        content: "{{ admin_conf.content | b64decode | regex_replace('server: https://.*', 'server: https://127.0.0.1:6443') }}"
        dest: "{{ lookup('env', 'HOME') }}/.kube/config"
        mode: '0600'
      delegate_to: localhost
      become: false
```

Your `site.yml` is now complete. One change besides the new play: the first play's assert becomes stricter.
`is defined` passes an empty value, which is what a failed `terraform output` gives make, so it checks
for a non-empty value instead:
```yaml
---
# Turns three bare Ubuntu machines into an HA Kubernetes cluster. Run it with `make cluster`, which
# supplies control_plane_endpoint and aws_account_id from Terraform.
#
# It is safe to run again at any time: every role checks the state of the machine first, so a second
# run reports changed=0.

- name: Check that the variables the Makefile passes are present
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Fail early rather than half-way through a cluster build
      ansible.builtin.assert:
        that:
          # Not `is defined`: a failed `terraform output` leaves make with an empty value, which
          # would be defined, empty, and only noticed minutes later inside `kubeadm init`.
          - control_plane_endpoint | default('') | length > 0
          - aws_account_id | default('') | length > 0
        fail_msg: >-
          Run this with `make cluster`, or pass -e control_plane_endpoint=<api NLB DNS>
          -e aws_account_id=<account id>.

- name: Prepare every node
  hosts: nodes
  become: true
  roles:
    - common
    - containerd
    - kubernetes_packages
    - ecr_credential_provider

- name: Create the cluster on the first node
  hosts: first_node
  become: true
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  roles:
    - kubeadm_init

- name: Add the other control planes, one at a time
  hosts: other_nodes
  become: true
  # etcd accepts one membership change at a time; two joins at once can lose quorum.
  serial: 1
  roles:
    - kubeadm_join

- name: Install the pod network and open the nodes for scheduling
  hosts: first_node
  become: true
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  roles:
    - cni_calico
    - untaint_control_plane

- name: Put a kubeconfig on the workstation
  hosts: first_node
  become: true
  tasks:
    - name: Read admin.conf
      ansible.builtin.slurp:
        src: /etc/kubernetes/admin.conf
      register: admin_conf

    - name: Make sure ~/.kube exists on the workstation
      # `copy` does not create the parent directory; it fails with "Destination directory does not
      # exist".
      ansible.builtin.file:
        path: "{{ lookup('env', 'HOME') }}/.kube"
        state: directory
        mode: '0700'
      delegate_to: localhost
      become: false

    - name: Write it to ~/.kube/config, pointing at the local end of the SSM tunnel
      # `make tunnel` forwards 127.0.0.1:6443 to the internal load balancer. The API server
      # certificate lists 127.0.0.1 as well, so no TLS verification has to be switched off.
      ansible.builtin.copy:
        content: "{{ admin_conf.content | b64decode | regex_replace('server: https://.*', 'server: https://127.0.0.1:6443') }}"
        dest: "{{ lookup('env', 'HOME') }}/.kube/config"
        mode: '0600'
      delegate_to: localhost
      become: false
```

**Why:**

- **The API server has no public address**, and the workstation is in a different VPC. Session
  Manager can forward a local port to any host the target instance can reach, so the tunnel goes
  through node 1 to the internal load balancer.
- **`server:` is rewritten to `https://127.0.0.1:6443`**, the local end of that tunnel. The
  certificate lists that name because of the `certSANs` entry in [step 6](3-control-plane.md#step-6--the-kubeadm_init-role), so nothing has to skip TLS
  verification.

**Run:**
```bash
make cluster
make tunnel          # keep this window open; Ctrl-C closes the tunnel
```

**Verify:** open a **second** Session Manager window and run:
```bash
sudo su - ubuntu
cd ~/Medical-RAG-Chatbot
kubectl get nodes
kubectl get pods -A
```
Three `Ready` nodes, without `--kubeconfig` and without a warning about the certificate.

**Commit:** `git add infra/ansible && git commit -m "Write the kubeconfig to the workstation"`

---

[← Part 3](3-control-plane.md) · [Index](../guide.md) · [Part 5 →](5-prove-and-extend.md) · [Troubleshooting](troubleshooting.md)
