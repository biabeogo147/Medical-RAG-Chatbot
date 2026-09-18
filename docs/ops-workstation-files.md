# Ops workstation: files worth knowing

The ops workstation is kept for months and only stopped when idle, so files pile up on it: a private
key, an admin kubeconfig, a GitHub token, caches, logs. This page is the map. Read it when you come back
to the project, and run the audit in section 6 every few weeks or before you hand the account to anyone.

Paths use `~` for `/home/ubuntu`. Work as `ubuntu` (`sudo su - ubuntu`); Session Manager starts you as
`ssm-user`, whose home is different.

| Mark | Meaning |
|---|---|
| 🔴 Secret | Gives access to something if copied. Never paste it anywhere, never commit it |
| 🟡 Sensitive | Personal data or account details, not a credential |
| ⚪ Ordinary | Configuration, public material, caches, logs |

Items marked *(default location)* are where the tool normally writes; the guides do not name the path.
The audit in section 6 confirms them.

---

## 1. The ones to remember

| Path | What it is | Why it matters | If it is lost |
|---|---|---|---|
| 🔴 `~/tls/rancher.recruitai.io.vn/rancher.key` | Private key of the Rancher certificate ([Terraform guide 17.2](terraform/guide/5-domain-certificate-and-secrets.md#step-17--migrate-dns-and-store-the-keys)) | Anyone with it can impersonate `rancher.recruitai.io.vn` until the certificate expires | Restore it from Secrets Manager (section 7). **Do not re-run 17.2**: a new key does not match the issued certificate |
| 🔴 `~/.kube/config` | Cluster-admin kubeconfig, written by `make cluster` ([Ansible guide](ansible/guide.md)) | Full control of the cluster while that cluster exists | `make cluster` writes it again |
| 🔴 `~/.config/gh/hosts.yml` *(default location)* | The GitHub token from `gh auth login` ([Terraform guide step 7](terraform/guide.md)) | Push access to this repo until the token expires (30 days) | Create a new token on GitHub, log in again |
| 🔴 `~/.bash_history` | Every command you typed | Holds any secret that was typed inside a command (section 5, risk 1) | Nothing to recover; clean it instead |
| 🟡 `infra/terraform/shared/terraform.tfvars` | Your budget alert email | Personal data; gitignored | Copy the `.example` again and type the email |

---

## 2. System files, written once by cloud-init

`infra/terraform/bootstrap/workstation-init.sh` runs once, as root, on the first boot. Editing it
changes nothing on the running machine (`ignore_changes = [ami, user_data]`): only replacing the
instance from CloudShell runs it again.

| Path | What it is | Mark |
|---|---|---|
| `/var/log/cloud-init-output.log` | Full trace of the setup script (`set -x`). It includes an IMDS token, which expired 60 seconds after boot | ⚪ |
| `/var/log/workstation-ready` | Empty flag: setup finished (Terraform guide step 5) | ⚪ |
| `/etc/profile.d/aws-region.sh` | Exports `AWS_REGION`, so no `~/.aws/config` is needed | ⚪ |
| `/swapfile` + a line in `/etc/fstab` | 2 GB of swap, mode 600. Memory swapped out here can contain secrets; the disk is encrypted | 🟡 |
| `/usr/local/bin/terraform`, `kubectl`, `helm`, `cosign`, `yq` | Pinned tools, checked against their published checksums | ⚪ |
| `/usr/local/bin/aws`, `/usr/local/aws-cli/` | AWS CLI v2 | ⚪ |
| `gh`, `session-manager-plugin`, `ansible`, `docker`, `jq`, `tmux` | Installed as packages | ⚪ |
| `/tmp/tmp.*/` | The setup script's download folder, never cleaned up; `/tmp` is emptied at the next stop and start | ⚪ |
| `/etc/wireguard/` | Created by `wireguard-tools` (Terraform guide 18.2). **Must stay empty here**: `wg0.conf` belongs on the gateway, not the workstation | ⚪ |

`ubuntu` is in the `docker` group, which is effectively root on this machine.

---

## 3. Your files, in the home directory

### The repo checkout: `~/Medical-RAG-Chatbot`

| Path | What it is | In Git? | Mark |
|---|---|---|---|
| `infra/terraform/shared/terraform.tfvars` | Budget alert email | No, gitignored | 🟡 |
| `infra/terraform/shared/.terraform/`, `infra/terraform/cluster/.terraform/` | Downloaded AWS provider (about 830 MB **each**) and the VPC module. Rebuilt by `make init` / `make shared-init` | No, gitignored | ⚪ |
| `infra/terraform/*/.terraform.lock.hcl` | Pinned provider versions and hashes | Yes | ⚪ |

There is **no local Terraform state**: all three stacks keep it in S3. A `terraform.tfstate` file in
the checkout means something went wrong.

### Git and GitHub

| Path | What it is | Mark |
|---|---|---|
| `~/.gitconfig` | Your name, noreply email, and `gh` as the credential helper (from `gh auth setup-git`) | 🟡 |
| `~/.config/gh/hosts.yml` *(default location)* | The fine-grained GitHub token. On a server without a keyring, `gh` may keep it in this file in plain text; `gh auth status` shows where it is. It stops working after 30 days, but the file stays | 🔴 |

### Certificate and WireGuard: `~/tls/rancher.recruitai.io.vn/`

Created by the Terraform guide, steps 17 and 18. The directory is mode 700 and every command there runs
`umask 077`, so the files are readable only by `ubuntu`. It is outside the repo.

**Files that stay:**

| File | What it is | Mark |
|---|---|---|
| `rancher.key` | Private key of the Rancher certificate. Also stored in Secrets Manager (`medical-rag/rancher-tls`) | 🔴 |
| `rancher.csr` | The request sent to Sectigo. It also acts as the guard that stops 17.2 from creating a new key | ⚪ |
| `rancher.crt` | Your certificate, pasted from Sectigo's download | ⚪ |
| `ca-bundle.crt` | Sectigo's intermediate certificates | ⚪ |
| `fullchain.crt` | `rancher.crt` followed by `ca-bundle.crt`; the form stored in Secrets Manager | ⚪ |
| `wireguard-server.pub` | The gateway's **public** WireGuard key, needed for the laptop's tunnel | ⚪ |

**Files that must never remain** (the guides create them briefly, then `shred` them):

| File | Contains |
|---|---|
| `rancher-tls.json` | The certificate chain **and its private key** |
| `rancher-password.json` | The Rancher bootstrap password |
| `wireguard-server.key` | The gateway's WireGuard private key |
| `wireguard.json`, `wireguard-new.json` | The gateway's private key and the laptop's public key |

A failed upload or a closed window can leave one behind. The audit checks for them.

### Kubernetes and Ansible (once the Ansible phase has been run)

| Path | What it is | Mark |
|---|---|---|
| `~/.kube/config` | Copy of the cluster's `admin.conf`, pointed at `https://127.0.0.1:6443` (the `make tunnel` end). Mode 600, directory 700. **It survives `make infra-destroy`** and is useless against the next cluster until `make cluster` rewrites it | 🔴 |
| `~/.kube/cache/` *(default location)* | kubectl's API discovery cache | ⚪ |
| `~/.ansible/collections/` | `amazon.aws` 10.3.2, from `make ansible-deps` | ⚪ |
| `~/.ansible/tmp/` *(default location)* | Ansible's scratch space. Empty between runs, but an interrupted `make cluster` can leave a copy of the kubeconfig here | 🔴 if not empty |

### Shell history and caches

| Path | What it is | Mark |
|---|---|---|
| `~/.bash_history` | Your typed commands. tmux panes write theirs **when the pane exits**, so a pane still open holds commands not yet in the file | 🔴 possibly |
| tmux sessions `tf` and `k8s` | Scrollback lives in memory until the workstation stops. It holds anything printed on screen, such as the Rancher password shown in 17.3 | 🔴 possibly |
| `~/.terraform.d/`, `~/.cache/helm/`, `~/.sigstore/` *(default locations)* | Terraform update check, Helm chart index, cosign trust root. No credentials | ⚪ |

---

## 4. What is deliberately not on the workstation

| Credential | Where it lives instead |
|---|---|
| AWS access keys | None exist. The workstation uses its EC2 instance role, so `~/.aws/credentials` should not exist |
| Terraform state | S3 bucket `medical-rag-tfstate-<account>` |
| App keys (Gemini, Hugging Face, Flask, GitHub bot) | Secrets Manager `medical-rag/llm`, `medical-rag/github` |
| Rancher password | Secrets Manager `medical-rag/rancher` |
| WireGuard gateway private key | Secrets Manager `medical-rag/wireguard`, and on the gateway while the cluster exists |
| Laptop WireGuard private key | Inside the laptop's WireGuard app only |
| Cosign signing key | AWS KMS; the private half never leaves it |
| SSH keys | None: the instance has no key pair |

**In CloudShell**, not here: the bootstrap step leaves `infra/terraform/bootstrap/tfplan` in the
CloudShell home folder. It holds the bootstrap plan, no secret; delete it when you no longer need it.

---

## 5. Known risks

1. **Secrets typed inside a command end up in `~/.bash_history`.** README deploy step 5 stores the app
   keys with `--secret-string '{"GOOGLE_API_KEY":"...", ...}'` typed on the command line. Safer: read
   the value with `read -rs`, write it to a mode-600 file, upload with `file://`, then `shred`, as the
   Terraform guide does in step 17. If you already typed secrets, clean the history (section 6).
2. **Printed secrets stay in tmux scrollback** until the workstation stops. Stop the workstation at the
   end of a session.
3. **The GitHub token is probably on disk in plain text** and remains after it expires. Delete expired tokens on
   GitHub and log out with `gh auth logout` when you are done with the project.
4. **Anyone who can open a Session Manager session on this instance** gets `sudo`, the admin IAM role,
   `rancher.key`, the kubeconfig and the GitHub token. Keep `ssm:StartSession` limited to yourself.
5. **Session Manager logging.** If your account sends session transcripts to S3 or CloudWatch, everything
   typed and printed is copied there too. Nothing in this project turns it on; check *Systems Manager →
   Session Manager → Preferences*.
6. **Disk space.** Two provider caches (about 1.7 GB), 2 GB of swap and Docker images share a 30 GB
   disk. `du -sh` in section 6 shows where it went.

---

## 6. Audit

Run on the workstation as `ubuntu`, one block at a time. Nothing here changes a file or prints a secret
value.

**Identity: no static keys.**
```bash
aws sts get-caller-identity --query Arn --output text
ls -la ~/.aws ~/.ssh 2>/dev/null
```
Expect an `assumed-role/...ops-workstation...` ARN, no `~/.aws/credentials` and no private key in
`~/.ssh`.

**Certificate directory: permissions, no leftovers, key still matches.**
```bash
cd ~/tls/rancher.recruitai.io.vn
stat -c '%a %n' . *
ls rancher-tls.json rancher-password.json wireguard-server.key wireguard.json wireguard-new.json 2>/dev/null
openssl x509 -in rancher.crt -noout -enddate
```
Expect `700 .` and `600` for every file; **no output** from `ls`; and the certificate's expiry date.
Renew before that date.

**GitHub token.**
```bash
gh auth status
```
Shows whether you are logged in and where the token is stored. If the token has expired, run
`gh auth logout`.

**Kubeconfig and Ansible scratch space.**
```bash
stat -c '%a %n' ~/.kube ~/.kube/config 2>/dev/null
ls -A ~/.ansible/tmp 2>/dev/null
```
Expect `700` and `600`; no output from the second command.

**WireGuard folder on the workstation.**
```bash
sudo ls -A /etc/wireguard
```
Expect no output.

**Terraform: no local state, cache sizes.**
```bash
cd ~/Medical-RAG-Chatbot
find . -name 'terraform.tfstate*' -not -path '*/.terraform/*'
du -sh infra/terraform/*/.terraform 2>/dev/null
df -h /
```
Expect no output from `find`.

**Secrets in shell history.** Counts matching lines without showing them:
```bash
grep -c "secret-string '" ~/.bash_history
grep -cE 'github_pat_|ghp_' ~/.bash_history
```
Expect `0` twice. If not:

1. In every open tmux pane, run `history -c`, or close the pane with `exit`. Otherwise the pane writes
   its history back to the file when it exits.
2. Open `nano ~/.bash_history`, delete the lines that contain secrets, and save.
3. Rotate the exposed key: create a new one at the provider and store it in Secrets Manager.

---

## 7. If the workstation is replaced

Stopping the workstation keeps every file. Replacing it (a new instance from CloudShell) starts from an
empty disk. Rebuild what matters:

| Lost | How to get it back |
|---|---|
| Repo checkout | `git clone`, Terraform guide step 7 |
| GitHub access | New fine-grained token, `gh auth login --with-token`, `gh auth setup-git` (step 7) |
| `terraform.tfvars` | Copy the `.example`, type the budget email |
| `.terraform/` caches | `make shared-init` and `make init` |
| `~/.ansible/collections/` | `make ansible-deps` |
| `~/.kube/config` | `make cluster` (only when a cluster exists) |
| `~/tls/rancher.recruitai.io.vn/` | Restore it from Secrets Manager, below. **Do not re-run 17.2** |

Install the WireGuard tools first; they are needed at the end:
```bash
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get -o DPkg::Lock::Timeout=600 install -y wireguard-tools
```
Restore the certificate directory from Secrets Manager:
```bash
install -d -m 700 ~/tls/rancher.recruitai.io.vn
cd ~/tls/rancher.recruitai.io.vn
umask 077
aws secretsmanager get-secret-value --secret-id medical-rag/rancher-tls --query SecretString --output text | jq -r '."tls.key"' > rancher.key
aws secretsmanager get-secret-value --secret-id medical-rag/rancher-tls --query SecretString --output text | jq -r '."tls.crt"' > fullchain.crt
```
Recreate `rancher.csr` from the restored key, so the guard in 17.2 works again:
```bash
openssl req -new -key rancher.key -out rancher.csr -subj "/CN=rancher.recruitai.io.vn" -addext "subjectAltName=DNS:rancher.recruitai.io.vn"
```
Recreate the gateway's public key, without writing its private key to a file:
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/wireguard --query SecretString --output text | jq -r '.serverPrivateKey' | wg pubkey > wireguard-server.pub
```
`rancher.crt` and `ca-bundle.crt` are only needed to build `fullchain.crt`, which you now have. Keep the
Sectigo download on the laptop for the next renewal.
