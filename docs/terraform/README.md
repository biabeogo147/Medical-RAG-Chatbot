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
    WS -->|"applies the shared and cluster stacks"| CLUSTER

    subgraph CLUSTER["Cluster VPC 10.10.0.0/16, 3 AZs"]
        PUB["Public NLB :80"]
        API["Internal NLB :6443<br/>kubeadm controlPlaneEndpoint"]
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
        N1 --> NAT
        N2 --> NAT
        N3 --> NAT
    end

    Internet(["Internet users"]) --> PUB
    NAT -->|"outbound only"| EXT["Package mirrors<br/>Gemini API, HF API, GitHub"]

    N1 -->|"IAM role, no keys"| SVC
    subgraph SVC["AWS services"]
        ECR["ECR<br/>images + signatures"]
        S3["S3<br/>index, etcd backups, SSM transfer"]
        KMS["KMS<br/>cosign signing key"]
        SM["Secrets Manager<br/>API keys"]
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
| `cluster/` | Workstation | **Destroyed when idle** (end of every session) | 0.50 USD/hour, and everything in it is rebuilt from code in minutes. |

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
`workstation.tf`.

### `bootstrap/` — 18 resources

| File | Creates |
|---|---|
| `state.tf` | The state bucket, with versioning, encryption, public access block, TLS-only policy, `prevent_destroy`, and a lifecycle rule that expires old versions after 90 days |
| `workstation.tf` | The ops VPC (`10.20.0.0/24`, one public subnet, internet gateway, route table), the workstation security group, its IAM role with `AdministratorAccess` + SSM, and the EC2 instance |
| `workstation-init.sh` | cloud-init: Docker and Ansible from Ubuntu packages; Terraform, kubectl, Helm, cosign, yq and gh downloaded and checked against their published checksums; AWS CLI v2 and the Session Manager plugin from their vendor URLs |
| `install-terraform.sh` | Installs Terraform into `~/bin` inside CloudShell, so the very first apply can run |

### `shared/` — 13 resources

| File | Creates | Used later by |
|---|---|---|
| `registry.tf` | ECR repository `medical-rag`: scan on push, immutable release tags, keep the last 20 tagged images | Jenkins pushes, nodes pull |
| `storage.tf` | Bucket `medical-rag-artifacts-<account>`: versioned, encrypted, private, TLS-only, old versions expire after 30 days | The index build Job writes the FAISS index; pods pull the pinned version |
| `kms.tf` | Asymmetric signing key (`ECC_NIST_P256`) + alias `alias/medical-rag-cosign` | Jenkins signs images; Kyverno verifies them |
| `secrets.tf` | Empty secrets `medical-rag/llm` and `medical-rag/github`. Values are set with the AWS CLI, never by Terraform | External Secrets syncs them into Kubernetes |
| `budgets.tf` | Monthly budget with email alerts at 50 % and 100 %, filtered to `project=medical-rag` | You |

### `cluster/` — 65 resources

| File | Creates | Notes |
|---|---|---|
| `network.tf` | VPC `10.10.0.0/16`, 3 private + 3 public subnets, internet gateway, 1 NAT gateway with its Elastic IP, route tables, S3 gateway endpoint | The community `terraform-aws-modules/vpc` module also adopts the VPC's default security group and route table (leaving both empty) and its default NACL (reset to allow-all): 3 of this step's 24 resources |
| `security.tf` | 3 security groups (nodes, API NLB, ingress NLB) and 8 rules | The node-to-node and NLB-to-node rules reference security groups, so they survive node replacement. Only three rules use CIDRs: HTTP from the internet, the API from inside the VPC, and node egress |
| `storage.tf` | Buckets `etcd-backups` (14 days) and `ssm-transfer` (1 day) | Cluster-scoped: useless once the cluster is gone, so `force_destroy` is on |
| `iam.tf` | The node role, instance profile and its inline policy | Least privilege: ECR for this repo, the 3 project buckets, the 2 project secrets, the cosign key. Plus two AWS managed policies: `AmazonSSMManagedInstanceCore` (Session Manager, Ansible) and `AmazonEBSCSIDriverPolicy` (volumes for the EBS CSI driver) |
| `compute.tf` | 3 × `m7i-flex.large` Ubuntu 24.04, one per AZ, no public IP, no key pair, IMDSv2 required | Tagged `k8s-cluster=medical-rag`, which is how Ansible finds them |
| `loadbalancers.tf` | Internal NLB :6443 and public NLB :80, with their target groups, listeners and 3 attachments each | The internal one is kubeadm's `controlPlaneEndpoint` |
| `main.tf` | Also holds the `data` lookups of the shared stack | A missing shared stack fails the plan here |

