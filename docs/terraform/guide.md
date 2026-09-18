# Terraform guide

A step-by-step guide to build every AWS resource of this project with Terraform. Each file is commented, so the code you copy explains itself; the architecture overview is in [`README.md`](README.md) next to this file. Follow the steps in order: each one ends with a check, and the next step assumes it passed.

## How this guide works

**Where commands run.** The laptop has an editor, Git Bash and the WireGuard client used to reach
Rancher. Every infrastructure command runs in AWS.

| Where | What you do there |
|---|---|
| **Laptop:** editor + **Git Bash** | Write the files, manage the WireGuard client, commit and push |
| **AWS CloudShell** (browser) | The bootstrap stack only (steps 4 and 6) |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager in the browser | Everything else: `git pull`, `make`, checks |

> Run laptop git commands in **Git Bash** (installed with Git). Windows PowerShell 5.1 does not understand `&&`.

**Three Terraform stacks.** They are split by lifetime, so the daily teardown never deletes data that took time to build.

| Stack | Folder | Creates | Applied from | Lifetime |
|---|---|---|---|---|
| bootstrap | `infra/terraform/bootstrap/` | State bucket, ops workstation and its small VPC | CloudShell | Kept |
| shared | `infra/terraform/shared/` | ECR, artifacts, KMS, secrets, Route 53, budget | Workstation | Kept |
| cluster | `infra/terraform/cluster/` | VPC, 3 nodes, WireGuard gateway, 2 NLBs, cluster buckets | Workstation | **Destroyed when idle** |

All three store their state in the same S3 bucket under different keys: `bootstrap/`, `shared/`, `cluster/`.

**Every step has the same shape:** goal → files → why → run → verify → commit.

**Versions:** Terraform 1.16.2, AWS provider `~> 6.64`, VPC module `~> 6.7`. Region `ap-southeast-1`.

## Roadmap

