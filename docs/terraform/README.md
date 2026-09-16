# Terraform architecture and folder structure

What the Terraform code builds, how the files are organised, and what each one is responsible for.
The build instructions are in [`guide.md`](guide.md). Every `.tf` file is commented, so the code
itself explains what each block does and why.

## 1. The picture

Terraform builds the AWS layer only: machines, network, storage, identity and the entry points.
Kubernetes and everything inside it is installed later by Ansible and Argo CD.

```mermaid
flowchart TB
    You["You, in a browser"]
    CS["AWS CloudShell"]
    You --> CS
    CS -->|"applies the bootstrap stack"| WS

    subgraph OPS["Ops VPC 10.20.0.0/24"]
        WS["Ops workstation<br/>EC2 Ubuntu t3.small<br/>terraform, ansible, kubectl, helm, docker, cosign"]
    end

    You -->|"Session Manager, no SSH"| WS
    WS -->|"applies"| SVC
    WS -->|"applies"| CLUSTER

    subgraph CLUSTER["Cluster VPC 10.10.0.0/16, 3 AZs"]
        PUB["Public NLB :80 app"]
        API["Internal NLB<br/>:6443 API · :443 Rancher"]
        WG["WireGuard gateway<br/>t3.small · UDP 51820"]
        N1["node-1<br/>m7i-flex.large"]
        N2["node-2"]
        N3["node-3"]
        NAT["NAT gateway"]
        PUB -->|"NodePort 30080"| N1
        PUB --> N2
        PUB --> N3
        API --> N1
        API --> N2
        API --> N3
        WG --> API
        N1 --> NAT
        N2 --> NAT
        N3 --> NAT
    end

    Internet(["App users"]) --> PUB
    Operator["Operator + WireGuard client"] -->|"vpn.recruitai.io.vn"| WG
    NAT -->|"outbound only"| EXT["Package mirrors<br/>Gemini API, HF API, GitHub"]

    N1 -->|"IAM role, no keys"| SVC
    subgraph SVC["AWS services"]
        ECR["ECR<br/>images + signatures"]
        S3["S3<br/>index, etcd backups, SSM transfer"]
        KMS["KMS<br/>cosign signing key"]
        SM["Secrets Manager<br/>app, Rancher and WireGuard keys"]
        R53["Route 53<br/>zone, rancher + vpn records"]
    end
```

Separately, **AWS Budgets** emails you at 50 % and 100 % of the 100 USD monthly limit. It is account
level and nothing in the cluster talks to it.

## 2. Three stacks, split by lifetime

A stack is one folder with its own state file. The split exists so the daily teardown never deletes
anything that is slow or expensive to rebuild.

| Stack | Applied from | Lifetime | Why |
|---|---|---|---|
| `bootstrap/` | CloudShell | Kept | It creates the state bucket the other stacks need, and the workstation they run on. Applying it from the workstation could destroy the machine you are sitting on. |
| `shared/` | Workstation | Kept | The FAISS index costs Hugging Face quota to build, secret values are typed by hand, a new KMS key invalidates every existing signature, and images would have to be rebuilt. |
| `cluster/` | Workstation | **Destroyed when idle** (end of every session) | About 0.53 USD/hour including WireGuard; everything in it is rebuilt from code. |

All three write their state to the same bucket, under different keys:

```
s3://medical-rag-tfstate-<account-id>/
  ├── bootstrap/terraform.tfstate
  ├── shared/terraform.tfstate
  └── cluster/terraform.tfstate
```

**How the stacks connect.** They never share a state file. The cluster stack looks up the shared
resources by name with `data` sources. If the shared stack is missing, `terraform plan` fails
immediately instead of building half a cluster.

```mermaid
flowchart LR
    B["bootstrap<br/>CloudShell"] -->|creates| SB[("State bucket")]
    B -->|creates| W["Ops workstation"]
    SB -.->|"stores state of"| SH["shared"]
    SB -.->|"stores state of"| C["cluster"]
    W -->|applies| SH
    W -->|applies| C
    SH -->|"looked up by name:<br/>ECR, bucket, KMS alias, secrets"| C
```