## 4. Everything Terraform creates, by service

| Service | Resources | Purpose |
|---|---|---|
| **EC2** | 3 nodes + 1 ops workstation | The cluster, and the machine you run commands from |
| **VPC** | 2 VPCs (cluster, ops), 7 subnets, 2 internet gateways, 1 NAT gateway + its Elastic IP, route tables, S3 gateway endpoint | Private network for the nodes; the workstation sits in its own tiny network |
| **Security groups** | 4 created (workstation, nodes, API NLB, ingress NLB), plus the cluster VPC's default group, which the module empties | Only port 80 is open to the internet |
| **ELB** | 2 Network Load Balancers, 2 target groups, 2 listeners, 6 target-group attachments | Stable API endpoint, and the public entry point for the app |
| **IAM** | 2 roles, 2 instance profiles, 1 inline policy, 4 managed-policy attachments | Machines authenticate with roles, so no access key exists anywhere |
| **S3** | 4 buckets: tfstate, artifacts, etcd-backups, ssm-transfer | State, the FAISS index, backups, and Ansible's file transfer over SSM |
| **ECR** | 1 repository + lifecycle policy | Signed application images |
| **KMS** | 1 signing key + alias | Cosign signs images with a key that never leaves AWS |
| **Secrets Manager** | 2 secrets | Gemini and HF keys, and the GitHub bot token |
| **Budgets** | 1 budget | Email at 50 and 100 USD |
| **SSM** | Nothing to create | Session Manager works through the IAM role and the agent that ships with Ubuntu |

## 5. What Terraform does not create

| Layer | Built by | Phase |
|---|---|---|
| kubeadm cluster, containerd, Calico, kubelet | Ansible (`infra/ansible/`) | After Terraform |
| Argo CD, ingress-nginx, External Secrets, EBS CSI, Prometheus, Grafana, Jenkins, Kyverno | Argo CD, from `deploy/argocd/` | After the cluster is up |
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
    OUT --> HELM["buckets, ecr_repository_url<br/>Helm values"]
    OUT --> SIGN["cosign_kms_key_arn<br/>CI signing"]
    SHARED["shared stack"] -->|"data sources by name"| CLUSTER["cluster stack"]
```

- **Variables → resources.** `var.project` builds every name, and `default_tags` puts `project`, `owner`, `stack`, `managed-by` (and `env=lab`) on everything.
- **Tags → tooling.** The budget filters on the `project` tag. Ansible instead selects nodes on the separate `k8s-cluster` tag set in `compute.tf`, so it never picks up the workstation.
- **Outputs → the next phase.** `api_nlb_dns` becomes kubeadm's `controlPlaneEndpoint`, `public_nlb_dns` is the app URL, `buckets` and `ecr_repository_url` end up in Helm values, and `cosign_kms_key_arn` is what CI signs with.
- **Data sources → across stacks and into AWS.** The cluster reads the shared registry, bucket, key and secrets by name, and reads the account ID, the Availability Zones and the Ubuntu AMI from AWS itself. No ID is ever copied by hand.

## 7. Sizing and cost

| Piece | Choice | Why |
|---|---|---|
| Node type | `m7i-flex.large` (2 vCPU, 8 GB) × 3 | kubeadm needs 2 vCPU minimum; the rest runs Jenkins, Prometheus and the app. It is also one of the types an AWS Free plan account may launch |
| Node disks | 40 GB gp3, encrypted | Images, logs and Prometheus data |
| NAT gateways | 1, not 3 | Saves about 0.12 USD/hour. If that AZ fails, nodes lose outbound internet but the cluster keeps serving |
| Workstation | `t3.small`, 30 GB + 2 GB swap | Enough for Terraform, Ansible and kubectl; application images are built by Jenkins in the cluster |
| Cluster total | **≈ 0.50 USD/hour** | Destroyed with `make infra-destroy` when idle |
| Kept always | ≈ 2.30 USD/month, plus 2.90 USD/month for the stopped workstation disk | KMS key, 2 secrets, buckets, images |

**AWS Free plan.** This account runs on the Free plan, which refuses to launch any instance type
that is not free-tier eligible, whatever your credits. `t3.small` and `m7i-flex.large` are on that
list; `t3.medium` and `t3.large` are not. Check with:

```bash
aws freetier get-account-plan-state
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output table
```