| Part | Step | Before this step | Where | Result | How it helps | Still missing after | Done when |
|---|---|---|---|---|---|---|---|
| [1](guide/1-bootstrap.md) | [1](guide/1-bootstrap.md#step-1--prepare-the-repo-laptop) | The app repo is on the laptop; this project owns nothing in AWS | Laptop | `.gitignore`, `.gitattributes` | Makes it impossible to commit state or variables by accident | Nothing in AWS yet: step 2 writes the state bucket, step 4 applies it | `git status` clean after commit |
| [1](guide/1-bootstrap.md) | [2](guide/1-bootstrap.md#step-2--bootstrap-provider-variables-and-the-state-bucket-laptop) | The repo can hold Terraform code without leaking state or variables | Laptop | Bootstrap: provider, variables, state bucket | Designs one versioned, encrypted, private home for the state of all three stacks | Only code; nothing is applied, and there is no machine to run Terraform on | files committed |
| [1](guide/1-bootstrap.md) | [3](guide/1-bootstrap.md#step-3--bootstrap-the-ops-workstation-laptop) | The state bucket exists as code, not in AWS | Laptop | Bootstrap: ops workstation | Describes the machine that will run every later step, reachable only by SSM | Still code only; the workstation's tools are installed on its first boot | files pushed |
| [1](guide/1-bootstrap.md) | [4](guide/1-bootstrap.md#step-4--apply-the-bootstrap-stack-cloudshell) | The whole bootstrap stack is written and pushed | CloudShell | Bootstrap applied | Turns the written code into a real bucket and a running workstation | The state is one local CloudShell file: no versioning, no locking; step 6 fixes it | `Apply complete! Resources: 18 added` |
| [1](guide/1-bootstrap.md) | [5](guide/1-bootstrap.md#step-5--connect-to-the-workstation-session-manager) | 18 resources exist and the workstation is booting | Session Manager | Workstation ready | Teaches the Session Manager and tmux routine every later step repeats | The bootstrap state is still a local CloudShell file; step 6 moves it to S3 | every tool prints a version, the role identity works |
| [1](guide/1-bootstrap.md) | [6](guide/1-bootstrap.md#step-6--move-the-bootstrap-state-into-s3-laptop--cloudshell) | The workstation answers and uses its instance role | Laptop + CloudShell | Bootstrap state moved into S3; account hygiene | Keeps the state safe if the CloudShell session is wiped, with version history | No shared service and no cluster resource exists | `terraform plan` → `No changes` |
| [2](guide/2-shared-stack.md) | [7](guide/2-shared-stack.md#step-7--makefile-github-access-and-the-shared-stack-skeleton) | State is in S3 and the laptop's access key is off | Workstation | Makefile, GitHub access, shared stack skeleton | Lets the workstation run Terraform and push to GitHub | The shared stack still creates nothing | `make shared` succeeds, lock file pushed |
| [2](guide/2-shared-stack.md) | [8](guide/2-shared-stack.md#step-8--ecr-artifacts-bucket-kms-key-secrets-and-budget) | The shared stack is connected to its state but empty | Workstation | ECR, artifacts bucket, KMS key, secrets, budget | Creates the services that must outlive every cluster teardown | Both secrets are empty, and the budget reads 0 until the `project` tag activates | 13 resources; plain HTTP to S3 denied |
| [3](guide/3-cluster-network.md) | [9](guide/3-cluster-network.md#step-9--cluster-stack-skeleton) | The shared stack's 13 resources exist: registry, bucket, key, secrets, budget | Workstation | Cluster stack skeleton | Makes a second stack you can destroy nightly without losing the shared one | Nothing is created yet; steps 10–14 add the network, nodes and load balancers | `make infra` succeeds, shared resources found |
| [3](guide/3-cluster-network.md) | [10](guide/3-cluster-network.md#step-10--network) | The cluster stack applies cleanly and reads the shared outputs | Workstation | Network | Gives nodes and load balancers a network in 3 zones with outbound access | No security group and no instance yet; the NAT gateway now bills hourly | 6 subnets in 3 AZs, NAT gateway `available` |
| [3](guide/3-cluster-network.md) | [11](guide/3-cluster-network.md#step-11--security-groups) | A VPC with 6 subnets in 3 zones and a NAT gateway | Workstation | Security groups | Decides what may reach the nodes before any node exists | Nothing sits behind them yet; steps 13 and 14 add nodes and load balancers | only port 80 open to the internet |
| [4](guide/4-cluster-nodes-and-load-balancers.md) | [12](guide/4-cluster-nodes-and-load-balancers.md#step-12--cluster-buckets-and-the-node-iam-role) | Network and firewalls exist, with nothing inside them | Workstation | Cluster buckets + node IAM role | Gives the nodes their permissions without an access key, and their buckets | No machine assumes the role, and the buckets are empty | policy simulation `allowed` / `implicitDeny` |
| [4](guide/4-cluster-nodes-and-load-balancers.md) | [13](guide/4-cluster-nodes-and-load-balancers.md#step-13--kubernetes-nodes) | The cluster buckets exist and the node role waits for a machine | Workstation | 3 Kubernetes nodes | Creates the three machines Ansible turns into a cluster | Bare Ubuntu: no Kubernetes, no API address, and three instances now billed hourly | 3 instances `Online` in SSM |
| [4](guide/4-cluster-nodes-and-load-balancers.md) | [14](guide/4-cluster-nodes-and-load-balancers.md#step-14--network-load-balancers) | 3 nodes are `Online` in SSM, each on its own private address | Workstation | 2 Network Load Balancers | Adds a stable API address and a public entry point that survive a node swap | Both target groups stay `unhealthy` until Kubernetes (Ansible) and ingress-nginx (GitOps) | both `active`, 3 targets each |
| [4](guide/4-cluster-nodes-and-load-balancers.md) | [15](guide/4-cluster-nodes-and-load-balancers.md#step-15--rebuild-test-and-evidence) | The cluster stack was built step by step, never from nothing | Workstation | Rebuild test and evidence | Proves the stack rebuilds from nothing, and records the numbers | The cluster is destroyed again; Rancher still has no name, certificate or way in | destroy → apply works (65 resources), `plan` → `No changes` |
| [5](guide/5-domain-certificate-and-secrets.md) | [16](guide/5-domain-certificate-and-secrets.md#step-16--the-zone-and-the-private-access-secrets) | The cluster stack is reproducible and now destroyed; the account owns no zone | Workstation | DNS zone, three private-access secrets, secret inventory output | Puts the zone and the private-access secrets where a teardown cannot reach them | The domain answers from the old provider; the three secrets are empty | shared stack has 17 managed resources |
| [5](guide/5-domain-certificate-and-secrets.md) | [17](guide/5-domain-certificate-and-secrets.md#step-17--migrate-dns-and-store-the-keys) | Route 53 holds the zone, the registrar still points elsewhere | Workstation + laptop | DNS migration, Sectigo certificate, Rancher password | Hands Terraform the domain, so steps 18 and 19 can add names | `rancher` and `vpn` do not exist, and the `wireguard` secret is still empty (18.2) | DNS records survive delegation; secrets expose names only |
| [6](guide/6-wireguard-and-private-rancher.md) | [18](guide/6-wireguard-and-private-rancher.md#step-18--wireguard-and-the-private-rancher-entry-point) | DNS answers from Route 53; password and certificate are stored | Workstation + laptop | WireGuard keys, gateway and private Rancher entry point | Gives the laptop a way in, and adds the 443 listener behind it | Nothing answers yet: Ansible installs Kubernetes, GitOps installs Rancher and the UIs | handshake recorded; internal NLB lists 6443 and 443; Rancher name resolves to private addresses |
| [7](guide/7-internal-uis.md) | [19](guide/7-internal-uis.md#step-19--internal-ui-names-dns-permission-for-cert-manager-two-secrets) | The VPN reaches the VPC; `rancher` is the only internal name | Workstation | Internal UI names, cert-manager DNS permission, alert email and certificate-backup secrets | Means the GitOps phase can install the UIs without touching AWS again | No UI runs, and `wildcard-tls` stays empty until the GitOps phase | 19 resources in `shared`, 88 in `cluster`; `argocd.<domain>` resolves to private addresses |

**Parts:** [1. Bootstrap: state bucket and ops workstation](guide/1-bootstrap.md) · [2. Shared stack: registry, artifacts, signing key, secrets](guide/2-shared-stack.md) · [3. Cluster stack: skeleton, network, security groups](guide/3-cluster-network.md) · [4. Cluster stack: IAM, nodes, load balancers, rebuild test](guide/4-cluster-nodes-and-load-balancers.md) · [5. Private access: domain, certificate and secrets](guide/5-domain-certificate-and-secrets.md) · [6. Private access: WireGuard and the Rancher entry point](guide/6-wireguard-and-private-rancher.md) · [7. Internal UIs, their certificate, and alert email](guide/7-internal-uis.md) · [Troubleshooting](guide/troubleshooting.md)

---

## The loop for every workstation step

From step 7 on, every step repeats this loop:

1. **Laptop:** create or edit the files, commit, push.
2. **Workstation:** open Session Manager ([step 5](guide/1-bootstrap.md#step-5--connect-to-the-workstation-session-manager), item 2), then:
   ```bash
   sudo su - ubuntu
   tmux new -As tf                        # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot && git pull
   ```
3. **Workstation:** run the `make` targets of the step. Read the plan before answering `yes`.
4. **Workstation:** run the checks of the step.

Session Manager disconnects after about 20 idle minutes. Shell variables such as `$VPC` are lost with it, so each check block sets the variables it needs.

---

## Cost

| What | When it costs | About |
|---|---|---|
| State bucket, artifacts bucket, ECR images | Always | < 0.50 USD/month |
| KMS key + 7 secrets | Always | 3.80 USD/month |
| Route 53 hosted zone | Always | 0.50 USD/month |
| Ops workstation (`t3.small`, 30 GB) | Hourly while running; disk always | 0.03 USD/hour + 2.90 USD/month |
| Cluster + WireGuard (`t3.small`, 8 GB, public IPv4) | While it exists | **about 0.53 USD/hour** as a planning estimate; recalculate before use as evidence |
| Domain + Sectigo DV | Yearly, outside AWS | Record the invoice amount separately |

**End of every session:** `make infra-destroy`, then stop the workstation (EC2 → Instances → Instance state → Stop).

---

Start with [Part 1: Bootstrap: state bucket and ops workstation](guide/1-bootstrap.md).
