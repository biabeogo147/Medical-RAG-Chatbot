# Ansible guide

A step-by-step guide that turns the three EC2 machines Terraform created into a highly available
Kubernetes cluster. Every file is commented, so the code you copy explains itself; the architecture
overview is in [`README.md`](README.md) next to this file. Follow the steps in order: each one ends
with a check, and the next step assumes it passed.

## How this guide works

**Start here when Terraform guide steps 1–15 are done:** `make infra` applied, and all three nodes
`Online` in SSM (step 13 of [`../terraform/guide.md`](../terraform/guide.md)). Part D of that guide is
needed before `make bootstrap`, not before Ansible.

**Where commands run.** No ops tool is installed on your laptop, and CloudShell is not used in this
phase.

| Where | What you do there |
|---|---|
| **Laptop:** editor + **Git Bash** | Write the files shown in each step, commit, push to GitHub |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager | `git pull`, `make`, checks |

**Who does what.** Each tool owns one layer and never reaches into another:

| Tool | Owns |
|---|---|
| Terraform | The AWS resources: network, machines, load balancers, IAM, buckets |
| **Ansible** | **What is installed and configured on those machines, and `kubeadm` itself** |
| Argo CD (next phase) | Everything running inside the cluster |

**No SSH.** Ansible reaches the nodes over Session Manager, exactly like your own shell does. There
is no key pair, no bastion, and no rule that lets anyone reach a node from outside the VPC. Ansible
uploads the files a task needs to the `ssm-transfer` bucket, and the node fetches them with `curl`
from a presigned URL.

**Every step has the same shape:** goal → files → why → run → verify → commit.

**Versions:** Kubernetes 1.36.4, containerd 2.3.5, Calico v3.32.2, ecr-credential-provider v1.37.0,
collection `amazon.aws` 10.3.2.
Region `ap-southeast-1`.

## Roadmap

| Step | Result | Done when |
|---|---|---|
| 1 | Inventory, SSM connection, make targets | `make ping` → 3 hosts `SUCCESS` |
| 2 | Role `common` + the first `site.yml` | `make cluster` twice → second run `changed=0` |
| 3 | Role `containerd` | `ctr version` answers, systemd cgroup driver confirmed |
| 4 | Role `kubernetes_packages` | `kubeadm version` → 1.36.4, packages held |
| 5 | Role `ecr_credential_provider` | Binary checksum verified, kubelet flags in place |
| 6 | Role `kubeadm_init` | Node 1 is a control plane, NLB target `healthy` |
| 7 | Role `kubeadm_join` | 3 control planes, etcd has 3 members |
| 8 | Roles `cni_calico` + `untaint_control_plane` | 3 nodes `Ready`, a test pod runs |
| 9 | Kubeconfig on the workstation, `make tunnel` | `kubectl get nodes` works from the workstation |
| 10 | Idempotency, HA drill, evidence | `changed=0`; the API survives losing a node |

## The loop for every step

1. **Laptop:** create or edit the files, commit, push.
2. **Workstation:** open Session Manager, then:
   ```bash
   sudo su - ubuntu
   tmux new -As k8s                       # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot && git pull
   ```
3. **Workstation:** run the `make` targets of the step, then its checks.

Session Manager disconnects after about 20 idle minutes and shell variables are lost with it, so
each check below sets what it needs.

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

Create `infra/ansible/site.yml`. Steps 6 to 9 add one play each:
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

## Step 3 — The `containerd` role

**Goal:** a container runtime the kubelet can talk to, using the same cgroup driver as the kubelet.