## 3. Folder structure

```
Makefile                                  make shared | infra | plan | infra-destroy
infra/terraform/
├── bootstrap/          state bucket + ops workstation      (CloudShell, kept)
├── shared/             registry, artifacts, key, secrets   (kept)
└── cluster/            network, nodes, load balancers      (destroyed when idle)
```

Inside a stack, the file name says what it builds. Terraform reads every `.tf` file in the folder and
works out the order itself from the references between resources, so the split is purely for humans.

### Files every stack has

| File | Role |
|---|---|
| `versions.tf` | Minimum Terraform version and the AWS provider version (`~> 6.64`) |
| `providers.tf` | Region and `default_tags` (`project`, `owner`, `stack`, `managed-by`, plus `env=lab` in `shared/` and `cluster/`) |
| `variables.tf` | The inputs, with defaults. Nothing else in the stack hard-codes a name or a size |
| `backend.tf` | Where the state lives. The bucket name is passed by the Makefile, so the account ID stays out of Git |
| `outputs.tf` | Values that other stacks, Ansible, Helm or you need later |
| `main.tf` | Account and AZ lookups, plus the `locals` that build names and CIDRs |

`bootstrap/` is the exception twice over: its `backend.tf` is added only in step 6, once the bucket it
creates exists, and it has no `main.tf` — its account lookup sits in `state.tf` and its AZ lookup in
`workstation.tf`. The shared stack also retains the historical filenames `bugdets.tf` and
`ouputs.tf`; Terraform loads them normally because every `.tf` file in the folder is equivalent.

### `bootstrap/` — 18 resources

| File | Creates |
|---|---|
| `state.tf` | The state bucket, with versioning, encryption, public access block, TLS-only policy, `prevent_destroy`, and a lifecycle rule that expires old versions after 90 days |
| `workstation.tf` | The ops VPC (`10.20.0.0/24`, one public subnet, internet gateway, route table), the workstation security group, its IAM role with `AdministratorAccess` + SSM, and the EC2 instance |
| `workstation-init.sh` | cloud-init: Docker and Ansible from Ubuntu packages; Terraform, kubectl, Helm, cosign, yq and gh downloaded and checked against their published checksums; AWS CLI v2 and the Session Manager plugin from their vendor URLs |
| `install-terraform.sh` | Installs Terraform into `~/bin` inside CloudShell, so the very first apply can run |

### `shared/` — 17 resources

| File | Creates | Used later by |
|---|---|---|
| `registry.tf` | ECR repository `medical-rag`: scan on push, immutable release tags, keep the last 20 tagged images | Jenkins pushes, nodes pull |
| `storage.tf` | Bucket `medical-rag-artifacts-<account>`: versioned, encrypted, private, TLS-only, old versions expire after 30 days | The index build Job writes the FAISS index; pods pull the pinned version |
| `kms.tf` | Asymmetric signing key (`ECC_NIST_P256`) + alias `alias/medical-rag-cosign` | Jenkins signs images; Kyverno verifies them |
| `secrets.tf` | Empty secrets `medical-rag/llm` and `medical-rag/github`. Values are set with the AWS CLI, never by Terraform | External Secrets syncs them into Kubernetes |
| `bugdets.tf` | Monthly budget with email alerts at 50 % and 100 %, filtered to `project=medical-rag` | You |
| `rancher.tf` | Route 53 zone plus empty `medical-rag/rancher`, `medical-rag/rancher-tls` and `medical-rag/wireguard` secrets | Rancher, External Secrets and the VPN gateway |
| `ouputs.tf` | Registry, bucket, KMS and all five secret names; never secret values | Cluster stack and operator checks |

### `cluster/` — 84 resources

