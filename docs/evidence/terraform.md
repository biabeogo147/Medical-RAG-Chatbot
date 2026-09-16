# Terraform phase — 2026-09-16

AWS account 242834061265, region `ap-southeast-1`. Terraform 1.16.2, AWS provider 6.64.0,
`terraform-aws-modules/vpc` 6.7. Everything was applied from the ops workstation over SSM Session
Manager, except the bootstrap stack, which was applied once from AWS CloudShell.

## Stacks

| Stack | Resources | Lifetime | Applied from |
|---|---|---|---|
| `bootstrap` | 18 | kept | CloudShell |
| `shared` | 13 | kept | ops workstation |
| `cluster` | 65 | destroyed when idle | ops workstation |

`terraform -chdir=infra/terraform/cluster state list | wc -l` → **77** (65 managed resources + 12 data sources).

## Reproducibility

| Check | Result |
|---|---|
| `terraform fmt -check` and `validate`, all three stacks | clean |
| `terraform plan` after `apply` | `No changes. Your infrastructure matches the configuration.` |
| `time make infra-destroy` | **1 m 27 s** |
| `time make infra` (rebuild from nothing) | **3 m 19 s** |
| `terraform plan` after the rebuild | `No changes.` |
| `make shared-plan` after the cluster rebuild | `No changes.` — the registry, index bucket, signing key and secrets survived the teardown |

A full cluster rebuild therefore takes **3.5 minutes** and needs no manual step.

## What is running

**Nodes** — one per Availability Zone, no public IP, no key pair, IMDSv2 required:

| Name | Type | AZ | Private IP |
|---|---|---|---|
| medical-rag-node-1 | m7i-flex.large | ap-southeast-1a | 10.10.1.160 |
| medical-rag-node-2 | m7i-flex.large | ap-southeast-1b | 10.10.2.106 |
| medical-rag-node-3 | m7i-flex.large | ap-southeast-1c | 10.10.3.124 |

All three report `Online` in SSM (Ubuntu 24.04), so Ansible can reach them without SSH.

**Network:** VPC `10.10.0.0/16`, 6 subnets across 3 AZs, NAT gateway `available`, S3 gateway endpoint.
Only one inbound rule is open to the internet: TCP 80 on the public NLB.

**Load balancers:**

| Name | Scheme | State | DNS |
|---|---|---|---|
| medical-rag-api | internal | active | `medical-rag-api-692fbe8f621d8ef9.elb.ap-southeast-1.amazonaws.com` |
| medical-rag-ingress | internet-facing | active | `medical-rag-ingress-1a82ae897541e4db.elb.ap-southeast-1.amazonaws.com` |

Targets are registered and `unhealthy`, as expected: Kubernetes and ingress-nginx are not installed yet.

**Shared services:**

| Resource | Verified value |
|---|---|
| ECR | `242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag`, `IMMUTABLE_WITH_EXCLUSION`, scan on push enabled |
| KMS | `SIGN_VERIFY` / `ECC_NIST_P256`, enabled, alias `alias/medical-rag-cosign` |
| Secrets Manager | `medical-rag/llm`, `medical-rag/github` |
| S3 | `medical-rag-tfstate-…`, `-artifacts-…`, `-etcd-backups-…`, `-ssm-transfer-…` |
| Budget | `medical-rag-monthly`, 100 USD, alerts at 50 % and 100 % |

**Security checks that passed:**
- Plain HTTP to the state bucket → `AccessDenied` (TLS-only bucket policy).
- IAM policy simulation for the node role: `kms:Sign` on the cosign key → `allowed`; `s3:GetObject` on a bucket outside the project → `implicitDeny`.
- No access key exists on any machine: CloudShell uses the console session, the workstation and the nodes use instance roles.

## Problems found and fixed during this phase

| Problem | Root cause | Fix |
|---|---|---|
| `terraform init` in CloudShell: `no space left on device` | The AWS provider unpacks to about 830 MB; the CloudShell home folder holds 1 GB | `TF_DATA_DIR=/tmp/tf-bootstrap`, re-exported in every new session |
| `RunInstances`: `InvalidParameterCombination: The specified instance type is not eligible for Free Tier` | The account is on the **AWS Free plan**, which blocks every instance type that is not free-tier eligible | Workstation `t3.medium` → `t3.small` (plus a 2 GB swapfile), nodes `t3.large` → `m7i-flex.large` (2 vCPU, 8 GB), both free-tier eligible |
| The default VPC has no subnets, so the workstation had nowhere to launch | Someone had deleted them in this shared account | The bootstrap stack creates its own `10.20.0.0/24` VPC with one public subnet |

## Cost

| Item | Rate |
|---|---|
| Cluster while it exists (3 nodes, NAT gateway, 2 NLBs, public IPs, 120 GB gp3) | **0.50 USD/hour** |
| Ops workstation while running | 0.03 USD/hour |
| Kept always (KMS key, 2 secrets, buckets, images, stopped workstation disk) | ≈ 5 USD/month |

Free plan credits: 128.47 USD, valid until 2027-02-13, about 250 cluster-hours.
The cluster is destroyed at the end of every session, so the running cost is measured in hours, not days.