Create `infra/ansible/roles/containerd/tasks/main.yml`:
```yaml
---
# containerd is the container runtime the kubelet talks to. Docker is not involved on the nodes.

- name: Create the keyring directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: '0755'

- name: Add the Docker signing key
  # containerd.io is published in Docker's repository, which is newer than Ubuntu's containerd and
  # has version strings that can be pinned.
  ansible.builtin.get_url:
    url: https://download.docker.com/linux/ubuntu/gpg
    dest: /etc/apt/keyrings/docker.asc
    mode: '0644'

- name: Add the Docker repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc]
      https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable
    filename: docker
    state: present

- name: Install the pinned containerd
  ansible.builtin.apt:
    name: "containerd.io={{ containerd_version }}"
    state: present
    update_cache: true
    lock_timeout: 300
    allow_change_held_packages: true

- name: Hold containerd at that version
  # Without a hold, an unattended upgrade could restart the runtime under a running cluster.
  ansible.builtin.dpkg_selections:
    name: containerd.io
    selection: hold

- name: Read the default containerd configuration
  # The package ships a minimal config with the CRI plugin disabled, so the default has to be
  # generated. Doing it this way keeps the file correct for whatever containerd version is pinned,
  # instead of hard-coding option names that move between releases.
  ansible.builtin.command: containerd config default
  register: containerd_default
  changed_when: false

- name: Write /etc/containerd/config.toml with the systemd cgroup driver
  # The kubelet uses systemd as its cgroup driver. If the runtime uses a different one, pods are
  # accounted for in two different cgroup trees and the node goes unstable under memory pressure.
  ansible.builtin.copy:
    content: "{{ containerd_default.stdout | regex_replace('SystemdCgroup = false', 'SystemdCgroup = true') }}\n"
    dest: /etc/containerd/config.toml
    mode: '0644'
  notify: Restart containerd

- name: Start containerd at boot
  ansible.builtin.systemd:
    name: containerd
    enabled: true
    state: started

- name: Apply the restart before the kubelet is installed
  ansible.builtin.meta: flush_handlers

- name: Check the merged configuration selects the systemd cgroup driver
  # `config dump` merges the file with containerd's built-in defaults, so it catches an option that
  # moved to a new path between versions. It reads the file, not the running daemon; the restart
  # handler above is what makes the daemon use it, and a failed restart fails the play.
  ansible.builtin.shell: >
    set -o pipefail;
    containerd config dump | grep -q 'SystemdCgroup = true'
  args:
    executable: /bin/bash
  changed_when: false
```

Create `infra/ansible/roles/containerd/handlers/main.yml`:
```yaml
---
- name: Restart containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
    daemon_reload: true
```

Add `- containerd` to the `roles:` list of the *Prepare every node* play in `site.yml`, below
`- common`.

**Why:**

- **Docker is not installed on the nodes.** The kubelet talks to containerd through CRI; Docker
  would only add a daemon that nothing uses.
- **The config is generated, not written by hand.** containerd 2.x renamed most of the option paths
  it inherited from 1.x. Reading `containerd config default` and changing the one line that matters
  keeps this role correct across those renames, and writing the result with `copy` still makes the
  task idempotent — the file only changes when its content changes.

**Run:**
```bash
make cluster
```

**Verify:**
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible
VARS="-e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
ansible nodes -b $VARS -m command -a "ctr version"
```
Expect a client and a server version of 2.3.5 from all three nodes. The role's own last task already
fails the run if the runtime is not using the systemd cgroup driver.

**Commit:** `git add infra/ansible && git commit -m "Add the containerd role"`

---

## Step 4 — The `kubernetes_packages` role

**Goal:** kubelet, kubeadm and kubectl on every node, pinned to one patch release.

Create `infra/ansible/roles/kubernetes_packages/tasks/main.yml`:
```yaml
---
# kubelet, kubeadm and kubectl, pinned to one patch release and held there.

- name: Add the Kubernetes signing key
  # Every minor version has its own repository and its own key, so the URL contains the minor.
  ansible.builtin.get_url:
    url: "https://pkgs.k8s.io/core:/stable:/{{ kubernetes_minor }}/deb/Release.key"
    dest: /etc/apt/keyrings/kubernetes.asc
    mode: '0644'

- name: Add the Kubernetes repository
  ansible.builtin.apt_repository:
    repo: >-
      deb [signed-by=/etc/apt/keyrings/kubernetes.asc]
      https://pkgs.k8s.io/core:/stable:/{{ kubernetes_minor }}/deb/ /
    filename: kubernetes
    state: present

