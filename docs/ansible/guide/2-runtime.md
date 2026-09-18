# Ansible guide — Part 2: Container runtime, Kubernetes packages, ECR login (steps 3–5)

[← Part 1](1-connection.md) · [Index](../guide.md) · [Part 3 →](3-control-plane.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 1 done: `site.yml` runs the `common` role on every node.

**Done when:** step 5 — containerd uses the systemd cgroup driver, kubeadm reports 1.36.4 and is held, and the ECR credential provider answers `--version` with its kubelet flags set in `/etc/default/kubelet`.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

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
  gate in [design §4.2.1](../../selfmanaged-k8s-ops-design.md#421-rancher-gitops-contract-and-compatibility-gate) passes.
- **Held packages.** An unattended upgrade that restarted the kubelet would restart every pod on the
  node; one that crossed a minor version could also make Rancher unschedulable. Upgrades are done
  deliberately, one node at a time, after that gate.
- **`cri-tools` is installed explicitly.** The `kubeadm` package no longer depends on it, but
  `crictl` is the tool for looking at containers when the kubelet or a static pod does not start.
- **The kubelet is enabled but not started.** Until kubeadm writes its configuration the kubelet has
  nothing to do and restarts in a loop. That is normal, and `kubeadm init` fixes it in [step 6](3-control-plane.md#step-6--the-kubeadm_init-role).

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
until `kubeadm init` gives it a configuration in [step 6](3-control-plane.md#step-6--the-kubeadm_init-role).

**Commit:** `git add infra/ansible && git commit -m "Add the ecr_credential_provider role"`

---

[← Part 1](1-connection.md) · [Index](../guide.md) · [Part 3 →](3-control-plane.md) · [Troubleshooting](troubleshooting.md)
