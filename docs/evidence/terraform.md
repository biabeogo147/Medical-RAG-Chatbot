# Terraform phase — 2026-09-16

AWS account 242834061265, region `ap-southeast-1`. Terraform 1.16.2, AWS provider 6.64.0,
`terraform-aws-modules/vpc` 6.7. Everything was applied from the ops workstation over SSM Session
Manager, except the bootstrap stack, which was applied once from AWS CloudShell.

Steps 1–15 built and rebuilt the base platform. Steps 16–18 then added private access to Rancher:
a Route 53 zone, the certificate and VPN keys in Secrets Manager, a WireGuard gateway and a TCP 443
listener on the internal NLB. Every verification step of the guide returned its expected output.

## Stacks

| Stack | Resources | Lifetime | Applied from |
|---|---|---|---|
| `bootstrap` | 18 | kept | CloudShell |
| `shared` | 17 (13 after step 15, + 4 in step 16) | kept | ops workstation |
| `cluster` | 84 (65 after step 15, + 19 in step 18) | destroyed when idle | ops workstation |

At step 15, `terraform -chdir=infra/terraform/cluster state list | wc -l` → **77** (65 managed resources + 12 data sources).
The rebuild numbers below were measured at step 15, before the Rancher access was added.

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

## What is running (step 15)

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
| Secrets Manager | `medical-rag/llm`, `medical-rag/github`; from step 16 also `medical-rag/rancher`, `medical-rag/rancher-tls`, `medical-rag/wireguard` |
| Route 53 | Public hosted zone `recruitai.io.vn` (from step 16), `prevent_destroy` |
| S3 | `medical-rag-tfstate-…`, `-artifacts-…`, `-etcd-backups-…`, `-ssm-transfer-…` |
| Budget | `medical-rag-monthly`, 100 USD, alerts at 50 % and 100 % |

**Security checks that passed:**
- Plain HTTP to the state bucket → `AccessDenied` (TLS-only bucket policy).
- IAM policy simulation for the node role: `kms:Sign` on the cosign key → `allowed`; `s3:GetObject` on a bucket outside the project → `implicitDeny`.
- No access key exists on any machine: CloudShell uses the console session, the workstation and the nodes use instance roles.

## Private access to Rancher (steps 16–18)

Rancher is never exposed to the internet. The laptop reaches it through a WireGuard tunnel that only
carries DNS and TCP 443 into the cluster VPC:

`laptop → UDP 51820 → WireGuard gateway (public subnet) → internal NLB :443 → NodePort 30443 on the 3 nodes`

| Step | Check | Result |
|---|---|---|
| 16 | `make shared` | 4 added: the zone and three empty secrets |
| 16 | `terraform output route53_name_servers`, `list-secrets` | Four `awsdns` name servers; `rancher`, `rancher-tls`, `wireguard` listed |
| 17.1 | `dig +short DS recruitai.io.vn @1.1.1.1` | Empty: DNSSEC off |
| 17.1 | `dig +short NS recruitai.io.vn @1.1.1.1` after changing the name servers at the registrar | The four `awsdns` names: the domain is delegated to Route 53 |
| 17.2 | `openssl req` on `rancher.csr` | Subject and SAN `DNS:rancher.recruitai.io.vn` |
| 17.2 | `dig` of Sectigo's DCV CNAME and of `CAA` | CNAME answers with Sectigo's value, no blocking `CAA`; certificate *Issued* (Sectigo PositiveSSL DV) |
| 17.3 | `openssl x509` / `openssl verify -untrusted ca-bundle.crt` | Subject `rancher.recruitai.io.vn`, Sectigo issuer, `rancher.crt: OK` |
| 17.3 | Public key of `rancher.crt` vs `rancher.key` | `OK: the certificate matches rancher.key` |
| 17.3 | `get-secret-value … rancher-tls \| jq -c keys` | `["tls.crt","tls.key"]`; the temporary JSON file shredded |
| 17.3 | `put-secret-value … rancher` | `VersionId` returned; password file shredded |
| 18.2 | Laptop public key length, `jq -c keys` on the stored secret | `44`; `["operatorPublicKey","serverPrivateKey"]`; gateway private key file shredded |
| 18.3 | `make infra` | **84 to add, 0 to change** (65 of steps 9–14 + 19 new) |
| 18.5 | WireGuard app, tunnel `medical-rag` activated | *Latest handshake* shows a time: gateway up, `vpn.recruitai.io.vn` resolves to it, UDP 51820 open, keys match |
| 18.5 | `Resolve-DnsName rancher.recruitai.io.vn -Server 10.10.0.2` through the tunnel | Three `10.10.x.x` addresses: the internal NLB, reached through the VPC resolver |