| File | Creates | Notes |
|---|---|---|
| `network.tf` | VPC `10.10.0.0/16`, 3 private + 3 public subnets, internet gateway, 1 NAT gateway with its Elastic IP, route tables, S3 gateway endpoint | The community `terraform-aws-modules/vpc` module also adopts the VPC's default security group and route table (leaving both empty) and its default NACL (reset to allow-all): 3 of this step's 24 resources |
| `security.tf` | 3 security groups (nodes, API NLB, ingress NLB) and 8 rules | Rules reference security groups where possible. Three use CIDRs: HTTP from the internet, the API from the VPC, node egress. `rancher.tf` and `wireguard.tf` add the rest (end state: 4 groups, 13 rules) |
| `storage.tf` | Buckets `etcd-backups` (14 days) and `ssm-transfer` (1 day) | Cluster-scoped: useless once the cluster is gone, so `force_destroy` is on |
| `iam.tf` | The node role, instance profile and its inline policy | Least privilege: ECR, 3 project buckets, 4 workload secrets and the cosign key. WireGuard credentials are deliberately excluded |
| `compute.tf` | 3 × `m7i-flex.large` Ubuntu 24.04, one per AZ, no public IP, no key pair, IMDSv2 required | Tagged `k8s-cluster=medical-rag`, which is how Ansible finds them |
| `loadbalancers.tf` | Internal NLB :6443 and public NLB :80, with their target groups, listeners and 3 attachments each | The internal one is kubeadm's `controlPlaneEndpoint` |
| `rancher.tf` | Internal NLB :443 target group/listener, 3 attachments, 3 firewall rules and the `rancher.<domain>` alias | Nine resources. The target group disables client-IP preservation to support Rancher agent hairpin connections |
| `wireguard.tf` | Gateway SG, minimal IAM role/profile, EIP, `t3.small` instance and `vpn.<domain>` record | Ten resources. No SSH; only UDP 51820 is public |
| `main.tf` | Also holds the `data` lookups of the shared stack | A missing shared stack fails the plan here |

## 4. Everything Terraform creates, by service

| Service | Resources | Purpose |
|---|---|---|
| **EC2** | 3 nodes + 1 WireGuard gateway + 1 ops workstation | Cluster compute, private UI access and the machine you run commands from |
| **VPC** | 2 VPCs, 7 subnets, 2 internet gateways, 1 NAT gateway + EIP, WireGuard EIP, route tables, S3 endpoint | Private nodes plus a small, isolated ops network |
| **Security groups** | 5 created, plus the emptied cluster default group | Public ingress is app HTTP 80 and WireGuard UDP 51820; Rancher TCP 443 is private |
| **ELB** | 2 NLBs, 3 target groups, 3 listeners, 9 attachments | Public app entry point plus private Kubernetes API and Rancher entry point |
| **IAM** | 3 roles, 3 instance profiles, 2 inline policies, 5 managed-policy attachments | Nodes, gateway and workstation use separate roles; the gateway reads only its own secret |
| **S3** | 4 buckets: tfstate, artifacts, etcd-backups, ssm-transfer | State, the FAISS index, backups, and Ansible's file transfer over SSM |
| **ECR** | 1 repository + lifecycle policy | Signed application images |
| **KMS** | 1 signing key + alias | Cosign signs images with a key that never leaves AWS |
| **Secrets Manager** | 5 secrets | App keys, GitHub token, Rancher password/TLS and WireGuard keys |
| **Route 53** | 1 hosted zone, Rancher alias and VPN A record | Private Rancher name follows the internal NLB; VPN name follows the gateway EIP |
| **Budgets** | 1 budget | Email at 50 and 100 USD |
| **SSM** | Nothing to create | Session Manager works through the IAM role and the agent that ships with Ubuntu |

## 5. What Terraform does not create

| Layer | Built by | Phase |
|---|---|---|
| kubeadm cluster, containerd, Calico, kubelet | Ansible (`infra/ansible/`) | After Terraform |
| Argo CD, ingress-nginx, External Secrets, EBS CSI, Prometheus, Grafana, Jenkins, Kyverno, **Rancher** | Argo CD, from `deploy/argocd/` | After the cluster is up |
| The app, its index build Job, ServiceMonitor and NetworkPolicy | Helm chart `deploy/charts/medical-rag` | Last |