- name: Install the pinned kubelet, kubeadm and kubectl
  ansible.builtin.apt:
    name:
      - "kubelet={{ kubernetes_apt_version }}"
      - "kubeadm={{ kubernetes_apt_version }}"
      - "kubectl={{ kubernetes_apt_version }}"
    state: present
    update_cache: true
    lock_timeout: 300
    allow_change_held_packages: true

- name: Install crictl
  # Needed to inspect containers when the kubelet or a static pod fails to start. The kubeadm package
  # does not depend on it, so it has to be installed explicitly. Not held: it only talks to the
  # runtime and restarts nothing when it changes.
  ansible.builtin.apt:
    name: "cri-tools={{ cri_tools_apt_version }}"
    state: present
    lock_timeout: 300

- name: Hold the three packages
  # An unattended upgrade of the kubelet would restart every pod on the node, and an upgrade that
  # skips a minor version breaks the cluster. Upgrades are done deliberately, one node at a time,
  # by the upgrade.yml playbook of a later phase.
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop:
    - kubelet
    - kubeadm
    - kubectl

- name: Start the kubelet at boot
  # Not started here: until kubeadm has written its configuration the kubelet has nothing to do and
  # restarts in a loop. kubeadm starts it as part of `init` and `join`.
  ansible.builtin.systemd:
    name: kubelet
    enabled: true
```

Add `- kubernetes_packages` to the `roles:` list, below `- containerd`.

**Why:**

- **Compatibility-gated pin.** The cluster starts on 1.36.4 and changes minor only after the Rancher
  gate in [design §4.2.1](../selfmanaged-k8s-ops-design.md#421-rancher-gitops-contract-and-compatibility-gate) passes.
- **Held packages.** An unattended upgrade that restarted the kubelet would restart every pod on the
  node; one that crossed a minor version could also make Rancher unschedulable. Upgrades are done
  deliberately, one node at a time, after that gate.
- **`cri-tools` is installed explicitly.** The `kubeadm` package no longer depends on it, but
  `crictl` is the tool for looking at containers when the kubelet or a static pod does not start.
- **The kubelet is enabled but not started.** Until kubeadm writes its configuration the kubelet has
  nothing to do and restarts in a loop. That is normal, and `kubeadm init` fixes it in step 6.

**Run:**
```bash
make cluster
```

**Verify:**
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible
VARS="-e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
ansible nodes -b $VARS -m command -a "kubeadm version -o short"
ansible nodes -b $VARS -m shell -a "apt-mark showhold"
ansible nodes -b $VARS -m shell -a "crictl -r unix:///run/containerd/containerd.sock info | grep -m1 SystemdCgroup"
```
Expect `v1.36.4`; the held packages `containerd.io`, `kubeadm`, `kubectl` and `kubelet`; and
`"SystemdCgroup": true` from every node. That last check asks the running runtime rather than a
configuration file. `crictl` comes from the `cri-tools` package installed by this role, which is why
it could not be used in step 3.

**Commit:** `git add infra/ansible && git commit -m "Add the kubernetes_packages role"`

---

## Step 5 — The `ecr_credential_provider` role

**Goal:** install the plugin that lets the kubelet pull from ECR with the node's IAM role, so no
pull secret is ever needed.