**What this adds to the running cluster:**

| Resource | Value |
|---|---|
| WireGuard gateway | `t3.small`, 8 GB gp3, public subnet, Elastic IP, own IAM role (SSM + read `medical-rag/wireguard` only) |
| Public DNS | `vpn.recruitai.io.vn` → gateway Elastic IP; `rancher.recruitai.io.vn` → alias of the internal NLB (private addresses only) |
| Internal NLB | Listeners TCP 6443 (Kubernetes API) and TCP 443 (Rancher, target NodePort 30443, client IP not preserved) |
| Client profile | `Address = 10.99.0.2/32`, `DNS = 10.10.0.2`, `AllowedIPs = 10.10.0.0/16`, `PersistentKeepalive = 25` |

**Security properties:**
- Inbound from the internet is now TCP 80 on the public NLB and UDP 51820 on the gateway. TCP 443 and 6443 have no public listener.
- The gateway forwards only DNS to the VPC resolver and TCP 443 into the VPC (`WG_FWD` chain); everything else from the tunnel is dropped, including traffic to the gateway itself.
- Private keys never enter Git or Terraform state: Terraform creates the secrets empty, values go in with `put-secret-value --secret-string file://…`, and each temporary file is removed with `shred -u`.
- The laptop's WireGuard private key never leaves the laptop; only its public key is stored.

The 443 path end to end (TLS handshake, HTTP 308 from ingress-nginx, `Test-NetConnection` 443 `True`
and 6443 `False`) is checked after `make bootstrap`, in the GitOps phase.

## Problems found and fixed during this phase

| Problem | Root cause | Fix |
|---|---|---|
| `terraform init` in CloudShell: `no space left on device` | The AWS provider unpacks to about 830 MB; the CloudShell home folder holds 1 GB | `TF_DATA_DIR=/tmp/tf-bootstrap`, re-exported in every new session |
| `RunInstances`: `InvalidParameterCombination: The specified instance type is not eligible for Free Tier` | The account is on the **AWS Free plan**, which blocks every instance type that is not free-tier eligible | Workstation `t3.medium` → `t3.small` (plus a 2 GB swapfile), nodes `t3.large` → `m7i-flex.large` (2 vCPU, 8 GB), both free-tier eligible |
| The default VPC has no subnets, so the workstation had nowhere to launch | Someone had deleted them in this shared account | The bootstrap stack creates its own `10.20.0.0/24` VPC with one public subnet |
| The domain could not be transferred to Route 53 as registrar | Domain transfer is not available on the Free plan | Keep the registrar and delegate the whole zone: its four name servers point at the Route 53 hosted zone |
| `openssl req … -ext subjectAltName`: `unknown option ext` | The workstation's OpenSSL `req` has no `-ext` option | Print the SAN with `-text \| grep -A1 "Subject Alternative Name"` |
| Certificate check: `MISMATCH: this certificate was not issued for rancher.csr` | An automatic sort of the Sectigo files picked a CA certificate instead of the leaf | Paste the leaf into `rancher.crt` and the CA bundle into `ca-bundle.crt` by hand, then join them with `cat` |
| Gateway `cloud-init status` → `status: error` on a first boot | The setup script stopped before WireGuard started; the log was not kept, so the exact cause is not recorded (most likely the `wireguard` secret was still empty at boot) | Store the keys before `make infra` (18.2), rebuild only the gateway with `apply -replace=aws_instance.wireguard`; the recovery path is documented in guide 18.5 |

## Cost

| Item | Rate |
|---|---|
| Cluster while it exists (3 nodes, NAT gateway, 2 NLBs, public IPs, 120 GB gp3) | 0.50 USD/hour at step 15 |
| Cluster with the WireGuard gateway and its Elastic IP (step 18) | **≈ 0.53 USD/hour** |
| Ops workstation while running | 0.03 USD/hour |
| Kept always (KMS key, 5 secrets, Route 53 zone, buckets, images, stopped workstation disk) | ≈ 7 USD/month |
| Sectigo PositiveSSL certificate | Paid once per year, outside AWS |

Free plan credits: 128.47 USD, valid until 2027-02-13, about 250 cluster-hours at the step-15 rate (about 240 with the WireGuard gateway).
The cluster is destroyed at the end of every session, so the running cost is measured in hours, not days.
