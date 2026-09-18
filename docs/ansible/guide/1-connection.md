# Ansible guide — Part 1: Inventory, SSM connection and the first role (steps 1–2)

[Index](../guide.md) · [Part 2 →](2-runtime.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** [Terraform guide](../../terraform/guide.md) steps 1–15 done, `make infra` applied, and the three nodes `Online` in SSM.

**Done when:** steps 1–2 — `make ping` answers `SUCCESS` from 3 hosts, and a second `make cluster` reports `changed=0`.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 1 — Inventory, connection and the make targets

**Goal:** Ansible finds the three nodes by tag and can run a command on each of them over SSM.

Create `infra/ansible/ansible.cfg`:
```ini
# Ansible reads this file when a command is run from infra/ansible/, which is what every make target
# does. Nothing here is a secret: the inventory is built live from the AWS API.
[defaults]
inventory          = inventory/aws_ec2.yml
roles_path         = roles
interpreter_python = /usr/bin/python3

# One fork per node: the three nodes are configured in parallel.
forks = 3

# Skipped tasks are normal here (a role that is already applied skips almost everything), so hide
# them and keep the output readable.
display_skipped_hosts = False
retry_files_enabled   = False
```

Create `infra/ansible/requirements.yml`:
```yaml
---
# The only collection this project needs. It provides both plugins used here:
#   - amazon.aws.aws_ec2  : builds the inventory from the EC2 API
#   - amazon.aws.aws_ssm  : runs tasks through Session Manager instead of SSH
#
# Pinned to 10.3.2 on purpose. Version 11 requires ansible-core >= 2.17, and Ubuntu 24.04 ships
# ansible-core 2.16, which is what the ops workstation runs.
collections:
  - name: amazon.aws
    version: "10.3.2"
```

Create `infra/ansible/inventory/aws_ec2.yml`. **The file name must end in `aws_ec2.yml`** or the
plugin refuses to load it:
```yaml
---
# A dynamic inventory: the host list comes from the EC2 API every run, so no IP address and no
# instance ID is ever written down. Terraform tags the nodes, Ansible finds them by that tag.
plugin: amazon.aws.aws_ec2

# Region and tag must match infra/terraform/cluster/variables.tf.
regions:
  - ap-southeast-1

filters:
  tag:k8s-cluster: medical-rag
  instance-state-name: running

# Use the Name tag as the host name, so the output reads medical-rag-node-1 instead of i-0a1b2c3d.
hostnames:
  - tag:Name

compose:
  # The aws_ssm connection plugin addresses a machine by its instance ID, not by an address.
  ansible_aws_ssm_instance_id: instance_id
  # Not used to connect; it only makes the logs and the etcd checks easier to read.
  ansible_host: private_ip_address

# Static groups built from the Name tag. kubeadm has to start on exactly one machine, and these two
# groups say which one, without any task having to sort a list at run time.
groups:
  nodes: true
  first_node: "tags['Name'] is defined and tags['Name'].endswith('-node-1')"
  other_nodes: "tags['Name'] is defined and not tags['Name'].endswith('-node-1')"
```

Create `infra/ansible/inventory/group_vars/all.yml`:
```yaml
---
# Settings that every play shares. Pinned versions live here so an upgrade is a one-line change.

project: medical-rag
aws_region: ap-southeast-1

# --- pinned versions -------------------------------------------------------------------------------
# Kubernetes stays on 1.36 until the GitOps phase pins a Rancher chart that accepts a newer minor.
# The apt version string has its own suffix and must match the minor exactly.
kubernetes_minor: "v1.36"
kubernetes_version: "1.36.4"
kubernetes_apt_version: "1.36.4-1.1"
# crictl, the command-line client for the container runtime. It is released per Kubernetes minor, so
# its version follows the minor, not the patch.
cri_tools_apt_version: "1.36.0-1.1"

# containerd.io from the Docker repository: newer than the one in Ubuntu and with a version string
# that can be pinned.
containerd_version: "2.3.5-1~ubuntu.24.04~noble"

# Calico, installed through its operator.
calico_version: "v3.32.2"

# The kubelet plugin that turns the node's IAM role into an ECR login, so no imagePullSecret is
# needed anywhere. Upstream publishes binaries for only a limited range of Kubernetes releases.
ecr_credential_provider_version: "v1.37.0"
ecr_credential_provider_url: "https://artifacts.k8s.io/binaries/cloud-provider-aws/{{ ecr_credential_provider_version }}/linux/amd64/ecr-credential-provider-linux-amd64"
ecr_credential_provider_dir: /etc/kubernetes/image-credential-provider

# --- networking ------------------------------------------------------------------------------------
# Neither range may overlap the cluster VPC (10.10.0.0/16) or the workstation VPC (10.20.0.0/24).
pod_cidr: "192.168.0.0/16"
service_cidr: "10.96.0.0/12"

# The machine kubeadm runs `init` on; the other two join it.
first_control_plane: "{{ groups['first_node'] | first }}"
```

Create `infra/ansible/inventory/group_vars/nodes.yml`:
```yaml
---
# How Ansible reaches the nodes. This file applies to the `nodes` group only, never to localhost:
# putting it in all.yml would send the final "copy the kubeconfig here" task through SSM as well.

# No SSH. Each task travels through a Session Manager session, and the module files it needs are
# handed over as a presigned S3 URL that the node downloads with curl.
ansible_connection: amazon.aws.aws_ssm
ansible_aws_ssm_region: "{{ aws_region }}"

# The transfer bucket from the cluster stack. It has no versioning and expires objects after a day,
# so a module file that carried a secret cannot survive in an old version. aws_account_id comes from
# the Makefile.
ansible_aws_ssm_bucket_name: "{{ project }}-ssm-transfer-{{ aws_account_id }}"

ansible_python_interpreter: /usr/bin/python3
```

Append to the `Makefile` at the repo root. **Recipe lines start with a tab, not spaces:**
```makefile
# --- Ansible: turn the three nodes into a Kubernetes cluster -----------------------------------
ANSIBLE_DIR  := infra/ansible
# aws_account_id can only come from here. project and aws_region are passed too, so the Makefile and
# group_vars/all.yml can never disagree about which cluster is being built.
ANSIBLE_VARS := -e project=$(PROJECT) -e aws_region=$(REGION) -e aws_account_id=$(ACCOUNT_ID)

# Recursive (=, not :=), so these two only call AWS when a target below actually uses them.
API_ENDPOINT  = $(shell $(CLUSTER) output -raw api_nlb_dns)
NODE_1        = $(shell aws ec2 describe-instances --filters "Name=tag:Name,Values=$(PROJECT)-node-1" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)

.PHONY: ansible-deps ping cluster kubectl tunnel

# Install the pinned collection. Once per workstation.
ansible-deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

# Reach all three nodes through Session Manager. The first check after `make infra`.
ping:
	cd $(ANSIBLE_DIR) && ansible nodes -m ansible.builtin.ping $(ANSIBLE_VARS)

# Build the cluster. Safe to run again: a second run changes nothing. It depends on `init` so that
# `terraform output` below can never come back empty in a fresh working copy.
cluster: init
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(ANSIBLE_VARS) -e control_plane_endpoint=$(API_ENDPOINT)

# Run one kubectl command on the first node, for the checks made before the tunnel exists:
#   make kubectl CMD="get nodes"
kubectl:
	@test -n "$(CMD)" || { echo 'usage: make kubectl CMD="get nodes"'; exit 1; }
	cd $(ANSIBLE_DIR) && ansible first_node -b $(ANSIBLE_VARS) -m command -a "kubectl --kubeconfig /etc/kubernetes/admin.conf $(CMD)"

# Forward 127.0.0.1:6443 to the internal API load balancer through node 1, so kubectl works on the
# workstation. Keep the window open; Ctrl-C closes the tunnel.
tunnel:
	aws ssm start-session --target $(NODE_1) --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=$(API_ENDPOINT),portNumber=6443,localPortNumber=6443
```

**Why:**

- **No host list in Git.** The nodes are found through the EC2 API by the `k8s-cluster` tag
  Terraform wrote. Destroy and rebuild the cluster and the inventory follows, with new instance IDs
  and new addresses, without a single edit.
- **`first_node` and `other_nodes` are groups, not a sorted list.** `kubeadm init` has to run on
  exactly one machine. Deciding that in the inventory keeps the playbook free of logic that could
  pick a different machine on a later run.
- **The collection is pinned to 10.3.2.** Version 11 requires ansible-core 2.17, and Ubuntu 24.04 —
  the workstation — ships ansible-core 2.16.

**Run:**
```bash
cd ~/Medical-RAG-Chatbot
make ansible-deps                 # installs amazon.aws 10.3.2 into ~/.ansible/collections
make ping
```

**Verify:** `make ping` prints one block per node:
```
medical-rag-node-1 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```
And the inventory itself:
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible
ansible-inventory --graph -e aws_account_id=$(aws sts get-caller-identity --query Account --output text)
```
Expect the groups `nodes` (3 hosts), `first_node` (1) and `other_nodes` (2).

**Commit:** `git add infra/ansible Makefile && git commit -m "Add the Ansible inventory over SSM"`

---

## Step 2 — The `common` role and the first playbook

**Goal:** every node satisfies the conditions the kubelet checks at startup, and `site.yml` runs.

Create `infra/ansible/roles/common/tasks/main.yml`:
```yaml
---
# Everything a machine needs before the first Kubernetes package is installed.

- name: Install the tools the apt repositories need
  ansible.builtin.apt:
    name:
      - apt-transport-https
      - ca-certificates
      - curl
      - gpg
    state: present
    update_cache: true
    cache_valid_time: 3600
    # On a fresh boot unattended-upgrades holds the dpkg lock for a minute or two. Without this the
    # first run of the playbook fails on a locked lock file.
    lock_timeout: 300

# --- identity ----------------------------------------------------------------------------------
# kubeadm registers a node under the machine's hostname, and the AMI takes that from instance
# metadata: ip-10-10-1-23, which says nothing about which node it is. Use the Name tag that Ansible
# already found the machine by. This has to happen before kubeadm runs: renaming a node afterwards
# means deleting it from the cluster and joining it again.

- name: Name the machine after its Name tag
  ansible.builtin.hostname:
    name: "{{ inventory_hostname }}"

- name: Stop cloud-init restoring the old name on the next boot
  # Without this, a node that is stopped and started again comes back as ip-10-10-1-23 while its
  # Node object still says medical-rag-node-1.
  ansible.builtin.copy:
    dest: /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
    content: "preserve_hostname: true\n"
    mode: '0644'

- name: Make the new name resolvable
  # Otherwise every sudo call prints "unable to resolve host".
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '^127\.0\.1\.1\s'
    line: "127.0.1.1 {{ inventory_hostname }}"

# --- swap --------------------------------------------------------------------------------------
# The kubelet refuses to start while swap is on, because the scheduler's memory accounting assumes
# it is off. The Ubuntu AMI has none, so both tasks usually report ok.

- name: Turn swap off now
  ansible.builtin.command: swapoff -a
  when: ansible_swaptotal_mb | int > 0
  changed_when: true

- name: Keep swap off after a reboot
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#].*\sswap\s.*)$'
    replace: '# \1'

# --- kernel ------------------------------------------------------------------------------------

- name: Load the kernel modules the runtime and the pod network need at every boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/kubernetes.conf
    content: |
      overlay
      br_netfilter
    mode: '0644'

- name: Load them in the running kernel as well
  ansible.builtin.command: "modprobe {{ item }}"
  loop:
    - overlay
    - br_netfilter
  # modprobe is a no-op if the module is already loaded, so this never really changes anything.
  changed_when: false

- name: Let bridged traffic reach iptables, and allow forwarding between pods
  ansible.builtin.copy:
    dest: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
    mode: '0644'
  notify: Reload sysctl

# --- clock -------------------------------------------------------------------------------------

- name: Check that the clock is in sync
  # Certificates and etcd elections both break on a drifting clock. Checking the result rather than
  # a service name works whether the image syncs with chrony or with systemd-timesyncd, and a node
  # that has just booted is given a minute to get there.
  ansible.builtin.command: timedatectl show --property=NTPSynchronized --value
  register: ntp_synchronised
  until: ntp_synchronised.stdout == 'yes'
  retries: 12
  delay: 5
  changed_when: false

# Handlers normally wait until the end of the play. The next role starts a container runtime that
# reads these sysctls, so apply them now.
- name: Apply the pending handlers before the next role
  ansible.builtin.meta: flush_handlers
```

Create `infra/ansible/roles/common/handlers/main.yml`:
```yaml
---
- name: Reload sysctl
  ansible.builtin.command: sysctl --system
  changed_when: true
```

Create `infra/ansible/site.yml`. Steps 6 to 9 add one play each, and [step 9](4-network-and-kubectl.md#step-9--kubectl-on-the-workstation) shows the complete file:
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
          - control_plane_endpoint is defined
          - aws_account_id is defined
        fail_msg: >-
          Run this with `make cluster`, or pass -e control_plane_endpoint=<api NLB DNS>
          -e aws_account_id=<account id>.

- name: Prepare every node
  hosts: nodes
  become: true
  roles:
    - common
```

**Why:**

- **The assert play is the cheapest possible safety net.** `control_plane_endpoint` is the DNS name
  of the internal load balancer and it ends up inside the API server's certificate. Getting it wrong
  is only noticed several minutes later, in the middle of `kubeadm init`.
- **Swap off** is a kubelet requirement: its memory accounting assumes a pod that exceeds its limit
  is killed, not swapped out.
- **`br_netfilter` and the two sysctls** make bridged pod traffic pass through iptables, which is how
  Service rules are enforced. Without them pods start but Services silently do not work.
- **`flush_handlers` at the end** applies the sysctls immediately instead of at the end of the play,
  because the container runtime in the next role reads them at startup.
- **The machines are renamed after their `Name` tag.** kubeadm registers a node under its hostname,
  and the AMI takes that from instance metadata, so without this step `kubectl get nodes` lists
  `ip-10-10-1-23` and you have to look up which machine that is. It has to happen here, before
  kubeadm runs: renaming a node later means removing it from the cluster and joining it again.

**Run:**
```bash
make cluster
```

**Verify:** the recap line shows some changes on the first run. Run it a second time:
```bash
make cluster
```
Now every node must report `changed=0`. That is the property the whole phase depends on: the
playbook describes a state, so running it again does nothing.

**Commit:** `git add infra/ansible && git commit -m "Add the common role"`

---

[Index](../guide.md) · [Part 2 →](2-runtime.md) · [Troubleshooting](troubleshooting.md)