Create `infra/ansible/roles/ecr_credential_provider/tasks/main.yml`:
```yaml
---
# Lets the kubelet pull from ECR using the node's IAM role. Without it every namespace would need an
# imagePullSecret holding a token that expires after 12 hours.

- name: Create the credential provider directory
  ansible.builtin.file:
    path: "{{ ecr_credential_provider_dir }}"
    state: directory
    mode: '0755'

- name: Download ecr-credential-provider and verify its published checksum
  # The checksum file sits next to the binary upstream; get_url fetches it and refuses to install a
  # binary that does not match.
  ansible.builtin.get_url:
    url: "{{ ecr_credential_provider_url }}"
    dest: "{{ ecr_credential_provider_dir }}/ecr-credential-provider"
    checksum: "sha256:{{ ecr_credential_provider_url }}.sha256"
    mode: '0755'

- name: Install the credential provider configuration
  # Tells the kubelet which registries to call the plugin for.
  ansible.builtin.copy:
    src: credential-provider-config.yaml
    dest: "{{ ecr_credential_provider_dir }}/config.yaml"
    mode: '0644'
  notify: Restart kubelet

- name: Point the kubelet at the plugin
  # kubeadm's own unit file reads /etc/default/kubelet, so these flags survive `init`, `join` and
  # every later upgrade.
  ansible.builtin.copy:
    dest: /etc/default/kubelet
    content: |
      KUBELET_EXTRA_ARGS=--image-credential-provider-bin-dir={{ ecr_credential_provider_dir }} --image-credential-provider-config={{ ecr_credential_provider_dir }}/config.yaml
    mode: '0644'
  notify: Restart kubelet
```

Create `infra/ansible/roles/ecr_credential_provider/files/credential-provider-config.yaml`:
```yaml
# Read by the kubelet. For an image whose name matches one of the patterns below, the kubelet runs
# the plugin, which asks ECR for a token using the instance role and caches it.
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.com.cn"
      - "*.dkr.ecr-fips.*.amazonaws.com"
      - "*.dkr.ecr.*.on.aws"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
```

Create `infra/ansible/roles/ecr_credential_provider/handlers/main.yml`:
```yaml
---
- name: Restart kubelet
  # Before kubeadm has run, the kubelet has no configuration and goes straight back to restarting.
  # That is expected and harmless: `kubeadm init` starts it properly a few tasks later.
  ansible.builtin.systemd:
    name: kubelet
    state: restarted
    daemon_reload: true
```

Add `- ecr_credential_provider` to the `roles:` list, below `- kubernetes_packages`. The
*Prepare every node* play is now complete:
```yaml
- name: Prepare every node
  hosts: nodes
  become: true
  roles:
    - common
    - containerd
    - kubernetes_packages
    - ecr_credential_provider
```

**Why:**

- **An ECR token lives 12 hours.** A pull secret holding one would have to be refreshed forever. The
  plugin asks ECR for a fresh token instead, using the instance profile the cluster stack attached,
  so nothing has to be stored or rotated.
- **The binary is checked against its published checksum.** `get_url` fetches the `.sha256` file
  next to it and refuses anything that does not match.
- **v1.37.0 with Kubernetes 1.36 is deliberate.** Upstream publishes this binary for a limited set
  of releases, and this build supports the cluster's credential-provider API. It speaks
  `credentialprovider.kubelet.k8s.io/v1`, the GA version of the kubelet credential-provider API.

**Run:**
```bash
make cluster
```

**Verify:**
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible
VARS="-e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
ansible nodes -b $VARS -m command -a "/etc/kubernetes/image-credential-provider/ecr-credential-provider --version"
ansible nodes -b $VARS -m command -a "cat /etc/default/kubelet"
```
Expect a version line from the binary, and a `KUBELET_EXTRA_ARGS=` line naming both the plugin
directory and `config.yaml`. That is as far as this step can be checked: the kubelet has no
configuration yet, and the first real ECR pull happens in the GitOps phase, once Jenkins has pushed
an image.

The machines are now ready. No control-plane component exists yet, and the kubelet keeps restarting
until `kubeadm init` gives it a configuration in step 6.

**Commit:** `git add infra/ansible && git commit -m "Add the ecr_credential_provider role"`

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
- **`certSANs` includes `127.0.0.1`.** In step 9 kubectl reaches the API through an SSM tunnel whose
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

Your `site.yml` is now complete:
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
  certificate lists that name because of the `certSANs` entry in step 6, so nothing has to skip TLS
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

## Step 10 — Idempotency, the HA drill, and the evidence

**Goal:** prove the cluster is reproducible and really survives losing a machine.

**Idempotency:**
```bash
cd ~/Medical-RAG-Chatbot
time make cluster
```
Every node must report `changed=0`. Anything that still changes is worth fixing before moving on.

**The HA drill.** It uses `kubectl` on the workstation, so open a second window, run `make tunnel`
there and leave it open for the whole drill. Stop node 2 — never node 1, because the tunnel runs
through it:
```bash
NODE2=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=medical-rag-node-2" \
  "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 stop-instances --instance-ids $NODE2