That boundary is deliberate: Terraform owns what AWS charges for, and Kubernetes owns what runs inside
the cluster. Rebuilding the cluster stack therefore never touches an image, a signature or the index.

## 6. How values travel

```mermaid
flowchart LR
    VARS["variables.tf<br/>project, region, sizes"] --> RES["Resource names<br/>medical-rag-nodes, medical-rag-api"]
    VARS --> TAGS["default_tags<br/>project, owner, stack, env"]
    TAGS --> BUDGET["Budget filter<br/>user:project$medical-rag"]
    TAG2["Per-instance tag<br/>k8s-cluster=medical-rag"] --> ANS["Ansible inventory"]
    OUT["outputs.tf"] --> KUBEADM["api_nlb_dns<br/>controlPlaneEndpoint"]
    OUT --> URL["public_nlb_dns<br/>app URL"]
    OUT --> VPN["wireguard_public_ip<br/>VPN endpoint"]
    OUT --> HELM["buckets, ecr_repository_url<br/>Helm values"]
    OUT --> SIGN["cosign_kms_key_arn<br/>CI signing"]
    SHARED["shared stack"] -->|"data sources by name"| CLUSTER["cluster stack"]
```

- **Variables → resources.** `var.project` builds every name, and `default_tags` puts `project`, `owner`, `stack`, `managed-by` (and `env=lab`) on everything.
- **Tags → tooling.** The budget filters on the `project` tag. Ansible instead selects nodes on the separate `k8s-cluster` tag set in `compute.tf`, so it never picks up the workstation.
- **Outputs → the next phase.** `api_nlb_dns` becomes kubeadm's `controlPlaneEndpoint`, `public_nlb_dns` is the app URL, `buckets` and `ecr_repository_url` end up in Helm values, and `cosign_kms_key_arn` is what CI signs with.
- **VPN → the private UI.** `vpn.recruitai.io.vn` follows the gateway EIP. The client routes only
  `10.10.0.0/16`; `rancher.recruitai.io.vn` resolves to the internal NLB's private addresses.
- **Data sources → across stacks and into AWS.** The cluster reads the shared registry, bucket, key and secrets by name, and reads the account ID, the Availability Zones and the Ubuntu AMI from AWS itself. No ID is ever copied by hand.

## 7. Sizing and cost

| Piece | Choice | Why |
|---|---|---|
| Node type | `m7i-flex.large` (2 vCPU, 8 GB) × 3 | kubeadm needs 2 vCPU minimum; the rest runs Jenkins, Prometheus and the app. It is also one of the types an AWS Free plan account may launch |
| Node disks | 40 GB gp3, encrypted | Images, logs and Prometheus data |
| NAT gateways | 1, not 3 | Saves about 0.12 USD/hour. If that AZ fails, nodes lose outbound internet but the cluster keeps serving |
| Workstation | `t3.small`, 30 GB + 2 GB swap | Enough for Terraform, Ansible and kubectl; application images are built by Jenkins in the cluster |
| WireGuard | `t3.small`, 8 GB gp3 + one public IPv4 | Free-tier eligible, like the workstation; destroyed with the cluster |
| Cluster total | **≈ 0.53 USD/hour** | Destroyed with `make infra-destroy` when idle |
| Kept always | ≈ 4.00 USD/month, plus 2.90 USD/month for the stopped workstation disk | KMS key, 5 secrets, Route 53, buckets and images |
| Domain + Sectigo DV | Yearly, outside AWS | Record the invoice amount; do not mix it into AWS hourly estimates |

**AWS Free plan.** This account runs on the Free plan, which refuses to launch any instance type
that is not free-tier eligible, whatever your credits. `t3.small` and `m7i-flex.large` are on that
list; `t3.medium` and `t3.large` are not. Check with:

```bash
aws freetier get-account-plan-state
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output table
```
