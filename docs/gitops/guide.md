# GitOps guide

A step-by-step guide that installs Argo CD on the cluster Ansible built, and then lets Argo CD install
everything else from Git: ingress-nginx, the EBS CSI driver, External Secrets, cert-manager, monitoring
with alert email, and Rancher. Every internal UI (Argo CD, Grafana, Prometheus, Alertmanager, Rancher)
opens only through the VPN.
Every file is commented, so the code you copy explains itself. The architecture overview is in
[`README.md`](README.md) next to this file. Follow the steps in order: each one ends with a check, and
the next step assumes it passed.

## How this guide works

**Start here when:**

- [Ansible guide](../ansible/guide.md) steps 10 and 11 are done: a second `make cluster` changes
  nothing, and the control-plane metrics listen on the node address.
- [Terraform guide](../terraform/guide.md) steps 16–19 are done: Secrets Manager holds
  the Rancher certificate and password and the SMTP settings, the internal UI names exist, and the
  WireGuard tunnel shows a handshake.

**Where commands run.** No ops tool is installed on your laptop.

| Where | What you do there |
|---|---|
| **Laptop:** editor + Git Bash | Write the files shown in each step, commit, push to GitHub |
| **Laptop:** PowerShell, browser, WireGuard app | Steps 9–11 and 13, to open the internal UIs through the VPN |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager | `git pull`, `make`, `kubectl`, checks |
| **WireGuard gateway:** a shell opened from the workstation with `aws ssm start-session` | Step 11 only, to test a certificate chain from inside the VPC |

**One idea to keep in mind.** After step 3 you never install an addon by hand again. You add a file
under `deploy/argocd/`, push it, and Argo CD installs it. **The push is the deploy.** The commands in
each step after that are **checks**, not installs.

**Every step has the same shape:** goal → files → why → commit and push → check.