kubectl get nodes -w          # node 2 turns NotReady once the node-monitor grace period expires
kubectl get pods -A           # the API keeps answering: 2 of 3 etcd members is still a quorum
```
Start it again and watch it come back on its own:
```bash
aws ec2 start-instances --instance-ids $NODE2
kubectl get nodes -w          # Ready again without a playbook run: containerd and the kubelet start
                              # at boot, and the static pod manifests are already on disk
```

**Record** in `docs/evidence/ansible.md`: how long `make cluster` takes on a set of fresh nodes, the
recap line of the second run, `kubectl get nodes -o wide`, the etcd member table, and what happened
during the drill.

**End of the session:**
```bash
make infra-destroy    # the cluster stack; the shared stack and the workstation are kept
```
Then stop the workstation (EC2 → Instances → Instance state → Stop). Next time, `make infra` followed
by `make cluster` rebuilds everything from these files.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ansible-inventory --graph` shows no hosts | The nodes are not running (`make infra` first), or the tag or region in `inventory/aws_ec2.yml` does not match Terraform |
| `Failed to parse … with auto plugin` | The inventory file is not named `aws_ec2.yml`, or `make ansible-deps` has not been run |
| `couldn't resolve module/action 'amazon.aws.aws_ssm'` | Same cause: the collection is missing. Check with `ansible-galaxy collection list amazon.aws` |
| `requires ansible-core 2.17` | A newer `amazon.aws` was installed by hand. `ansible-galaxy collection install -r infra/ansible/requirements.yml --force` puts the pinned 10.3.2 back |
| `aws_account_id is undefined` | The playbook was started directly instead of through `make cluster` |
| `TargetNotConnected` on `make ping` | The SSM agent has not registered yet. `aws ssm describe-instance-information` must list the node as `Online`; a node that never appears has no NAT route |
| `Failed to upload file to S3` | The `ssm-transfer` bucket is missing or in another region. It belongs to the cluster stack, so run `make infra` |
| Tasks hang and then fail with a timeout | The Session Manager session dropped. Run it again; the playbook is idempotent |
| `dpkg` lock errors | unattended-upgrades is holding it on a freshly booted node; the roles wait up to 5 minutes for it. Run it again |
| `kubeadm init` or a join fails part-way, and the next run reports that port 6443 is in use | Reset that one node and run again. From `infra/ansible`: `ansible medical-rag-node-2 -b -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=$(aws sts get-caller-identity --query Account --output text) -m command -a "kubeadm reset -f"`, then `make cluster` |
| After resetting a node that had already joined, the next join fails on `check-etcd` | Its old etcd member is still registered. List the members with the `etcdctl` command in step 7, then `member remove <id>` before `make cluster` |
| `NTPSynchronized` never becomes `yes` in the `common` role | The node cannot reach the time service. Check the NAT route and the security group, then reboot the instance |
| Nodes stay `NotReady` after step 8 | Calico is still pulling images: `make kubectl CMD="get pods -n calico-system"`. If pods stay `Pending`, the control-plane taint is still there — step 8 |
| A join fails with `error execution phase check-etcd` | The previous join has not finished; `serial: 1` prevents this, so check that the play really has it |
| `x509: certificate is valid for …, not 127.0.0.1` | The cluster was built before `certSANs` contained `127.0.0.1`. Fix the template, then rebuild the API server certificate on each node with `kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml` |
| `The connection to the server 127.0.0.1:6443 was refused` | The `make tunnel` window was closed, or node 1 is stopped |