**Commands are short on purpose.** Each line does one thing, and a value you need twice is saved in a
variable on its own line first. A long command is split over several lines with `\`, one option per
line. When something fails, you know exactly which part.

**References.** "Criterion #4" and "#5" are rows of the definition of done in
[design §6](../selfmanaged-k8s-ops-design.md#6-verification-and-evidence-definition-of-done); "§4.2.1"
is the [Rancher contract and compatibility gate](../selfmanaged-k8s-ops-design.md#421-rancher-gitops-contract-and-compatibility-gate).

**Versions** (checked 2026-09-17): Argo CD chart 10.9.2 (Argo CD v3.5.3), ingress-nginx 4.15.1,
aws-ebs-csi-driver 2.66.0, external-secrets 2.10.0, cert-manager v1.21.2, kube-prometheus-stack 91.4.1,
Rancher 2.15.1.
Region `ap-southeast-1`.

## Roadmap

| Part | Step | Before this step | Result | How it helps | Still missing after | Done when |
|---|---|---|---|---|---|---|
| [1](guide/1-argocd.md) | [1](guide/1-argocd.md#step-1--cluster-up-tunnel-open-secrets-present) | Terraform and Ansible are done: an HA cluster, DNS names and secrets | Cluster up, tunnel open, secrets present | Gives kubectl a way into the cluster, and proves the secrets hold values | Nothing is installed: Argo CD comes in step 2, ingress-nginx in step 4 | 3 nodes `Ready`; the Rancher and alertmanager secrets have a current version |
| [1](guide/1-argocd.md) | [2](guide/1-argocd.md#step-2--install-argo-cd-by-hand) | Cluster up, tunnel open, secrets present; only Calico, CoreDNS and kube-proxy run | Argo CD installed by hand | Puts Argo CD in the cluster and shows what `make bootstrap` will do | Argo CD manages nothing: no Application exists | Every Argo CD pod `Running`; the API answers `ok` |
| [1](guide/1-argocd.md) | [3](guide/1-argocd.md#step-3--the-root-application-and-argo-cd-managing-itself) | Argo CD runs, installed by hand with Helm | `root` app-of-apps, Argo CD manages itself, `make bootstrap` | Hands Argo CD the repository, and its own chart, to manage | No addon is installed, so the ingress targets are still unhealthy | `argocd` and `root` are `Synced` and `Healthy` |
| [2](guide/2-foundation.md) | [4](guide/2-foundation.md#step-4--ingress-nginx) | Argo CD syncs itself from Git and watches `apps/` | ingress-nginx | Gives both load balancers a controller to route to | Requests reach nginx and stop there: no Ingress, no trusted certificate | Both ingress target groups `healthy`; the public NLB answers `404` |
| [2](guide/2-foundation.md) | [5](guide/2-foundation.md#step-5--ebs-csi-driver-and-the-gp3-storageclass) | The ingress targets are healthy and nginx answers `404` | EBS CSI driver + `gp3` StorageClass | Lets a pod ask for an encrypted volume in its own zone | Nothing asks for a volume yet, and no secret reaches the cluster | A test volume is created, used and deleted |
| [2](guide/2-foundation.md) | [6](guide/2-foundation.md#step-6--external-secrets-and-the-platform-secrets) | `gp3` creates and deletes encrypted volumes on demand | External Secrets + `platform-secrets` | Brings Secrets Manager values into the cluster without putting them in Git | No trusted certificate yet: nginx still serves a self-signed placeholder | `tls-rancher-ingress` exists, with the right certificate |
| [3](guide/3-certificates-and-argocd-ui.md) | [7](guide/3-certificates-and-argocd-ui.md#step-7--cert-manager-and-the-wildcard-certificate) | Secrets Manager values reach the cluster; nginx serves a placeholder certificate | cert-manager + wildcard certificate | Gets a trusted certificate for every internal name | Not backed up: Let's Encrypt allows only 5 orders for these names per 7 days | `*.recruitai.io.vn` `READY True`, issued by Let's Encrypt production |
| [3](guide/3-certificates-and-argocd-ui.md) | [8](guide/3-certificates-and-argocd-ui.md#step-8--keep-the-certificate-across-rebuilds) | A trusted wildcard certificate; `medical-rag/wildcard-tls` is still empty | Certificate backup and restore | Saves the certificate to Secrets Manager so a rebuild can put it back | No UI answers on those names: the Argo CD Ingress comes in step 9 | The certificate is in Secrets Manager; the restore object is `SecretSynced` |
| [3](guide/3-certificates-and-argocd-ui.md) | [9](guide/3-certificates-and-argocd-ui.md#step-9--the-argo-cd-ui-through-the-vpn) | The certificate is in Secrets Manager and the restore object is in place | Argo CD UI | Replaces step 2's port-forward with a real URL, open only over the VPN | Nothing measures the cluster: no metrics, no alerts, no management UI | `argocd.recruitai.io.vn`: no VPN → timeout; VPN → login works |
| [4](guide/4-monitoring-and-rancher.md) | [10](guide/4-monitoring-and-rancher.md#step-10--monitoring-the-whole-cluster-alert-email-three-uis) | The Argo CD UI opens through the VPN; Ansible step 11 opened the control-plane metrics | Monitoring, alert email, 3 UIs | Adds metrics for the whole cluster and email when something breaks | No management UI (criterion #4), and the rebuild is unproven (criterion #5) | Every target `up` incl. etcd; a test alert arrives by email; Grafana, Prometheus, Alertmanager open through the VPN |
| [4](guide/4-monitoring-and-rancher.md) | [11](guide/4-monitoring-and-rancher.md#step-11--rancher) | Prometheus, Grafana and Alertmanager run behind the VPN | Rancher | Adds the management UI and closes criterion #4 | No safe teardown: `make infra-destroy` alone would strand Prometheus's EBS volume | Criterion #4: no VPN → timeout; VPN → `pong`; the chain verifies; the UI loads |
| [5](guide/5-teardown-and-rebuild.md) | [12](guide/5-teardown-and-rebuild.md#step-12--make-down) | Every platform component runs; only `make infra-destroy` exists | `make down` by hand, then as a target | Makes teardown release the EBS volumes the cluster created | Nothing has proved the platform comes back from Git; no evidence recorded | No CSI volume left in EC2, cluster destroyed |
| [5](guide/5-teardown-and-rebuild.md) | [13](guide/5-teardown-and-rebuild.md#step-13--rebuild-from-nothing-and-the-evidence) | A destroyed cluster; Git, the Makefile and the certificate backup survive | Rebuild from nothing, evidence | Proves the platform comes back from Git alone, and records the evidence | The app is not deployed: its Helm chart, the index Job and Jenkins come next | Every Application `Synced` and `Healthy`; no new certificate ordered; times recorded |

**Parts:** [1. Argo CD: install by hand, then let it manage itself](guide/1-argocd.md) · [2. Foundation: ingress, volumes, secrets](guide/2-foundation.md) · [3. Certificates and the first internal UI](guide/3-certificates-and-argocd-ui.md) · [4. Monitoring, alert email and Rancher](guide/4-monitoring-and-rancher.md) · [5. Teardown, rebuild and evidence](guide/5-teardown-and-rebuild.md) · [Troubleshooting](guide/troubleshooting.md)

---

## The loop for every step

1. **Laptop:** create or edit the files, then in Git Bash:
   ```bash
   git add deploy
   git commit -m "<the message given in the step>"
   git push
   ```
2. **Workstation:** open Session Manager, then:
   ```bash
   sudo su - ubuntu
   tmux new -As k8s                       # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot
   git pull
   ```
3. **Workstation, from step 3 on** (before that, Argo CD does not exist yet): ask Argo CD to read Git
   now instead of within the next three minutes. `--all` matters: a changed file inside an existing
   Application is noticed only when that Application is refreshed, not just `root`.
   ```bash
   kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite
   ```
4. **Workstation:** run the checks of the step.

### tmux windows

tmux numbers its windows from 0, and the status bar at the bottom shows them. This
guide uses three:

| Window | Used for | How to get there |
|---|---|---|
| 0 | Everything else: `make`, `kubectl`, checks | `Ctrl-b 0` |
| 1 | `make tunnel`, open the whole time | `Ctrl-b c` the first time, then `Ctrl-b 1` |
| 2 | A short-lived port-forward, only in step 2 | `Ctrl-b c`; close it with `Ctrl-C`, then `exit` |

kubectl reaches the API through the tunnel. If window 1 closes, kubectl answers `connection refused`;
open it again and run `make tunnel`.

**Reading the Application list.** You will run this often:
```bash
kubectl -n argocd get applications
```
`SYNC STATUS` says whether the cluster matches Git (`Synced`) or not (`OutOfSync`). `HEALTH STATUS`
says whether what was applied actually works (`Healthy`), is still starting (`Progressing`), or is
broken (`Degraded`). A step is done when its new line shows `Synced` and `Healthy`.

---

Start with [Part 1: Argo CD: install by hand, then let it manage itself](guide/1-argocd.md).
