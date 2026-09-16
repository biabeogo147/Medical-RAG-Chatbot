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

| Step | Where | Result | Done when |
|---|---|---|---|
| 1 | Laptop | `.gitignore`, `.gitattributes` | `git status` clean after commit |
| 2 | Laptop | Bootstrap: provider, variables, state bucket | files committed |
| 3 | Laptop | Bootstrap: ops workstation | files pushed |
| 4 | CloudShell | Bootstrap applied | `Apply complete! Resources: 18 added` |
| 5 | Session Manager | Workstation ready | every tool prints a version, the role identity works |
| 6 | Laptop + CloudShell | Bootstrap state moved into S3; account hygiene | `terraform plan` → `No changes` |
| 7 | Workstation | Makefile, GitHub access, shared stack skeleton | `make shared` succeeds, lock file pushed |
| 8 | Workstation | ECR, artifacts bucket, KMS key, secrets, budget | 13 resources; plain HTTP to S3 denied |
| 9 | Workstation | Cluster stack skeleton | `make infra` succeeds, shared resources found |
| 10 | Workstation | Network | 6 subnets in 3 AZs, NAT gateway `available` |
| 11 | Workstation | Security groups | only port 80 open to the internet |
| 12 | Workstation | Cluster buckets + node IAM role | policy simulation `allowed` / `implicitDeny` |
| 13 | Workstation | 3 Kubernetes nodes | 3 instances `Online` in SSM |
| 14 | Workstation | 2 Network Load Balancers | both `active`, 3 targets each |
| 15 | Workstation | Rebuild test and evidence | destroy → apply works (65 resources), `plan` → `No changes` |
| 16 | Workstation | DNS zone, three private-access secrets, secret inventory output | shared stack has 17 managed resources |
| 17 | Workstation + laptop | DNS migration, Sectigo certificate and WireGuard keys | DNS records survive delegation; secrets expose names only |
| 18 | Workstation + laptop | WireGuard gateway and private Rancher entry point | handshake recorded; internal NLB lists 6443 and 443; Rancher name resolves to private addresses |

## Cost

| What | When it costs | About |
|---|---|---|
| State bucket, artifacts bucket, ECR images | Always | < 0.50 USD/month |
| KMS key + 5 secrets | Always | 3.00 USD/month |
| Route 53 hosted zone | Always | 0.50 USD/month |
| Ops workstation (`t3.small`, 30 GB) | Hourly while running; disk always | 0.03 USD/hour + 2.90 USD/month |
| Cluster + WireGuard (`t3.small`, 8 GB, public IPv4) | While it exists | **about 0.53 USD/hour** as a planning estimate; recalculate before use as evidence |
| Domain + Sectigo DV | Yearly, outside AWS | Record the invoice amount separately |

**End of every session:** `make infra-destroy`, then stop the workstation (EC2 → Instances → Instance state → Stop).

---

## Part A — Bootstrap

### Step 1 — Prepare the repo (laptop)

**Goal:** Terraform state and variables can never be committed, and Terraform files always use Linux line endings.

Append to `.gitignore`:

```gitignore
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
tfplan
```

Append to `.gitattributes`:

```gitattributes
*.tf text eol=lf
*.hcl text eol=lf
Makefile text eol=lf
```

**Why:**
- State files can contain resource details and sometimes secrets. `*.tfvars` holds your email; only `.example` files are shared.
- `.terraform.lock.hcl` is **not** ignored: it pins provider versions, like `uv.lock`, and is committed in step 7.
- The files are written on Windows but run on Linux. `.gitattributes` already forces LF for `*.sh`; this adds Terraform files and the Makefile.

**Commit:**
```bash
git add .gitignore .gitattributes
git commit -m "Ignore Terraform state and force LF for Terraform files"
```

---

### Step 2 — Bootstrap: provider, variables and the state bucket (laptop)

**Goal:** a versioned, encrypted, private S3 bucket that holds the state of all three stacks.

Create `infra/terraform/bootstrap/versions.tf`:
```hcl
# Settings for Terraform itself. Only constants are allowed here: no variables.
terraform {
  # 1.10 is the first release with native S3 state locking (use_lockfile), which all three stacks use.
  required_version = ">= 1.10"

  # Terraform core knows nothing about AWS. The provider plugin makes the API calls.
  # `terraform init` downloads it and records the exact version in .terraform.lock.hcl.
  required_providers {
    aws = {
      source = "hashicorp/aws" # short for registry.terraform.io/hashicorp/aws

      # "Pessimistic" operator: accepts 6.64, 6.65, 6.99 ... but never 7.0, which may break things.
      version = "~> 6.64"
    }
  }
}
```

Create `infra/terraform/bootstrap/providers.tf`:
```hcl
# Which region to call and which credentials to use. No key is configured: in CloudShell the provider
# uses the console session, and on the ops workstation it uses the EC2 instance role.
provider "aws" {
  region = var.region # var.<name> reads a variable declared in variables.tf

  # Tags added automatically to every resource created through this provider.
  default_tags {
    tags = {
      project    = var.project # the tag the AWS budget filters on, to separate this project's spend
      owner      = var.owner
      stack      = "bootstrap" # says in the console which stack created a resource
      managed-by = "terraform" # a warning not to edit the resource by hand
    }
  }
}
```

Create `infra/terraform/bootstrap/variables.tf`:
```hcl
# The inputs of this stack. Everything else refers to them as var.<name>, so no name, size or region
# is hard-coded further down. Override one without editing the code:
#   terraform apply -var workstation_instance_type=c7i-flex.large
#   a terraform.tfvars file, or the environment variable TF_VAR_workstation_instance_type
#
# `description` shows up in `terraform plan`; `type` makes Terraform reject a wrong value early;
# `default` makes the variable optional (a variable without one must be supplied).

variable "region" {
  description = "AWS region for every resource in this project."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as the resource name prefix and the project tag."
  type        = string
  default     = "medical-rag"
}

variable "owner" {
  description = "Value of the owner tag."
  type        = string
  default     = "devops-lab-user"
}

variable "ops_vpc_cidr" {
  description = "CIDR of the small VPC that hosts the ops workstation."
  type        = string
  default     = "10.20.0.0/24" # must not overlap the cluster VPC (10.10.0.0/16)
}

variable "workstation_instance_type" {
  description = "EC2 instance type of the ops workstation."
  type        = string
  # t3.small (2 vCPU, 2 GB) is enough for Terraform, Ansible and kubectl, and it is one of the
  # types an AWS Free plan account may launch.
  default = "t3.small"
}

variable "workstation_volume_gb" {
  description = "Root volume size of the ops workstation, in GB."
  type        = number
  default     = 30
}
```

Create `infra/terraform/bootstrap/state.tf`:
```hcl
# The S3 bucket that stores the Terraform state of all three stacks.
# State is the record of what Terraform created; losing it means losing control of the resources.

# A `data` source reads from AWS instead of creating anything. This one answers "which account is this?".
data "aws_caller_identity" "current" {}

# Values computed once and reused. "${...}" inserts a value into a string.
locals {
  # S3 bucket names are unique across every AWS account in the world, hence the account ID suffix.
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# A `resource` is something Terraform creates and owns.
# "aws_s3_bucket" is the type, "state" is the local name used in references (aws_s3_bucket.state.id).
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    # Terraform refuses to delete this bucket, even with `terraform destroy`.
    prevent_destroy = true
  }
}

# Each bucket feature is its own resource. Before AWS provider v4 they were blocks inside aws_s3_bucket.
# `bucket = aws_s3_bucket.state.id` is a reference: it passes the name AND tells Terraform to create
# the bucket first. References are how Terraform works out the order; you never write the order yourself.

# Keeps the previous copy of every overwritten object, so a broken state file can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# AES256 uses keys AWS manages, at no cost. aws:kms would add a charge per request, pointless for state.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Four switches that make it impossible to expose the bucket publicly, even by accident later.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Builds an IAM policy in HCL and renders it to JSON: easier to read and review than a JSON blob.
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport" # a name for the statement, visible in the console
    effect  = "Deny"                  # an explicit Deny always wins, whatever else allows the action
    actions = ["s3:*"]

    principals {
      type        = "*" # applies to everyone
      identifiers = ["*"]
    }

    # Both ARNs are needed: the bucket itself (listing) and the objects inside it.
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    # The Deny applies only when the request did NOT use TLS, so HTTPS keeps working and plain HTTP fails.
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # No reference links these two, but AWS can reject a bucket policy while it decides whether the
  # policy is "public", so the public access block must exist first.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {} # empty filter = every object. Required: without it the rule is rejected

    # Versioning protects you, but without this the bucket would grow forever.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Interrupted uploads are otherwise kept and billed invisibly.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # A rule about old versions only makes sense once versioning is enabled.
  depends_on = [aws_s3_bucket_versioning.state]
}
```

**Why:**
- **`required_version` / `~> 6.64`:** everyone runs a compatible Terraform and provider. `~> 6.64` accepts 6.65, 6.66… but never 7.0, which may contain breaking changes.
- **`default_tags`:** every resource gets `project`, `owner`, `stack` and `managed-by` automatically. The `project` tag later filters the budget.
- **Account ID in the bucket name:** S3 bucket names are global across all AWS accounts.
- **One resource per bucket feature:** since AWS provider v4, versioning, encryption, public access and lifecycle are separate resources.

| Protection | Purpose |
|---|---|
| Versioning | Recover an older state after a bad write |
| Encryption (`AES256`) | Data encrypted at rest |
| Public access block | The bucket can never be made public |
| TLS-only policy | Requests over plain HTTP are denied |
| Lifecycle | Old state versions are deleted after 90 days |
| `prevent_destroy` | Terraform refuses to delete the bucket |

**Commit:**
```bash
git add infra
git commit -m "Add Terraform bootstrap stack: state bucket"
```

---

### Step 3 — Bootstrap: the ops workstation (laptop)

**Goal:** an Ubuntu EC2 instance with every ops tool installed, reachable only through Session Manager.

The workstation variables (`ops_vpc_cidr`, `workstation_instance_type`, `workstation_volume_gb`) are already in `variables.tf` from step 2.

Create `infra/terraform/bootstrap/workstation.tf`:
```hcl
# The ops workstation: an EC2 Ubuntu machine with every ops tool, reached only through SSM
# Session Manager. All later Terraform, Ansible, kubectl and Helm commands run there, so nothing has
# to be installed on the operator's laptop. Docker is there for checks and image pulls only:
# application images are built in the cluster by Jenkins with rootless BuildKit.

# Canonical publishes the newest Ubuntu 24.04 image ID in this public SSM parameter, per region.
# Reading it beats hard-coding an AMI ID, which is region-specific and goes stale.
data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Lists the AZs of the region, so no AZ name is written in the code.
data "aws_availability_zones" "available" {
  state = "available"
}

# --- A small network of its own -------------------------------------------------------------------
# One public subnet, no NAT. It does not depend on the default VPC (which anyone in the account can
# change) and never overlaps the cluster VPC (10.10.0.0/16).

resource "aws_vpc" "ops" {
  cidr_block           = var.ops_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # needed to resolve AWS endpoints such as ssm.<region>.amazonaws.com

  tags = {
    Name = "${var.project}-ops"
  }
}

# The VPC's door to the internet. Attaching it is not enough: a route must point at it (below).
resource "aws_internet_gateway" "ops" {
  vpc_id = aws_vpc.ops.id

  tags = {
    Name = "${var.project}-ops"
  }
}

resource "aws_subnet" "ops_public" {
  vpc_id = aws_vpc.ops.id

  # cidrsubnet(10.20.0.0/24, 4, 0) adds 4 bits and takes the first block: 10.20.0.0/28. Enough for one machine.
  cidr_block        = cidrsubnet(var.ops_vpc_cidr, 4, 0)
  availability_zone = data.aws_availability_zones.available.names[0] # lists are indexed from 0

  tags = {
    Name = "${var.project}-ops-public"
  }
}

resource "aws_route_table" "ops_public" {
  vpc_id = aws_vpc.ops.id

  # "Anything not local goes to the internet gateway." This is what makes the subnet public.
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ops.id
  }

  tags = {
    Name = "${var.project}-ops-public"
  }
}

# Without this the subnet would use the VPC's default route table, which has no internet route.
resource "aws_route_table_association" "ops_public" {
  subnet_id      = aws_subnet.ops_public.id
  route_table_id = aws_route_table.ops_public.id
}

# --- Identity --------------------------------------------------------------------------------------
# A role needs both halves: a trust policy saying WHO may assume it, and permissions saying WHAT it may do.

# The trust policy: only the EC2 service can assume this role.
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workstation" {
  name               = "${var.project}-ops-workstation"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# for_each creates one resource per item in the set, instead of repeating the block. each.value is the item.
resource "aws_iam_role_policy_attachment" "workstation" {
  for_each = toset([
    # Terraform creates many kinds of resources, so the workstation gets full rights. A lab trade-off:
    # anyone allowed to start an SSM session on this machine gets admin rights.
    "arn:aws:iam::aws:policy/AdministratorAccess",
    # Lets the SSM agent register the instance, which is what makes the browser shell work.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.workstation.name
  policy_arn = each.value
}

# EC2 cannot be given a role directly, only a profile that contains one.
resource "aws_iam_instance_profile" "workstation" {
  name = "${var.project}-ops-workstation"
  role = aws_iam_role.workstation.name
}

# --- Firewall ---------------------------------------------------------------------------------------
# A security group with no ingress rule blocks everything inbound. Nothing listens for you: the SSM
# agent dials out to AWS, and the browser session travels back over that connection. No SSH, no key pair.
resource "aws_security_group" "workstation" {
  name        = "${var.project}-ops-workstation"
  description = "Ops workstation: no inbound rules, reached only through SSM"
  vpc_id      = aws_vpc.ops.id
}

# Rules are separate resources, so each has its own ID and description and can change independently.
resource "aws_vpc_security_group_egress_rule" "workstation_all" {
  security_group_id = aws_security_group.workstation.id
  description       = "Outbound to SSM, AWS APIs, GitHub and package mirrors"
  ip_protocol       = "-1" # every protocol
  cidr_ipv4         = "0.0.0.0/0"
}

# --- The machine ------------------------------------------------------------------------------------

resource "aws_instance" "workstation" {
  # `insecure_value` is the plain value of the SSM parameter. The normal `.value` is marked sensitive,
  # which would hide the AMI ID in every plan; a public AMI ID is not a secret.
  ami                    = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  instance_type          = var.workstation_instance_type
  subnet_id              = aws_subnet.ops_public.id
  vpc_security_group_ids = [aws_security_group.workstation.id]
  iam_instance_profile   = aws_iam_instance_profile.workstation.name

  # This subnet has no NAT gateway, so the machine needs its own public IP to reach the SSM endpoints.
  # Nothing can connect in, because the security group has no inbound rule.
  associate_public_ip_address = true

  # Passed to cloud-init and run once as root on first boot. path.module is this file's folder.
  user_data = file("${path.module}/workstation-init.sh")

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only: reading instance credentials needs a token obtained with a PUT, which a simple
    # "fetch this URL" bug in an application cannot do.
    http_tokens = "required"
    # The metadata answer may travel one hop, so the host can read it but a container on it cannot.
    # The cluster nodes use 2, because pods there do need it.
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.workstation_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project}-ops-workstation"
  }

  # Terraform sees no reference between the instance and the route, but cloud-init starts downloading
  # immediately: without a route to the internet gateway the boot script fails.
  depends_on = [aws_route_table_association.ops_public]

  lifecycle {
    # Both values change over time (Canonical publishes new images; you edit the script). Without this,
    # a new AMI would replace the machine you are working on, and an edited script would stop and
    # restart it. To apply a new script deliberately: terraform apply -replace=aws_instance.workstation
    ignore_changes = [ami, user_data]
  }
}
```

Create `infra/terraform/bootstrap/workstation-init.sh`:
```bash
#!/bin/bash
# cloud-init user data for the ops workstation. Runs once, as root, on first boot.
# Progress: /var/log/cloud-init-output.log. Finished when /var/log/workstation-ready exists.
#
#   -e  stop at the first failing command, instead of continuing on a broken machine
#   -u  an undefined variable is an error, not an empty string
#   -x  print each command, so the log shows exactly where it stopped
#   -o pipefail  a failure anywhere in a pipeline fails the pipeline
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive # apt never stops to ask: nobody is here to answer

# Pinned versions: rebuilding this machine installs exactly the same tools.
TERRAFORM_VERSION=1.16.2
KUBECTL_VERSION=v1.35.8
HELM_VERSION=v4.3.0
COSIGN_VERSION=v3.1.3
YQ_VERSION=v4.53.6
GH_VERSION=2.100.0

# On first boot unattended-upgrades holds the apt/dpkg lock: wait for it, and retry the index update.
# If all 20 attempts fail the loop still exits 0, so the install continues on a stale package index.
APT="apt-get -o DPkg::Lock::Timeout=600"
for i in $(seq 20); do $APT update && break; sleep 15; done
# python3-boto3 is what Ansible's AWS modules and its SSM connection plugin need later.
$APT install -y git make unzip jq curl ca-certificates bash-completion tmux \
  docker.io docker-buildx ansible python3-boto3 python3-botocore
# Lets you run docker without sudo. It applies at the next login, hence `sudo su - ubuntu`.
usermod -aG docker ubuntu

# 2 GB of RAM is enough for day-to-day work but tight while Terraform plans the cluster stack,
# so add swap rather than a bigger instance.
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab

# Default region for the AWS CLI and Terraform, read from instance metadata.
# 169.254.169.254 is reachable only from the instance itself. The PUT first, then the token header,
# is IMDSv2, required by http_tokens = "required".
IMDS_TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/placement/region)
# Every login shell exports it, so no AWS command needs --region.
echo "export AWS_REGION=${REGION} AWS_DEFAULT_REGION=${REGION}" > /etc/profile.d/aws-region.sh

cd "$(mktemp -d)" # work in a throwaway folder

# Each download below is checked against the checksum file published with the release:
#   curl -f fail on HTTP errors, -s silent, -S still show real errors, -L follow redirects, -O keep the name
#   grep ... | sha256sum -c -   picks this file's line out of the checksum list and verifies it

# Terraform
curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
grep " terraform_${TERRAFORM_VERSION}_linux_amd64.zip$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -
unzip -o "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" terraform -d /usr/local/bin

# kubectl
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  kubectl" | sha256sum -c -
install -m 0755 kubectl /usr/local/bin/kubectl # copy and set the executable bit in one step

# Helm: --strip-components=1 drops the leading folder of the archive
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz" --strip-components=1 -C /usr/local/bin linux-amd64/helm

# cosign
curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt"
grep " cosign-linux-amd64$" cosign_checksums.txt | sha256sum -c -
install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign

# yq: its checksum file uses the BSD format, so sed rewrites the line into "<hash>  <file>"
curl -fsSLO "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
curl -fsSLO "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums-bsd"
grep "^SHA256 (yq_linux_amd64) " checksums-bsd | sed 's/^SHA256 (\(.*\)) = \(.*\)$/\2  \1/' | sha256sum -c -
install -m 0755 yq_linux_amd64 /usr/local/bin/yq

# GitHub CLI
curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.deb"
curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"
grep " gh_${GH_VERSION}_linux_amd64.deb$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c -

# AWS CLI v2 and the Session Manager plugin, needed by Ansible over SSM and by the kubectl tunnel.
# Both come from AWS's own vendor URLs, which publish no SHA256 checksum file (the AWS CLI has only a
# detached GPG signature).
curl -fsSL -o awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q awscliv2.zip
./aws/install --update
curl -fsSLO https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb

# Installed through apt, not `dpkg -i`, because only apt waits for the dpkg lock. With set -e a locked
# dpkg would abort the whole script.
$APT install -y ./session-manager-plugin.deb "./gh_${GH_VERSION}_linux_amd64.deb"

touch /var/log/workstation-ready # the finish flag checked in step 5 of the guide
```

Create `infra/terraform/bootstrap/install-terraform.sh`:
```bash
#!/usr/bin/env bash
# Installs Terraform into ~/bin. Used once in AWS CloudShell, which has no Terraform, to create the
# workstation that does. No -x here: you run this by hand, so keep the output quiet unless it fails.
set -euo pipefail

VERSION="${TERRAFORM_VERSION:-1.16.2}" # use the environment variable if set, otherwise this default

# Pick the right build, and refuse anything else instead of downloading a binary that cannot run.
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$HOME/bin"  # the guide adds this folder to PATH
cd "$(mktemp -d)"     # download into a throwaway folder: the CloudShell home holds only 1 GB

curl -fsSLO "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_${ARCH}.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_SHA256SUMS"
grep " terraform_${VERSION}_linux_${ARCH}.zip$" "terraform_${VERSION}_SHA256SUMS" | sha256sum -c -
unzip -o "terraform_${VERSION}_linux_${ARCH}.zip" terraform -d "$HOME/bin" # extract only the binary
"$HOME/bin/terraform" version
```

Create `infra/terraform/bootstrap/outputs.tf`:
```hcl
# Printed after `apply`, and readable later with `terraform output -raw <name>`.
# These three are what the rest of the project needs from this stack.

output "region" {
  value = var.region
}

# The backend of the shared and cluster stacks: `make init` passes it with -backend-config.
output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

# Used to find the machine in the console, and for `aws ssm start-session --target <id>`.
output "workstation_instance_id" {
  value = aws_instance.workstation.id
}
```

**Why:**
- **Its own small VPC (`10.20.0.0/24`):** the workstation does not depend on the default VPC, which anyone in the account can change (in this account it has no subnets). The range does not overlap the cluster VPC (`10.10.0.0/16`).
- **Public IP but no inbound rule:** the SSM agent must reach AWS over the internet (there is no NAT here), but nothing can connect in.
- **No key pair, IMDSv2 required:** no SSH key to leak, and the instance credentials cannot be read through a simple SSRF request.
- **`AdministratorAccess`:** Terraform creates many kinds of resources. It is a lab trade-off: anyone allowed to start an SSM session on this instance gets admin rights, which is recorded in the design doc risks.
- **AMI from Canonical's SSM parameter:** always the latest Ubuntu 24.04. `ignore_changes = [ami, user_data]` stops Terraform from replacing the workstation every time Canonical publishes a new image.
- **Pinned versions with checksum verification:** rebuilding the workstation gives the same, untampered tools.

Commit with the scripts marked executable (Windows does not keep the executable bit):
```bash
git add infra
git update-index --chmod=+x infra/terraform/bootstrap/install-terraform.sh infra/terraform/bootstrap/workstation-init.sh
git commit -m "Add ops workstation to the bootstrap stack"
git push
```

**Verify:** `git ls-files -s infra/terraform/bootstrap/*.sh` shows mode `100755` for both scripts.

---

### Step 4 — Apply the bootstrap stack (CloudShell)

**Goal:** create the state bucket and the workstation.

1. Sign in to the AWS Console as `devops-lab-user` (with MFA). Select region **Asia Pacific (Singapore) ap-southeast-1**.
2. Open **CloudShell** (the terminal icon in the top bar). Check which plan the account is on:
   ```bash
   aws freetier get-account-plan-state
   ```
   If `accountPlanType` is `FREE`, AWS refuses to launch any instance type that is not free-tier
   eligible, whatever credits you have. This project therefore uses `t3.small` for the workstation and
   `m7i-flex.large` for the nodes. To see the full list:
   ```bash
   aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
     --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' --output table
   ```
   A paid plan removes the restriction; check what happens to your remaining credits in the Billing
   console before upgrading.
3. Prepare the shell. The AWS provider is about 830 MB unpacked and the CloudShell home folder holds only 1 GB, so Terraform's working data goes to `/tmp`:
   ```bash
   df -h /tmp            # needs at least 2 GB available
   export TF_DATA_DIR=/tmp/tf-bootstrap
   export PATH="$HOME/bin:$PATH"
   ```
   **Both exports are lost when the CloudShell session ends.** Run them again in every new session
   before any `terraform` command, or the provider lands in the 1 GB home folder and the download
   fails with `no space left on device`.
4. Get the code and install Terraform:
   ```bash
   git clone https://github.com/biabeogo147/Medical-RAG-Chatbot.git ~/Medical-RAG-Chatbot
   cd ~/Medical-RAG-Chatbot
   ./infra/terraform/bootstrap/install-terraform.sh
   ```
5. Initialise, check and apply:
   ```bash
   cd infra/terraform/bootstrap
   terraform init
   terraform fmt -check && terraform validate
   terraform plan -out tfplan      # read it: 18 to add, 0 to change, 0 to destroy
   terraform apply tfplan
   ```

**Why `plan -out` then `apply tfplan`:** Terraform applies exactly the plan you read, even if something changed in between.

**Verify:**
```bash
BUCKET=$(terraform output -raw state_bucket)
aws s3api get-bucket-versioning --bucket "$BUCKET"          # "Status": "Enabled"
aws s3api get-public-access-block --bucket "$BUCKET"        # all four flags true
aws s3 ls "s3://$BUCKET" --endpoint-url http://s3.ap-southeast-1.amazonaws.com   # AccessDenied (TLS-only policy)
terraform output workstation_instance_id
```

**Keep this CloudShell tab open:** `/tmp` is cleared when the session ends, and step 6 continues here. If the tab was closed, redo 4.3, then `cd ~/Medical-RAG-Chatbot/infra/terraform/bootstrap && terraform init`.

---

### Step 5 — Connect to the workstation (Session Manager)

**Goal:** confirm the workstation is ready and uses its IAM role.

1. Wait about 5 minutes after the apply for cloud-init to finish.
2. Console → **EC2 → Instances** → `medical-rag-ops-workstation` → **Connect** → **Session Manager** → **Connect**.
3. Session Manager logs in as `ssm-user`. Switch to `ubuntu` and start a `tmux` session, so a long `terraform apply` survives a dropped browser session:
   ```bash
   sudo su - ubuntu
   tmux new -As tf
   ```

**Verify:**
```bash
ls /var/log/workstation-ready                     # exists (if not: tail -f /var/log/cloud-init-output.log)
terraform version && ansible --version | head -1 && kubectl version --client && helm version --short
docker version --format '{{.Server.Version}}' && cosign version | head -3 && yq --version && gh --version | head -1
aws sts get-caller-identity --query Arn --output text   # ...assumed-role/medical-rag-ops-workstation/i-...
echo "$AWS_REGION"                                     # ap-southeast-1
```

**If a tool is missing:** read `/var/log/cloud-init-output.log`. Fix `workstation-init.sh` on the laptop and push. Then in CloudShell (redo 4.3 if the tab was closed):
```bash
cd ~/Medical-RAG-Chatbot && git pull
cd infra/terraform/bootstrap && terraform init
terraform apply -replace=aws_instance.workstation
```

---

### Step 6 — Move the bootstrap state into S3 (laptop + CloudShell)

**Goal:** the bootstrap state no longer lives only in CloudShell, where it could be lost.

On the laptop, create `infra/terraform/bootstrap/backend.tf`:
```hcl
# Added after the first apply (step 6). bucket and region are passed with -backend-config.
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
```

```bash
git add infra
git commit -m "Store bootstrap state in S3"
git push
```

In the CloudShell tab from step 4:
```bash
cd ~/Medical-RAG-Chatbot && git pull
cd infra/terraform/bootstrap
terraform init -migrate-state \
  -backend-config="bucket=medical-rag-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  -backend-config="region=ap-southeast-1"
# Answer "yes" to copy the existing state to the new backend.
```

**Verify:**
```bash
aws s3 ls "s3://medical-rag-tfstate-$(aws sts get-caller-identity --query Account --output text)/bootstrap/"   # terraform.tfstate
terraform plan                                       # No changes.
rm -f terraform.tfstate terraform.tfstate.backup     # the local copy is no longer used
```

**Account hygiene (Console, once):**
- **Billing and Cost Management → Cost allocation tags:** activate the `project` tag. It appears up to 24 hours after the first tagged resource exists. If the account belongs to an AWS Organization, only the management account can activate it. Until it is active, the budget in step 8 stays at 0.
- **IAM → Users → devops-lab-user → Security credentials:** deactivate the access key on your laptop. From now on you work in the Console and on the workstation.

**Rule from now on:** change the bootstrap stack only from CloudShell, never from the workstation. A mistake could replace the machine you are working on. To work on it again later in CloudShell:
```bash
export TF_DATA_DIR=/tmp/tf-bootstrap PATH="$HOME/bin:$PATH"
cd ~/Medical-RAG-Chatbot && git pull
cd infra/terraform/bootstrap
terraform init \
  -backend-config="bucket=medical-rag-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  -backend-config="region=ap-southeast-1"
```

---

## The loop for every workstation step

From step 7 on, every step repeats this loop:

1. **Laptop:** create or edit the files, commit, push.
2. **Workstation:** open Session Manager (step 5.2), then:
   ```bash
   sudo su - ubuntu
   tmux new -As tf                        # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot && git pull
   ```
3. **Workstation:** run the `make` targets of the step. Read the plan before answering `yes`.
4. **Workstation:** run the checks of the step.

Session Manager disconnects after about 20 idle minutes. Shell variables such as `$VPC` are lost with it, so each check block sets the variables it needs.

---

## Part B — Shared stack (kept)

### Step 7 — Makefile, GitHub access and the shared stack skeleton

**Goal:** the workstation can push to GitHub, and the shared stack is connected to the S3 state.

Create `Makefile` at the repo root. **Recipe lines must start with a tab, not spaces.**
```makefile
SHELL := /bin/bash

REGION       ?= ap-southeast-1
PROJECT      ?= medical-rag
ACCOUNT_ID   := $(shell aws sts get-caller-identity --query Account --output text)
BACKEND      := -backend-config="bucket=$(PROJECT)-tfstate-$(ACCOUNT_ID)" -backend-config="region=$(REGION)"
SHARED       := terraform -chdir=infra/terraform/shared
CLUSTER      := terraform -chdir=infra/terraform/cluster

.PHONY: shared-init shared-plan shared init plan infra infra-destroy

# Shared stack: registry, index artifacts, signing key, secrets, budget. Kept across rebuilds.
shared-init:
	$(SHARED) init -input=false $(BACKEND)

shared-plan: shared-init
	$(SHARED) plan

shared: shared-init
	$(SHARED) apply

# Cluster stack: network, nodes, load balancers. Destroyed when idle.
init:
	$(CLUSTER) init -input=false $(BACKEND)

plan: init
	$(CLUSTER) plan

infra: init
	$(CLUSTER) apply

infra-destroy: init
	$(CLUSTER) destroy
```

Create `infra/terraform/shared/versions.tf`:
```hcl
# Settings for Terraform itself. Only constants are allowed here: no variables.
terraform {
  # 1.10 is the first release with native S3 state locking (use_lockfile), used by this stack's backend.
  required_version = ">= 1.10"

  # Terraform core knows nothing about AWS. The provider plugin makes the API calls.
  # `terraform init` downloads it and records the exact version in .terraform.lock.hcl.
  required_providers {
    aws = {
      source = "hashicorp/aws" # short for registry.terraform.io/hashicorp/aws

      # "Pessimistic" operator: accepts 6.64, 6.65, 6.99 ... but never 7.0, which may break things.
      version = "~> 6.64"
    }
  }
}
```

Create `infra/terraform/shared/backend.tf`:
```hcl
# Where this stack's state is stored. A backend block cannot use variables, so the bucket name (which
# contains the account ID) is passed by `make shared-init` with -backend-config and stays out of Git.
terraform {
  backend "s3" {
    key = "shared/terraform.tfstate" # each stack has its own key in the same bucket

    # Terraform writes a .tflock object in S3 while it works, so two applies cannot run at once.
    # This replaces the DynamoDB lock table that older setups needed.
    use_lockfile = true
    encrypt      = true
  }
}
```

Create `infra/terraform/shared/providers.tf`:
```hcl
# Which region to call and which credentials to use. No key is configured: the provider
# uses the EC2 instance role of the ops workstation.
provider "aws" {
  region = var.region # var.<name> reads a variable declared in variables.tf

  # Tags added automatically to every resource created through this provider.
  default_tags {
    tags = {
      project    = var.project # the tag the AWS budget filters on, to separate this project's spend
      owner      = var.owner
      env        = "lab"
      stack      = "shared"    # says in the console which stack created a resource
      managed-by = "terraform" # a warning not to edit the resource by hand
    }
  }
}
```

Create `infra/terraform/shared/variables.tf`:
```hcl
# The inputs of the shared stack. budget_email has no default, so terraform.tfvars must set it.

variable "region" {
  description = "AWS region for every resource in this project."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as the resource name prefix and the project tag."
  type        = string
  default     = "medical-rag"
}

variable "owner" {
  description = "Value of the owner tag."
  type        = string
  default     = "devops-lab-user"
}

variable "budget_email" {
  description = "Email address that receives the budget alerts."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget. Alerts fire at 50% and 100% of it."
  type        = number
  default     = 100
}
```

Create `infra/terraform/shared/terraform.tfvars.example`:
```hcl
# Copy to terraform.tfvars (gitignored) and fill in.
budget_email = "you@example.com"

# Optional overrides
# monthly_budget_usd = 100
```

Create `infra/terraform/shared/main.tf`:
```hcl
# Lookups and computed values used by the other files of this stack.

data "aws_caller_identity" "current" {}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id # part of the globally unique bucket name
}
```

**Why:**
- **Partial backend configuration:** a `backend` block cannot use variables, so the bucket name (which contains the account ID) is passed by the Makefile. The account ID is never written in Git.
- **`use_lockfile = true`:** Terraform locks the state with a `.tflock` object in S3, so two applies cannot run at the same time. It replaces the old DynamoDB lock table.
- **`make shared` / `make infra` without `-auto-approve`:** Terraform always shows the plan and waits for `yes`.

**Run (first time on the workstation):**

1. Clone the repo and set your variables:
   ```bash
   git clone https://github.com/biabeogo147/Medical-RAG-Chatbot.git ~/Medical-RAG-Chatbot
   cd ~/Medical-RAG-Chatbot
   cp infra/terraform/shared/terraform.tfvars.example infra/terraform/shared/terraform.tfvars
   nano infra/terraform/shared/terraform.tfvars      # set budget_email
   make shared-plan      # No changes (no resources yet)
   make shared
   ```
2. Give the workstation push access to **this repo only**. On the laptop, open GitHub → Settings → Developer settings → **Fine-grained personal access tokens** → Generate:
   - Repository access: *Only select repositories* → `Medical-RAG-Chatbot`
   - Permissions: *Contents* → Read and write
   - Expiration: 30 days

   Then on the workstation:
   ```bash
   git config --global user.name "biabeogo147"
   git config --global user.email "<your GitHub noreply email>"   # GitHub → Settings → Emails
   gh auth login --with-token        # paste the token, press Enter, then Ctrl+D
   gh auth setup-git
   ```
3. Commit the provider lock file. It is generated here, on Linux, where Terraform runs:
   ```bash
   git add infra/terraform/shared/.terraform.lock.hcl
   git commit -m "Lock Terraform provider versions for the shared stack"
   git push
   ```
   Run `git pull` on the laptop afterwards.

**Verify:**
```bash
aws s3 ls "s3://medical-rag-tfstate-$(aws sts get-caller-identity --query Account --output text)/shared/"   # terraform.tfstate
```

---

### Step 8 — ECR, artifacts bucket, KMS key, secrets and budget

**Goal:** the long-lived services that CI and the cluster use, kept when the cluster is destroyed.

Create `infra/terraform/shared/registry.tf`:
```hcl
# The container registry for the app image. It lives in the shared stack because destroying the
# cluster must not delete images or the signatures that were made for them.
resource "aws_ecr_repository" "app" {
  name = local.name

  # A release tag (the git SHA) can never be overwritten, so what was scanned and signed is what runs.
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  # Two exceptions, because cosign and BuildKit must be able to overwrite these tags: legacy cosign
  # signature tags (sha256-*) and the BuildKit cache tag.
  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  image_tag_mutability_exclusion_filter {
    filter      = "buildcache*"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true # a free vulnerability scan of every pushed image
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  # Counts tagged images only. Cosign v3 stores signatures and SBOM attestations as untagged OCI
  # referrers, so a rule with tagStatus "any" would count them and could delete the signature of an
  # image that is still running.
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 tagged images"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["*"]
        countType      = "imageCountMoreThan"
        countNumber    = 20
      }
      action = { type = "expire" }
    }]
  })
}
```

Create `infra/terraform/shared/storage.tf`:
```hcl
# The bucket that holds the FAISS index versions. It is in the shared stack because embedding the
# corpus costs Hugging Face API quota and time: the cluster is rebuilt daily, the index is not.
resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.name}-artifacts-${local.account_id}" # bucket names are globally unique
  # No force_destroy: S3 rejects the delete while the bucket still holds objects, so destroy fails loudly.
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# An index file overwritten by mistake can be recovered.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-overwritten-objects"
    status = "Enabled"

    filter {}

    # Only replaced versions expire; the current index is kept forever.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

data "aws_iam_policy_document" "artifacts_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
```

Create `infra/terraform/shared/kms.tf`:
```hcl
# The key cosign signs images with. Asymmetric and SIGN_VERIFY, so the private half never leaves KMS:
# CI asks KMS to sign, and anyone can verify with the public half.
# It is kept across cluster rebuilds, because a new key would invalidate every existing signature.
resource "aws_kms_key" "cosign" {
  description              = "Cosign image signing key for ${var.project}"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7 # AWS enforces a waiting period before a key is really deleted
}

# A stable name for the key, so nothing has to reference the generated key ID:
#   cosign sign --key awskms:///alias/medical-rag-cosign
resource "aws_kms_alias" "cosign" {
  name          = "alias/${var.project}-cosign"
  target_key_id = aws_kms_key.cosign.key_id
}
```

Create `infra/terraform/shared/secrets.tf`:
```hcl
# Terraform creates empty secrets only: the names and who may read them. Values are set once with
#   aws secretsmanager put-secret-value --secret-id medical-rag/llm --secret-string '{...}'
# so they never appear in the Terraform state file or in Git. External Secrets syncs them into
# Kubernetes later.
resource "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github"]) # medical-rag/llm: Gemini + HF keys. medical-rag/github: bot token

  name = "${var.project}/${each.key}"

  # A deleted secret can still be restored for 7 days. That is also why the name cannot be reused
  # immediately after a destroy.
  recovery_window_in_days = 7
}
```

Create `infra/terraform/shared/bugdets.tf` (the repository keeps this historical filename):
```hcl
# An email when this project's spend crosses half and then all of the monthly budget.
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd) # the AWS API expects a string here
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # The account also hosts other projects, so only resources tagged project=medical-rag count.
  # In HCL "$${" is an escape sequence, so format() is the simplest way to write a literal "$".
  # This needs the "project" cost allocation tag to be activated in the billing console.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:project$%s", var.project)]
  }

  # dynamic generates one notification block per item, here 50% and 100% of the limit.
  # ACTUAL alerts on real spend; FORECASTED would also fire on predictions and cause false alarms.
  dynamic "notification" {
    for_each = [50, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
```

Create `infra/terraform/shared/ouputs.tf` (the repository keeps this historical filename):
```hcl
# What the cluster stack, CI and the Helm charts need from here.

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

# What CI signs with: cosign sign --key awskms:///alias/medical-rag-cosign
output "cosign_kms_key_alias" {
  value = aws_kms_alias.cosign.name
}

output "cosign_kms_key_arn" {
  value = aws_kms_key.cosign.arn
}

output "secret_names" {
  value = [for s in aws_secretsmanager_secret.app : s.name]
}
```

**Why:**
- **Why these are shared:** the FAISS index costs HF API quota to embed, secret values would have to be typed again, a new KMS key would invalidate every existing signature, and images would have to be rebuilt. None of that should happen on a daily teardown.
- **ECR `IMMUTABLE_WITH_EXCLUSION`:** a release tag (the git SHA) can never be overwritten, so what was scanned and signed is what runs. The build cache tag and legacy cosign tags must be rewritten, so they are excluded.
- **Lifecycle on tagged images only:** cosign v3 stores signatures as untagged OCI referrers. A rule counting all images could delete the signature of an image that is still running.
- **Artifacts bucket versioned:** an overwritten index file can be recovered for 30 days.
- **KMS `SIGN_VERIFY` / `ECC_NIST_P256`:** an asymmetric key that cosign uses through the AWS API. The private key never leaves KMS.
- **Empty secrets, 7-day recovery window:** Terraform creates only the names; values set with the CLI never enter the state or Git. A deleted secret can be restored for 7 days.
- **Budget filtered by `user:project$medical-rag`:** the account also hosts other projects; only this project's tagged resources count. In HCL `$${` is an escape sequence, so `format()` writes the literal `$`.
- **No `force_destroy` here:** Terraform refuses to delete a registry or bucket that still holds data.

**Run:** `make shared-plan` (expect 13 to add), then `make shared`.

**Verify:**
```bash
aws ecr describe-repositories --repository-names medical-rag \
  --query 'repositories[0].[imageTagMutability,imageScanningConfiguration.scanOnPush]'   # IMMUTABLE_WITH_EXCLUSION, true
ART=$(terraform -chdir=infra/terraform/shared output -raw artifacts_bucket)
aws s3 ls "s3://$ART" --endpoint-url http://s3.ap-southeast-1.amazonaws.com   # AccessDenied: plain HTTP is refused
aws kms describe-key --key-id alias/medical-rag-cosign --query 'KeyMetadata.[KeyUsage,KeySpec]'   # SIGN_VERIFY, ECC_NIST_P256
aws secretsmanager list-secrets --query 'SecretList[?starts_with(Name, `medical-rag/`)].Name'   # medical-rag/github, medical-rag/llm
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount]'                                        # medical-rag-monthly, 100.0
```

---

## Part C — Cluster stack (destroyed when idle)

### Step 9 — Cluster stack skeleton

**Goal:** the cluster stack is connected to the S3 state and can find the shared resources.

Create `infra/terraform/cluster/versions.tf`:
```hcl
# Settings for Terraform itself. Only constants are allowed here: no variables.
terraform {
  # 1.10 is the first release with native S3 state locking (use_lockfile), used by this stack's backend.
  required_version = ">= 1.10"

  # Terraform core knows nothing about AWS. The provider plugin makes the API calls.
  # `terraform init` downloads it and records the exact version in .terraform.lock.hcl.
  required_providers {
    aws = {
      source = "hashicorp/aws" # short for registry.terraform.io/hashicorp/aws

      # "Pessimistic" operator: accepts 6.64, 6.65, 6.99 ... but never 7.0, which may break things.
      version = "~> 6.64"
    }
  }
}
```

Create `infra/terraform/cluster/backend.tf`:
```hcl
# Where this stack's state is stored. The bucket name is passed by `make init` with -backend-config,
# because a backend block cannot use variables.
terraform {
  backend "s3" {
    key          = "cluster/terraform.tfstate"
    use_lockfile = true # a .tflock object in S3 stops two applies from running at the same time
    encrypt      = true
  }
}
```

Create `infra/terraform/cluster/providers.tf`:
```hcl
# Which region to call and which credentials to use. No key is configured: the provider
# uses the EC2 instance role of the ops workstation.
provider "aws" {
  region = var.region # var.<name> reads a variable declared in variables.tf

  # Tags added automatically to every resource created through this provider.
  default_tags {
    tags = {
      project    = var.project # the tag the AWS budget filters on, to separate this project's spend
      owner      = var.owner
      env        = "lab"
      stack      = "cluster"   # says in the console which stack created a resource
      managed-by = "terraform" # a warning not to edit the resource by hand
    }
  }
}
```

Create `infra/terraform/cluster/variables.tf`:
```hcl
# The inputs of the cluster stack. All have defaults, so no terraform.tfvars file is needed here.
# Override one for a single run with: terraform apply -var node_instance_type=c7i-flex.large

variable "region" {
  description = "AWS region for every resource in this project."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as the resource name prefix and the project tag."
  type        = string
  default     = "medical-rag"
}

variable "owner" {
  description = "Value of the owner tag."
  type        = string
  default     = "devops-lab-user"
}

variable "vpc_cidr" {
  description = "CIDR of the cluster VPC. Must not overlap the Calico pod CIDR."
  type        = string
  default     = "10.10.0.0/16" # must not overlap the ops VPC (10.20.0.0/24) or the Calico pod CIDR
}

variable "node_count" {
  description = "Number of Kubernetes nodes. Each one is a control-plane node that also runs workloads."
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "EC2 instance type of the Kubernetes nodes."
  type        = string
  # kubeadm needs at least 2 vCPU and 2 GB. m7i-flex.large gives 2 vCPU and 8 GB and, unlike
  # t3.large, may be launched by an AWS Free plan account.
  default = "m7i-flex.large"
}

variable "node_volume_gb" {
  description = "Root volume size of each node, in GB."
  type        = number
  default     = 40
}

variable "api_port" {
  description = "Kubernetes API server port."
  type        = number
  default     = 6443
}

variable "ingress_http_nodeport" {
  description = "NodePort of ingress-nginx for HTTP, targeted by the public NLB."
  type        = number
  default     = 30080 # ingress-nginx will listen here on every node
}
```

Create `infra/terraform/cluster/main.tf`:
```hcl
# Lookups and computed values shared by every file of this stack.

data "aws_caller_identity" "current" {}

# opt-in-not-required filters out Local Zones and AZs that must be enabled by hand.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id
  azs        = slice(data.aws_availability_zones.available.names, 0, 3) # the first three AZs, whatever node_count is

  # cidrsubnet(10.10.0.0/16, 8, n) gives /24 blocks:
  # 10.10.1.0/24, 10.10.2.0/24, 10.10.3.0/24 for the nodes,
  # 10.10.101.0/24 ... for the load balancers and the NAT gateway.
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 101)]
}

# --- Resources of the shared stack, looked up by name ------------------------------------------------
# The two stacks share no state file. If the shared stack is missing, `terraform plan` fails here
# instead of building half a cluster.

data "aws_ecr_repository" "app" {
  name = var.project
}

data "aws_s3_bucket" "artifacts" {
  bucket = "${var.project}-artifacts-${local.account_id}"
}

# Reading the alias, not the key, means the key can be rotated without touching this code.
data "aws_kms_alias" "cosign" {
  name = "alias/${var.project}-cosign"
}

data "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github"])

  name = "${var.project}/${each.key}"
}
```

Create `infra/terraform/cluster/outputs.tf` with one output for now:
```hcl
output "region" {
  value = var.region
}
```

**Why:**
- **`data` sources instead of a remote state:** the cluster looks up shared resources by name. The two stacks share no state file, and the shared stack can change internally without breaking the cluster.
- **A failed lookup is a useful error:** if the shared stack is missing, `plan` stops at once with "not found" instead of creating a half-built cluster.

**Run:**
```bash
make plan      # Changes to Outputs only; no resources
make infra
git add infra/terraform/cluster/.terraform.lock.hcl
git commit -m "Lock Terraform provider versions for the cluster stack"
git push
```

**Verify:**
```bash
aws s3 ls "s3://medical-rag-tfstate-$(aws sts get-caller-identity --query Account --output text)/cluster/"   # terraform.tfstate
```

---

### Step 10 — Network

**Goal:** the cluster VPC across 3 Availability Zones: private subnets for the nodes, public subnets for the load balancers.

Create `infra/terraform/cluster/network.tf`:
```hcl
# The cluster network. A module is a folder of Terraform code published for reuse; this one is the
# community standard and creates the subnets, route tables, internet gateway, NAT gateway and its
# Elastic IP. It also adopts the VPC's default security group and route table (leaving both empty) and
# its default NACL (reset to allow-all).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7" # modules are pinned like providers

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets # the nodes: no route from the internet
  public_subnets  = local.public_subnets  # the public NLB and the NAT gateway

  # One NAT gateway for all three AZs instead of one per AZ: about 0.12 USD/hour cheaper. If its AZ
  # fails, nodes lose outbound internet, but the cluster keeps serving traffic.
  enable_nat_gateway      = true
  single_nat_gateway      = true
  map_public_ip_on_launch = false # nothing gets a public IP just by sitting in a public subnet
}

# A free gateway endpoint: S3 traffic (index artifacts, etcd backups, Ansible transfers) stays on the
# AWS network instead of going through the NAT gateway, which is billed per GB.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${local.name}-s3"
  }
}
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "vpc_id" {
  value = module.vpc.vpc_id
}
```

**Why:**

| Piece | Purpose |
|---|---|
| **Private subnets** `10.10.1-3.0/24` | Nodes have no public IP and cannot be reached from the internet |
| **Public subnets** `10.10.101-103.0/24` | The public NLB and the NAT gateway |
| **One NAT gateway** | Nodes download packages and call the Gemini/HF APIs. One NAT instead of three saves about 0.12 USD/hour. If its AZ fails, nodes lose outbound internet but the cluster keeps running |
| **S3 gateway endpoint** | S3 traffic stays inside AWS: free, and it does not go through the NAT |
| **VPC module** | `terraform-aws-modules/vpc` is the community standard. It creates most of this step's resources (subnets, route tables, internet gateway, NAT, Elastic IP) with tested defaults |

**Run:** `make plan` (expect 24 to add; the first run downloads the module), then `make infra`. The NAT gateway takes 1–2 minutes.

**Verify:**
```bash
VPC=$(terraform -chdir=infra/terraform/cluster output -raw vpc_id)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].[AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' --output table   # 6 subnets, 3 AZs
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC --query 'NatGateways[].State'   # ["available"]
```

---

### Step 11 — Security groups

**Goal:** firewalls that open only the ports the cluster needs.

Create `infra/terraform/cluster/security.tf`:
```hcl
# The baseline firewalls: three groups and eight rules. Step 18 adds the WireGuard group and five
# rules for VPN and private Rancher access. Rules are separate resources, so each
# has its own ID and description and can be changed without touching the others.
# Wherever possible a rule names another security group instead of an IP range: nodes can then be
# replaced and get new addresses without any rule needing an edit.

resource "aws_security_group" "nodes" {
  name        = "${local.name}-nodes"
  description = "Kubernetes nodes"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-nodes"
  }
}

resource "aws_security_group" "api_nlb" {
  name        = "${local.name}-api-nlb"
  description = "Internal NLB in front of the Kubernetes API"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-api-nlb"
  }
}

resource "aws_security_group" "ingress_nlb" {
  name        = "${local.name}-ingress-nlb"
  description = "Public NLB in front of ingress-nginx"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name}-ingress-nlb"
  }
}

# --- nodes ---

# The group refers to itself, so the rule means "from the other nodes and nothing else". All protocols,
# because the cluster needs etcd (2379-2380), kubelet (10250), the API (6443) and Calico VXLAN (UDP 4789).
resource "aws_vpc_security_group_ingress_rule" "nodes_from_nodes" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "Node to node: etcd, kubelet, API server, Calico VXLAN"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_api_from_nlb" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_port
  to_port                      = var.api_port
  description                  = "Kubernetes API from the internal NLB"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_http_from_nlb" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.ingress_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.ingress_http_nodeport
  to_port                      = var.ingress_http_nodeport
  description                  = "ingress-nginx NodePort from the public NLB"
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Outbound: AWS APIs, container registries, Gemini and Hugging Face APIs"
}

# --- internal API NLB ---

# Callers inside the VPC only: the nodes themselves, and later the SSM tunnel used by kubectl.
resource "aws_vpc_security_group_ingress_rule" "api_nlb_from_vpc" {
  security_group_id = aws_security_group.api_nlb.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = var.api_port
  to_port           = var.api_port
  description       = "Kubernetes API from inside the VPC (nodes, SSM tunnel)"
}

# A load balancer's own group also needs an egress rule, for forwarded traffic and health checks.
resource "aws_vpc_security_group_egress_rule" "api_nlb_to_nodes" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_port
  to_port                      = var.api_port
  description                  = "Forward and health-check to the API servers"
}

# --- public ingress NLB ---

# The only public inbound rule at this point. Step 18 also opens WireGuard UDP 51820, not TCP 443.
resource "aws_vpc_security_group_ingress_rule" "ingress_nlb_http" {
  security_group_id = aws_security_group.ingress_nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "HTTP from the internet"
}

resource "aws_vpc_security_group_egress_rule" "ingress_nlb_to_nodes" {
  security_group_id            = aws_security_group.ingress_nlb.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = var.ingress_http_nodeport
  to_port                      = var.ingress_http_nodeport
  description                  = "Forward and health-check to ingress-nginx"
}
```

**Why:**

| Rule | Reason |
|---|---|
| Nodes ← nodes, all traffic | etcd (2379–2380), kubelet (10250), API server (6443) and Calico VXLAN (UDP 4789) between the 3 nodes. The source is the group itself, so nothing else gets in |
| Nodes ← API NLB, 6443 | The internal load balancer forwards API calls and runs health checks |
| Nodes ← public NLB, 30080 | The public load balancer reaches ingress-nginx |
| API NLB ← VPC, 6443 | Only callers inside the VPC reach the API: the nodes and, later, the SSM tunnel |
| Public NLB ← internet, 80 | The only public inbound rule at this point in the guide |

- **Groups referenced instead of IP addresses:** rules keep working when nodes are replaced and get new IPs.
- **One resource per rule (`aws_vpc_security_group_*_rule`):** the current provider recommendation; each rule has its own ID and description.

**Run:** `make plan` (expect 11 to add), then `make infra`.

**Verify:**
```bash
VPC=$(terraform -chdir=infra/terraform/cluster output -raw vpc_id)
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC \
  --query 'SecurityGroups[].GroupName'                     # 4 groups: nodes, api-nlb, ingress-nlb + default
SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC --query 'SecurityGroups[].GroupId' --output text | tr '\t' ',')
aws ec2 describe-security-group-rules --filters Name=group-id,Values=$SGS \
  --query 'SecurityGroupRules[?CidrIpv4==`0.0.0.0/0` && !IsEgress].[GroupId,FromPort,ToPort]' --output table   # only port 80 before step 18
```

---

### Step 12 — Cluster buckets and the node IAM role

**Goal:** the buckets that live with the cluster, and the permissions of the nodes, with no access key anywhere.

Create `infra/terraform/cluster/storage.tf`:
```hcl
# Buckets whose content is only useful while this cluster exists. The FAISS index lives in the shared
# stack instead, so a teardown never throws it away.
locals {
  buckets = {
    etcd-backups = 14 # days to keep etcd snapshots
    ssm-transfer = 1  # days to keep the temporary files Ansible copies through SSM
  }
}

# for_each over the map creates one bucket per key, and the same protections are written once instead
# of twice. Each instance is addressed as aws_s3_bucket.this["etcd-backups"].
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = "${local.name}-${each.key}-${local.account_id}"
  force_destroy = true # lets `make infra-destroy` delete the bucket even with objects in it
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this # iterating over the resource keeps the same keys

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "expire-objects"
    status = "Enabled"

    filter {} # every object

    expiration {
      days = each.value # the number from the map above
    }
  }
}

# Same TLS-only rule as the state bucket: requests over plain HTTP are denied.
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [each.value.arn, "${each.value.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = data.aws_iam_policy_document.tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
```

Create `infra/terraform/cluster/iam.tf`:
```hcl
# What the nodes are allowed to do in AWS. They authenticate with this role, so no access key exists
# on any machine. Known limitation of a self-managed cluster: every pod on a node can reach the node's
# role, which is why each statement names its exact resources.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nodes" {
  name               = "${local.name}-nodes"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",          # Session Manager and Ansible over SSM
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy", # volumes for Jenkins and Prometheus
  ])

  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}

# The project-specific permissions, written as one inline policy.
data "aws_iam_policy_document" "nodes" {
  # The only action in this policy AWS cannot scope to a repository: it is registry-wide.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Pull for the nodes, push for the Jenkins build pods. This repository only.
  statement {
    sid = "EcrPullPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }

  # Listing a bucket and reading its objects are different permissions on different ARNs, so both
  # statements are needed: the shared artifacts bucket plus the two cluster buckets.
  statement {
    sid       = "S3ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = concat([data.aws_s3_bucket.artifacts.arn], [for b in aws_s3_bucket.this : b.arn])
  }

  statement {
    sid       = "S3ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = concat(["${data.aws_s3_bucket.artifacts.arn}/*"], [for b in aws_s3_bucket.this : "${b.arn}/*"])
  }

  # Read by External Secrets, which turns them into Kubernetes Secrets.
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for s in data.aws_secretsmanager_secret.app : s.arn]
  }

  # Sign, not decrypt: the CI pipeline asks KMS to sign image digests with the cosign key.
  statement {
    sid       = "CosignSign"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [data.aws_kms_alias.cosign.target_key_arn]
  }
}

resource "aws_iam_role_policy" "nodes" {
  name   = "${local.name}-nodes"
  role   = aws_iam_role.nodes.id
  policy = data.aws_iam_policy_document.nodes.json
}

resource "aws_iam_instance_profile" "nodes" {
  name = "${local.name}-nodes"
  role = aws_iam_role.nodes.name
}
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "buckets" {
  value = { for k, b in aws_s3_bucket.this : k => b.bucket }
}
```

**Why:**
- **`for_each` over a map of buckets:** two buckets get the same protections without copying the code. Only the expiry differs.
- **`force_destroy = true`:** `make infra-destroy` can delete these buckets even with content; etcd snapshots of a deleted cluster are useless.

| Permission | Used by |
|---|---|
| `AmazonSSMManagedInstanceCore` | Session Manager and Ansible over SSM |
| `AmazonEBSCSIDriverPolicy` | The EBS CSI driver creates disks for Jenkins and Prometheus |
| ECR pull + push, **this repository only** | Nodes pull the app image; Jenkins BuildKit pods push it |
| S3, **the project's three buckets only** | Index artifacts, etcd backups, Ansible file transfers |
| Secrets Manager, **the two project secrets only** | External Secrets reads the API keys |
| KMS `Sign` / `GetPublicKey`, **the cosign key only** | Jenkins signs images |

- **Least privilege:** every statement names its exact resources, except `ecr:GetAuthorizationToken`, which AWS only supports on `*`.
- **Known limitation:** on a self-managed cluster every pod on a node can use the node's role. The design doc lists the mitigations (IMDS hop limit, NetworkPolicy).

**Run:** `make plan` (expect 15 to add), then `make infra`.

**Verify with the IAM policy simulator:**
```bash
ROLE_ARN=$(aws iam get-role --role-name medical-rag-nodes --query Role.Arn --output text)
KEY_ARN=$(terraform -chdir=infra/terraform/shared output -raw cosign_kms_key_arn)
aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" \
  --action-names kms:Sign --resource-arns "$KEY_ARN" \
  --query 'EvaluationResults[].EvalDecision'                      # ["allowed"]
aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" \
  --action-names s3:GetObject --resource-arns "arn:aws:s3:::some-other-bucket/file" \
  --query 'EvaluationResults[].EvalDecision'                      # ["implicitDeny"]
```

---

### Step 13 — Kubernetes nodes

**Goal:** 3 Ubuntu EC2 instances, one per Availability Zone, ready for Ansible.

Create `infra/terraform/cluster/compute.tf`:
```hcl
# The three Kubernetes machines. Terraform only creates them; Ansible turns them into a cluster.

data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "nodes" {
  count = var.node_count # creates nodes[0], nodes[1], nodes[2]

  ami           = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  instance_type = var.node_instance_type # 2 vCPU for kubeadm, 8 GB for Jenkins, Prometheus and the app

  # node 1 to AZ a, node 2 to AZ b, node 3 to AZ c. Losing one AZ leaves 2 of 3 etcd members, which
  # keeps quorum, so the cluster survives. There are always 3 subnets, so a 4th node would wrap onto
  # the first one again.
  subnet_id = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]

  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.nodes.name
  # No public IP and no key pair: the only way in is Session Manager.

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 2 hops, unlike the workstation's 1: pods run in their own network namespace, so External Secrets
    # and the EBS CSI driver need one extra hop to reach the metadata service.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.node_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-node-${count.index + 1}"
    # Ansible's aws_ec2 inventory selects the nodes by this tag, so no IP address is ever written down.
    k8s-cluster = local.name
  }

  lifecycle {
    # Canonical publishes new images constantly; without this every apply would replace the nodes.
    ignore_changes = [ami]
  }
}
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "node_instance_ids" {
  value = aws_instance.nodes[*].id
}

output "node_private_ips" {
  value = aws_instance.nodes[*].private_ip
}
```

**Why:**
- **`count` + `count.index % length(...)`:** node 1 goes to AZ a, node 2 to AZ b, node 3 to AZ c. Losing one AZ leaves 2 of 3 etcd members, which keeps quorum.
- **`m7i-flex.large` (2 vCPU, 8 GB):** kubeadm needs at least 2 vCPU and 2 GB; the rest is for Jenkins, Prometheus and the app. On an AWS Free plan account it is also one of the few types that may be launched at all (see the note in step 4).
- **No public IP, no key pair:** access is Session Manager only, through the NAT gateway.
- **`http_put_response_hop_limit = 2`:** IMDSv2 answers requests from inside pods (one extra network hop), which External Secrets and the EBS CSI driver need.
- **`k8s-cluster` tag:** Ansible finds the nodes by this tag, so no IP address is written in the inventory.

**Run:** `make plan` (expect 3 to add), then `make infra`.

**Verify** (the SSM agent needs 2–3 minutes after boot):
```bash
aws ssm describe-instance-information \
  --filters Key=tag:k8s-cluster,Values=medical-rag \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,PlatformVersion]' --output table   # 3 × Online, Ubuntu, 24.04
aws ec2 describe-instances --filters Name=tag:k8s-cluster,Values=medical-rag Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Placement.AvailabilityZone,PublicIpAddress,MetadataOptions.HttpTokens]' --output table   # 3 AZs, None, required
```

---

### Step 14 — Network Load Balancers

**Goal:** a stable internal address for the Kubernetes API and a public entry point for the app.

Create `infra/terraform/cluster/loadbalancers.tf`:
```hcl
# Two Network Load Balancers: one inside the VPC for the Kubernetes API, one facing the internet for
# the app. A target group is the list of machines behind a load balancer; a listener is the port it
# accepts traffic on.

# --- internal NLB: one stable address for the 3 API servers (kubeadm controlPlaneEndpoint) ---

resource "aws_lb" "api" {
  name               = "${local.name}-api"
  internal           = true # no public address
  load_balancer_type = "network"
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.api_nlb.id]

  # Each AZ's load balancer node may send traffic to targets in the other AZs, so an API server stays
  # reachable even if two of the three AZs have none running.
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api"
  port        = var.api_port
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # A node calling the API through the NLB can be routed back to itself. With client IP preservation
  # on, AWS drops that "hairpin" connection and kubeadm join and kubelet time out. Turning it off makes
  # the NLB the source address, which works. The API server does not need to see the real client IP.
  preserve_client_ip = false

  # /readyz answers 200 only when the API server is really ready, which is stricter than "port 6443 is
  # open". kubeadm allows anonymous access to it, and the NLB does not validate the certificate.
  health_check {
    protocol            = "HTTPS"
    path                = "/readyz"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = var.api_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Registers each node in the target group: one attachment per node.
resource "aws_lb_target_group_attachment" "api" {
  count = var.node_count

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.nodes[count.index].id
  port             = var.api_port
}

# --- public NLB: internet -> ingress-nginx NodePort ---

resource "aws_lb" "ingress" {
  name                             = "${local.name}-ingress"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = module.vpc.public_subnets
  security_groups                  = [aws_security_group.ingress_nlb.id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "ingress_http" {
  name        = "${local.name}-ingress-http"
  port        = var.ingress_http_nodeport # 30080, where ingress-nginx will listen on every node
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # A plain TCP check: ingress-nginx is not installed yet, so targets stay unhealthy until it is.
  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "ingress_http" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_http.arn
  }
}

resource "aws_lb_target_group_attachment" "ingress_http" {
  count = var.node_count

  target_group_arn = aws_lb_target_group.ingress_http.arn
  target_id        = aws_instance.nodes[count.index].id
  port             = var.ingress_http_nodeport
}
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "api_nlb_dns" {
  description = "kubeadm controlPlaneEndpoint (port 6443)"
  value       = aws_lb.api.dns_name
}

output "public_nlb_dns" {
  description = "Public HTTP entry point of the app"
  value       = aws_lb.ingress.dns_name
}
```

Your `infra/terraform/cluster/outputs.tf` should now match:
```hcl
# What the next phases read from this stack, with `terraform output -raw <name>`.

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

# Ansible finds the nodes by tag, so these are for your own checks.
output "node_instance_ids" {
  value = aws_instance.nodes[*].id # [*] collects the attribute from every instance of the resource
}

output "node_private_ips" {
  value = aws_instance.nodes[*].private_ip
}

output "api_nlb_dns" {
  description = "kubeadm controlPlaneEndpoint (port 6443)"
  value       = aws_lb.api.dns_name
}

output "public_nlb_dns" {
  description = "Public HTTP entry point of the app"
  value       = aws_lb.ingress.dns_name
}

# Used in the Helm values of the etcd backup CronJob and in the Ansible SSM connection settings.
output "buckets" {
  value = { for k, b in aws_s3_bucket.this : k => b.bucket }
}
```

**Why:**
- **Internal NLB :6443:** kubeadm's `controlPlaneEndpoint`. Clients use one DNS name; if an API server dies, the NLB stops sending traffic to it.
- **`preserve_client_ip = false` on the API target group:** a node calling the API through the NLB can be routed back to itself. With client IP preservation on, AWS drops that "hairpin" connection and `kubeadm join` times out.
- **Health check `HTTPS /readyz`:** a node counts as healthy only when its API server is ready, not just when port 6443 is open.
- **Public NLB :80 → NodePort 30080:** ingress-nginx, installed later, listens on that port on every node.
- **Security groups on the NLBs:** node rules reference the load balancer's group instead of broad IP ranges.

**Run:** `make plan` (expect 12 to add), then `make infra`. The NLBs take 2–3 minutes to become active.

**Verify:**
```bash
aws elbv2 describe-load-balancers --names medical-rag-api medical-rag-ingress \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,State.Code]' --output table   # internal + internet-facing, active
TG=$(aws elbv2 describe-target-groups --names medical-rag-api --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table   # 3 targets
```
**Target state:** `initial` for the first minute, then `unhealthy`. This is expected: nothing listens on 6443 or 30080 until Kubernetes and ingress-nginx are installed.

---

### Step 15 — Rebuild test and evidence

**Goal:** prove the cluster stack is reproducible, and record the numbers.

**Run:**
```bash
make plan                                                          # No changes.
terraform -chdir=infra/terraform/cluster state list | wc -l        # managed resources (65 + data sources)
time make infra-destroy                                            # answer yes
make shared-plan                                                   # No changes: shared resources untouched
time make infra                                                    # answer yes
make plan                                                          # No changes.
```

**Verify:** the second `make infra` succeeds without editing anything, and every `plan` reports `No changes`.

**Record** in `docs/evidence/terraform.md`: resource count, destroy time, apply time, and the output of the checks from steps 10–14.

**End of the session:** `make infra-destroy`, then stop the workstation.

---

## Part D — Private access to Rancher

Rancher is a cluster-admin UI, so TCP 443 is never exposed to the internet. Argo CD installs the
chart later; these steps create the persistent DNS and secrets, a WireGuard gateway, and a private
TCP path through the existing internal NLB.

The split follows the same rule as everywhere else. What must survive a teardown — the zone, the
certificate, password and VPN keys — goes in the **shared** stack. The gateway, internal listener
and DNS records are rebuilt with the **cluster** stack.

**Why a domain at all.** Rancher insists on being served at the root of its own hostname; it cannot
live under `/rancher` next to the app. With a name of its own, ingress-nginx routes by host and there
is no clash: `rancher.recruitai.io.vn` on 443 goes to Rancher, and the load balancer's own name on 80
still goes to the app.

### Step 16 — The zone and the private-access secrets

**Goal:** Route 53 owns the domain and the empty Rancher, TLS and WireGuard secrets survive every
cluster rebuild.

Create `infra/terraform/shared/rancher.tf`:
```hcl
# Persistent DNS and credentials for private Rancher access. Values are inserted later with the AWS
# CLI, never with Terraform, so private keys do not enter state.

# The hosted zone is here rather than in the cluster stack because a zone gets a new set of name
# servers every time it is created, and those name servers are typed in by hand at the domain
# registrar. Recreating it would mean repeating that step and waiting for the change to spread.
resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "Public names for ${var.project}"

  lifecycle {
    # The registrar points at this zone. Deleting it takes down every name under the domain until the
    # registrar is updated again.
    prevent_destroy = true
  }
}

# Three empty secrets, filled in once with `aws secretsmanager put-secret-value`:
#   <project>/rancher      {"bootstrapPassword": "..."}  the password for the first login
#   <project>/rancher-tls  {"tls.crt": "...", "tls.key": "..."}  the certificate bought from Sectigo
#   <project>/wireguard    {"serverPrivateKey": "...", "operatorPublicKey": "..."}
resource "aws_secretsmanager_secret" "rancher" {
  for_each = toset(["rancher", "rancher-tls", "wireguard"])

  name                    = "${var.project}/${each.key}"
  recovery_window_in_days = 7
}

variable "domain" {
  description = "Domain this stack owns the Route 53 zone for. Its name servers are set at the registrar."
  type        = string
  default     = "recruitai.io.vn"
}

# Enter these four at the registrar, once. They only change if the zone is recreated.
output "route53_name_servers" {
  value = aws_route53_zone.main.name_servers
}
```

Update `infra/terraform/shared/ouputs.tf` so the inventory lists all five names, never values:
```hcl
output "secret_names" {
  value = concat(
    [for s in aws_secretsmanager_secret.app : s.name],
    [for s in aws_secretsmanager_secret.rancher : s.name],
  )
}
```

The project owns `recruitai.io.vn`; choose a different domain only before the first `make shared`.
The zone has `prevent_destroy`, so changing it later is intentionally blocked.

**Why:**

- **The certificate is in Secrets Manager, not in Git and not in a Terraform variable.** Terraform
  creates the empty secret; the value goes in with one CLI call, so the private key never reaches
  the state file. External Secrets syncs it into the cluster later.

**Run:**
```bash
cd ~/Medical-RAG-Chatbot
make shared          # expect 4 to add (the zone and three secrets), plus the changed secret_names output
```

**Verify:**
```bash
terraform -chdir=infra/terraform/shared output route53_name_servers
aws secretsmanager list-secrets \
  --query 'SecretList[?starts_with(Name, `medical-rag/`)].Name' --output text
```
The output includes four Route 53 name servers and the empty `rancher`, `rancher-tls` and
`wireguard` secrets. Do not put values in them until the DNS inventory in step 17 is complete.

**Commit:** `git add infra/terraform/shared && git commit -m "Add private Rancher access secrets"`

---

### Step 17 — Migrate DNS and store the keys

**Goal:** the domain answers from Route 53 without losing any existing record, and the certificate,
the Rancher password and the WireGuard keys are stored before the cluster is built.

This step changes DNS and secret values, not code, so there is nothing to commit. It has four parts.
Do them in order; two of them end with a wait.

| Part | Where you work | Then wait |
|---|---|---|
| 17.1 Point the domain at Route 53 | Registrar website, AWS console, workstation | Minutes to hours |
| 17.2 Get the certificate from Sectigo | Workstation, Sectigo website, registrar website | Minutes to hours |
| 17.3 Put the certificate on the workstation and store it | Laptop, workstation | — |
| 17.4 Create the WireGuard keys | Laptop, workstation | — |

> **Coming back in a new Session Manager window?** Run `sudo su - ubuntu`, then `tmux new -As tf`.
> Every block below starts with the `cd` it needs.

#### 17.1 Point the domain at Route 53

**1. Registrar website — note the records you already have.** Open the DNS record list of
`recruitai.io.vn`. If you never added a record there (no website, no email, no verification record),
skip to 3. Otherwise write down each record's type, host, value and TTL. Leave out `rancher` and
`vpn`: Terraform creates those in step 18, and a copy would make it fail.

**2. AWS console — copy them into Route 53.** Open **Route 53 → Hosted zones → recruitai.io.vn →
Create record**, and enter each record from 1 with the same type, host, value and TTL.

**3. Workstation — check that DNSSEC is off.**
```bash
dig +short DS recruitai.io.vn @1.1.1.1
```
Empty output is the usual case: continue. If it prints something, DNSSEC is switched on at the
registrar. Switch it off in the registrar's DNSSEC settings, wait a day, and run the command again
until it prints nothing; otherwise every lookup for the domain fails once Route 53 starts answering.

**4. Change the name servers.** Workstation — print the four names:
```bash
cd ~/Medical-RAG-Chatbot
terraform -chdir=infra/terraform/shared output route53_name_servers
```
Registrar website — open the domain's **name server** setting. It is separate from the record list
and is usually called *Name servers* or *DNS servers*. Choose custom name servers, enter the four
names without quotes (and without a final dot, if the form rejects it), and save. Leave the old
records at the registrar untouched for 48 hours; you do not have to wait that long to continue.

**5. Workstation — verify**, a few minutes to a few hours later:
```bash
dig +short NS recruitai.io.vn @1.1.1.1
```
Expect the four `awsdns` names. `@1.1.1.1` asks Cloudflare's public DNS, so this is what the rest of
the internet sees. If you copied records in 2, check each one the same way: `dig +short <type>
<host>.recruitai.io.vn @1.1.1.1` must print the value you wrote down.

#### 17.2 Get the certificate from Sectigo

**1. Workstation — create the private key and the certificate request.** The `if` stops this from
replacing a key once a request exists for it: a new key would make the certificate Sectigo issues for
the old request useless. (A key left without a request, by a run that failed half-way, is simply
replaced.)
```bash
install -d -m 700 ~/tls/rancher.recruitai.io.vn
cd ~/tls/rancher.recruitai.io.vn
umask 077
if [ -e rancher.csr ]; then
  echo "STOP: rancher.csr already exists. Keep it and rancher.key; do not create new ones."
else
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout rancher.key -out rancher.csr \
    -subj "/CN=rancher.recruitai.io.vn" \
    -addext "subjectAltName=DNS:rancher.recruitai.io.vn"
fi
openssl req -in rancher.csr -noout -subject
openssl req -in rancher.csr -noout -text | grep -A1 "Subject Alternative Name"
ls
```
Expect a subject naming `rancher.recruitai.io.vn`, the line `DNS:rancher.recruitai.io.vn`, and two
files: `rancher.csr`, the request you send to Sectigo, and `rancher.key`, the private key, which never
leaves this directory. There is no certificate yet: Sectigo creates it from the request.

**2. Order the certificate.** Workstation — print the request:
```bash
cat ~/tls/rancher.recruitai.io.vn/rancher.csr
```
Select everything from `-----BEGIN CERTIFICATE REQUEST-----` to `-----END CERTIFICATE REQUEST-----`
with the mouse, and copy it.

Sectigo website (or your reseller's) — start the certificate order and paste the request when asked.
For the server type choose *Other* or *Nginx*. For the validation method choose **DNS (CNAME)**, not
email or HTTP file.

**3. Add the validation record.** Sectigo shows a name such as `_1A2B3C4D.rancher.recruitai.io.vn` and
a value such as `5E6F7A8B.c3d4e5.sectigo.com`. Add the record in both places below, because some
resolvers may still ask the old name servers.

Registrar website — add a `CNAME` record. Most panels append the domain themselves, so enter the name
**without** `.recruitai.io.vn` (for example `_1A2B3C4D.rancher`), and the value as shown.

Workstation — first confirm that the domain has exactly one hosted zone:
```bash
aws route53 list-hosted-zones-by-name --dns-name recruitai.io.vn \
  --query "HostedZones[?Name=='recruitai.io.vn.'].Id" --output text
```
Expect one `/hostedzone/Z…`. Two IDs mean a second zone was created by hand; see Troubleshooting.

Paste **only this line** and press Enter. At the prompt, paste the **full** name from Sectigo, ending
in `.recruitai.io.vn`, and press Enter:
```bash
read -r -p "CNAME name: " DCV_NAME
```
Then **only this line**, the same way, for the value:
```bash
read -r -p "CNAME value: " DCV_VALUE
```
`read` waits for what you type next, so pasting a whole block would feed it the following command
instead. Now paste the rest:
```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name recruitai.io.vn \
  --query "HostedZones[?Name=='recruitai.io.vn.'].Id | [0]" --output text)
CHANGE_ID=$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query ChangeInfo.Id --output text --change-batch "$(jq -n \
    --arg name "$DCV_NAME" --arg value "$DCV_VALUE" \
    '{Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: "CNAME", TTL: 300,
      ResourceRecords: [{Value: $value}]}}]}')")
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
dig +short CNAME "$DCV_NAME" @1.1.1.1
dig +short CAA recruitai.io.vn @1.1.1.1
dig +short CAA rancher.recruitai.io.vn @1.1.1.1
```
Expect Sectigo's value from the first `dig`, and nothing from the two `CAA` lookups (or answers that
include `sectigo.com`). A `CAA` record that names another certificate authority blocks the order; see
Troubleshooting.

**4. Wait for Sectigo.** It checks the record every few minutes, and issuing can take a few hours.
You are done when the order page says *Issued* or the certificate email arrives.

#### 17.3 Put the certificate on the workstation and store it

Sectigo sends the certificate to you — usually a `.zip` by email, or a download on the order page — so
the files land on the laptop. Session Manager has no upload button, but certificates are plain text,
so you move them by pasting. You do not need to know which file is which: the workstation sorts them.

**1. Laptop — open the files.** Extract the `.zip`. Open every file ending in `.crt`, `.ca-bundle`,
`.cer` or `.pem` in Notepad (right-click → Open with → Notepad). Each holds one or more blocks from
`-----BEGIN CERTIFICATE-----` to `-----END CERTIFICATE-----`. A file that shows unreadable characters
instead is in binary form: download the *Nginx* or *PEM* format from the order page.

**2. Workstation — paste all of them into one file.** Run:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
cat > sectigo.pem <<'EOF'
```
The prompt changes to `>`. The shell is not stuck: it is writing everything you paste into
`sectigo.pem`. For each file from 1, press Ctrl+A and Ctrl+C in Notepad, paste into Session Manager
(Ctrl+V, or right-click → Paste), and press Enter. After the last file, type `EOF` and press Enter;
the normal prompt comes back. If something went wrong, press Ctrl+C and start this part again: the
file is written from scratch.

**3. Workstation — sort the certificates and check them.**
```bash
cd ~/tls/rancher.recruitai.io.vn
sed 's/-----END CERTIFICATE-----/&\n/' sectigo.pem \
  | awk '/-----BEGIN CERTIFICATE-----/ {n++} n {print > ("part-" n ".pem")}'
: > rancher.crt
: > ca-bundle.crt
for f in part-*.pem; do
  if openssl x509 -in "$f" -noout -checkhost rancher.recruitai.io.vn | grep -q "does match"; then
    cat "$f" >> rancher.crt
  else
    cat "$f" >> ca-bundle.crt
  fi
done
rm -f part-*.pem

grep -c "BEGIN CERTIFICATE" rancher.crt ca-bundle.crt
openssl x509 -in rancher.crt -noout -subject -issuer -enddate
openssl verify -untrusted ca-bundle.crt rancher.crt
if [ "$(openssl x509 -in rancher.crt -pubkey -noout | openssl sha256)" = \
     "$(openssl pkey -in rancher.key -pubout | openssl sha256)" ]; then
  echo "OK: the certificate matches rancher.key"
else
  echo "MISMATCH: this certificate was not issued for rancher.csr"
fi
```
The first half splits `sectigo.pem` into one file per certificate. It puts the one issued for
`rancher.recruitai.io.vn` into `rancher.crt`, and all the others — Sectigo's intermediate certificates,
which link yours to a root that browsers trust — into `ca-bundle.crt`. Expect:

- `rancher.crt:1`, and `ca-bundle.crt:` followed by 1 or more,
- a subject naming `rancher.recruitai.io.vn` and a Sectigo issuer,
- `rancher.crt: OK`, meaning the chain is complete,
- `OK: the certificate matches rancher.key`.

For `rancher.crt:0` or `MISMATCH`, see Troubleshooting.

**4. Workstation — store the certificate.** Safe to run again, for example after a renewal:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
awk 1 rancher.crt ca-bundle.crt > fullchain.crt
jq -n --rawfile crt fullchain.crt --rawfile key rancher.key \
  '{"tls.crt": $crt, "tls.key": $key}' > rancher-tls.json &&
  aws secretsmanager put-secret-value --secret-id medical-rag/rancher-tls \
    --secret-string file://rancher-tls.json
shred -u rancher-tls.json
aws secretsmanager get-secret-value --secret-id medical-rag/rancher-tls \
  --query SecretString --output text | jq -c 'keys'
```
Expect `["tls.crt","tls.key"]`. `fullchain.crt` is your certificate followed by the intermediates,
the order a web server sends them in. `awk 1` joins the files instead of `cat`, which glues
`-----END CERTIFICATE-----` to the next `-----BEGIN CERTIFICATE-----` whenever a file lacks a final
newline.

**5. Workstation — create the Rancher password.** The `if` makes this safe to run again: it never
replaces a password that already exists.
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
if aws secretsmanager get-secret-value --secret-id medical-rag/rancher >/dev/null 2>&1; then
  echo "The Rancher password already exists; nothing changed."
else
  openssl rand -base64 24 | jq -Rn '{bootstrapPassword: input}' > rancher-password.json &&
    aws secretsmanager put-secret-value --secret-id medical-rag/rancher \
      --secret-string file://rancher-password.json
  shred -u rancher-password.json
fi
```
You need the password at the first Rancher login, in the GitOps phase. This prints it on screen:
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/rancher \
  --query SecretString --output text | jq -r '.bootstrapPassword'
```

The certificate's private key now exists in two places: `rancher.key` in this directory, which only
`ubuntu` can open, and Secrets Manager. The GitOps phase adds a third, the `tls-rancher-ingress`
Secret.

#### 17.4 Create the WireGuard keys

WireGuard uses two key pairs, one for the laptop and one for the gateway. Each private key stays where
it was made; only the public keys are exchanged.

**1. Laptop — install WireGuard and create the laptop's key pair.** Install WireGuard for Windows from
<https://www.wireguard.com/install/> and open it. Click the arrow next to **Add Tunnel**, choose
**Add empty tunnel…**, name it `medical-rag`, copy the text after **Public key:**, and click
**Save**. The private key stays inside this tunnel. Step 18 edits this same tunnel. Do not create a
second one: it would get a new key that the gateway does not know.

**2. Workstation — install the WireGuard tools.**
```bash
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get -o DPkg::Lock::Timeout=600 install -y wireguard-tools
```

**3. Workstation — enter the laptop's public key.** Paste **only this line**, press Enter, paste the
public key from 1 at the prompt, and press Enter:
```bash
read -r -p "Laptop public key: " OPERATOR_PUBLIC_KEY
```

**4. Workstation — create the gateway's key pair and store it.**
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
if [[ ! $OPERATOR_PUBLIC_KEY =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
  echo "STOP: that is not a WireGuard public key. Copy it again from the app, then repeat part 3."
elif [ -e wireguard-server.pub ]; then
  echo "STOP: the gateway key already exists. To change the laptop key, see step 18."
else
  wg genkey | tee wireguard-server.key | wg pubkey > wireguard-server.pub
  if jq -n --rawfile serverPrivateKey wireguard-server.key --arg operatorPublicKey "$OPERATOR_PUBLIC_KEY" \
       '{serverPrivateKey: ($serverPrivateKey | rtrimstr("\n")), operatorPublicKey: $operatorPublicKey}' \
       > wireguard.json &&
     aws secretsmanager put-secret-value --secret-id medical-rag/wireguard \
       --secret-string file://wireguard.json; then
    echo "OK: the gateway key is stored"
  else
    echo "FAILED: nothing was stored. Run this block again."
    rm -f wireguard-server.pub
  fi
  shred -u wireguard.json wireguard-server.key
fi
aws secretsmanager get-secret-value --secret-id medical-rag/wireguard \
  --query SecretString --output text | jq -c 'keys'
cat wireguard-server.pub
```
Expect `OK: the gateway key is stored`, then `["operatorPublicKey","serverPrivateKey"]`, then one line:
the gateway's public key, which step 18 puts into the laptop's tunnel.

The gateway's private key is now only in Secrets Manager; the gateway copies it into
`/etc/wireguard/wg0.conf` when it first boots. Its public key stays in `wireguard-server.pub`, and
`cat ~/tls/rancher.recruitai.io.vn/wireguard-server.pub` shows it again at any time.

---

### Step 18 — WireGuard and the private Rancher entry point

**Goal:** the laptop's WireGuard tunnel connects, and the private Rancher name and TCP 443 listener
exist. Rancher itself answers only after `make bootstrap` in the GitOps phase.

**Laptop** — create the three files below, and change one line in `main.tf`.

Create `infra/terraform/cluster/wireguard.tf`:
```hcl
variable "wireguard_cidr" {
  description = "VPN address range. Must not overlap the VPC, pod or Service CIDRs."
  type        = string
  default     = "10.99.0.0/24"
}

variable "wireguard_instance_type" {
  description = "Small gateway type known to be launchable by this account's Free plan."
  type        = string
  default     = "t3.small"
}

data "aws_secretsmanager_secret" "wireguard" {
  name = "${var.project}/wireguard"
}

resource "aws_iam_role" "wireguard" {
  name               = "${local.name}-wireguard"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "wireguard_ssm" {
  role       = aws_iam_role.wireguard.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "wireguard" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [data.aws_secretsmanager_secret.wireguard.arn]
  }
}

resource "aws_iam_role_policy" "wireguard" {
  name   = "read-wireguard-secret"
  role   = aws_iam_role.wireguard.id
  policy = data.aws_iam_policy_document.wireguard.json
}

resource "aws_iam_instance_profile" "wireguard" {
  name = "${local.name}-wireguard"
  role = aws_iam_role.wireguard.name
}

resource "aws_security_group" "wireguard" {
  name        = "${local.name}-wireguard"
  description = "WireGuard gateway; no SSH"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "wireguard_udp" {
  security_group_id = aws_security_group.wireguard.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  description       = "WireGuard handshake; unauthenticated packets are discarded"
}

resource "aws_vpc_security_group_egress_rule" "wireguard_all" {
  security_group_id = aws_security_group.wireguard.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Secrets Manager, SSM and private VPC destinations"
}

resource "aws_instance" "wireguard" {
  ami                    = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  instance_type          = var.wireguard_instance_type
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  iam_instance_profile   = aws_iam_instance_profile.wireguard.name
  # Gives cloud-init internet access immediately. Attaching the EIP below swaps this temporary
  # address for the stable VPN endpoint a few seconds after boot, which drops any connection open at
  # that moment, so every network step in wireguard-init.sh is retried.
  associate_public_ip_address = true
  # source_dest_check stays at its default (on). The gateway SNATs everything from the tunnel, so every
  # packet on its network card carries its own address, and AWS has nothing to block.

  user_data = templatefile("${path.module}/wireguard-init.sh", {
    region         = var.region
    secret_id      = data.aws_secretsmanager_secret.wireguard.name
    server_address = "${cidrhost(var.wireguard_cidr, 1)}/${split("/", var.wireguard_cidr)[1]}"
    peer_address   = cidrhost(var.wireguard_cidr, 2)
    wireguard_cidr = var.wireguard_cidr
    vpc_cidr       = var.vpc_cidr
    vpc_resolver   = cidrhost(var.vpc_cidr, 2) # the Route 53 Resolver sits at the VPC range plus two
  })
  # A changed script or address must reach the gateway. Without this, AWS would stop the instance, swap
  # the user data and start it again, but cloud-init runs the script only on the first boot.
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${local.name}-wireguard" }
  lifecycle { ignore_changes = [ami] }
}

resource "aws_eip" "wireguard" {
  domain   = "vpc"
  instance = aws_instance.wireguard.id
  tags     = { Name = "${local.name}-wireguard" }
}

resource "aws_route53_record" "vpn" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "vpn.${var.domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.wireguard.public_ip]
}

output "wireguard_instance_id" {
  value = aws_instance.wireguard.id
}

output "wireguard_public_ip" {
  value = aws_eip.wireguard.public_ip
}

# The address to put in the client profile. It is derived from wireguard_cidr, so changing that
# variable changes the server, the peer and this value together.
output "wireguard_client_address" {
  value = "${cidrhost(var.wireguard_cidr, 2)}/32"
}
```

Create `infra/terraform/cluster/wireguard-init.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# The EIP is attached a few seconds after boot and replaces the public address, which drops any
# connection open at that moment. Every step that uses the network is therefore retried, and fails
# the script only after ten attempts.
retry() {
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    "$@" && return 0
    sleep 10
  done
  return 1
}

# On first boot unattended-upgrades holds the dpkg lock for minutes. Wait for it inside apt, as the
# workstation does, rather than failing fast and burning the retries.
APT="apt-get -o DPkg::Lock::Timeout=600"
retry $APT update
retry $APT install -y wireguard-tools jq unzip iptables

# AWS CLI v2 from AWS's own URL, as on the ops workstation. Ubuntu's awscli package is not v2.
cd /tmp
retry curl -fsSL -o awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q awscliv2.zip
./aws/install --update

umask 077
retry aws --region "${region}" secretsmanager get-secret-value \
  --secret-id "${secret_id}" --query SecretString --output text > /run/wireguard-secret.json
jq -e '.serverPrivateKey and .operatorPublicKey' /run/wireguard-secret.json >/dev/null
PRIVATE_KEY=$(jq -r .serverPrivateKey /run/wireguard-secret.json)
PEER_KEY=$(jq -r .operatorPublicKey /run/wireguard-secret.json)
rm -f /run/wireguard-secret.json
INTERFACE=$(ip route show default | awk '{print $5; exit}')

# The tunnel is for Rancher. From wg0 the gateway forwards only DNS to the VPC
# resolver and TCP 443 into the VPC; everything else is dropped, including the Kubernetes API on 6443.
# Replies are let back in, but nothing in the VPC can open a connection towards the laptop, and
# nothing from the tunnel reaches the gateway itself. The rules live in their own chain, so PostDown
# removes them cleanly.
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${server_address}
ListenPort = 51820
PrivateKey = $PRIVATE_KEY
PostUp = iptables -N WG_FWD
PostUp = iptables -A WG_FWD -d ${vpc_resolver}/32 -p udp --dport 53 -j ACCEPT
PostUp = iptables -A WG_FWD -d ${vpc_resolver}/32 -p tcp --dport 53 -j ACCEPT
PostUp = iptables -A WG_FWD -d ${vpc_cidr} -p tcp --dport 443 -j ACCEPT
PostUp = iptables -A WG_FWD -j DROP
PostUp = iptables -A FORWARD -i wg0 -j WG_FWD
PostUp = iptables -A FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j DROP
PostUp = iptables -A INPUT -i wg0 -j DROP
PostUp = iptables -t nat -A POSTROUTING -s ${wireguard_cidr} -o $INTERFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${wireguard_cidr} -o $INTERFACE -j MASQUERADE
PostDown = iptables -D INPUT -i wg0 -j DROP
PostDown = iptables -D FORWARD -o wg0 -j DROP
PostDown = iptables -D FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j WG_FWD
PostDown = iptables -F WG_FWD
PostDown = iptables -X WG_FWD

[Peer]
PublicKey = $PEER_KEY
AllowedIPs = ${peer_address}/32
EOF

chmod 600 /etc/wireguard/wg0.conf
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard.conf
sysctl --system
systemctl enable --now wg-quick@wg0
touch /var/log/wireguard-ready
```

Create `infra/terraform/cluster/rancher.tf`:
```hcl
# Private TCP 443 on the existing internal NLB. Rancher itself is installed later by Argo CD; this
# file only creates its network path and stable name.

variable "ingress_https_nodeport" {
  description = "NodePort of ingress-nginx for HTTPS, targeted by the internal NLB."
  type        = number
  default     = 30443
}

variable "domain" {
  description = "Domain of the Route 53 zone the shared stack created. Must match its `domain`."
  type        = string
  default     = "recruitai.io.vn"
}

# TLS passes through the NLB unchanged; the load balancer never terminates it and never sees the key.
resource "aws_lb_target_group" "ingress_https" {
  name        = "${local.name}-ingress-https"
  port        = var.ingress_https_nodeport
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # Rancher agents connect back through this NLB. Disabling preservation prevents a target that is
  # routed back to itself from failing NAT loopback. Rancher therefore sees NLB addresses, not the
  # client's; with a single WireGuard peer, any VPN session is that one operator.
  preserve_client_ip = false

  # Like the HTTP target group, a plain TCP check: the targets stay unhealthy until ingress-nginx is
  # installed, which does not happen until the GitOps phase.
  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "ingress_https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_https.arn
  }
}

resource "aws_lb_target_group_attachment" "ingress_https" {
  count = var.node_count

  target_group_arn = aws_lb_target_group.ingress_https.arn
  target_id        = aws_instance.nodes[count.index].id
  port             = var.ingress_https_nodeport
}

# TCP 443 is private. WireGuard SNATs the peer to the gateway's VPC address, and Rancher agents also
# originate inside the VPC.
resource "aws_vpc_security_group_ingress_rule" "api_nlb_https_from_vpc" {
  security_group_id = aws_security_group.api_nlb.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Private Rancher HTTPS from the VPC and WireGuard"
}

resource "aws_vpc_security_group_egress_rule" "api_nlb_to_nodes_https" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = var.ingress_https_nodeport
  to_port                      = var.ingress_https_nodeport
  description                  = "Forward and health-check to ingress-nginx TLS"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_ingress_https" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.ingress_https_nodeport
  to_port                      = var.ingress_https_nodeport
  description                  = "ingress-nginx TLS NodePort from the internal NLB"
}

# --- the name ----------------------------------------------------------------------------------------
data "aws_route53_zone" "main" {
  name         = "${var.domain}."
  private_zone = false
}

resource "aws_route53_record" "rancher" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "rancher.${var.domain}"
  type    = "A"

  # Internal load balancer names are publicly resolvable to private addresses. DNS works everywhere,
  # but only a client with a route into the VPC can connect: from outside, that means WireGuard.
  # Inside the VPC, Rancher's own agents connect to this name as well.
  alias {
    name    = aws_lb.api.dns_name
    zone_id = aws_lb.api.zone_id

    # With no healthy target there is nowhere else to send the query, so target health is not a
    # useful DNS signal here.
    evaluate_target_health = false
  }
}

output "rancher_url" {
  description = "The Rancher UI, once the GitOps phase has installed the chart"
  value       = "https://${aws_route53_record.rancher.name}"
}
```

Expand the workload secret lookup in `infra/terraform/cluster/main.tf`, so the nodes can read the two
Rancher secrets. The WireGuard secret is deliberately not in this list: of the roles in this stack,
only the gateway's can read it.
```hcl
data "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github", "rancher", "rancher-tls"])
  name     = "${var.project}/${each.key}"
}
```

Argo CD installs Rancher later; its chart pin, values, secret wiring and upgrade gate are in
[design §4.2.1](../selfmanaged-k8s-ops-design.md#421-rancher-gitops-contract-and-compatibility-gate).

**Why:**

- **A dedicated gateway** keeps internet-facing UDP away from the administrator workstation and its
  `AdministratorAccess` role.
- **The tunnel is for Rancher only.** Security groups open the internal NLB to the whole VPC, because
  Rancher's own agents need it, so without a filter the VPN would also reach the Kubernetes API on
  6443. The gateway forwards only DNS and TCP 443, and the internal NLB is the only 443 listener in
  the VPC. The laptop has no `kubectl` anyway; the API stays reachable through `make tunnel` on the
  workstation.
- **Public DNS, private addresses.** The internal NLB's name resolves publicly to private addresses,
  so normal DNS and a public certificate work, while the network path still requires WireGuard.
- **TLS passes through unchanged.** ingress-nginx holds the key, and Rancher's agents avoid NLB
  hairpin failures because the HTTPS target group disables client-IP preservation.

**Commit and push** (laptop):
`git add infra/terraform/cluster && git commit -m "Add private Rancher access through WireGuard" && git push`

**Run** (workstation):
```bash
cd ~/Medical-RAG-Chatbot && git pull
make infra
```
Expect **84 to add, 0 to change**: the cluster was destroyed at the end of step 15, so Terraform builds
the 65 resources of steps 9–14 plus the 19 new ones. If the cluster is still running from an earlier
session, expect 19 to add and 1 to change instead; the change is the node policy growing from two
secrets to four. Final baselines: 17 managed resources in `shared`, 84 in `cluster`.

**Finish the laptop's tunnel.** Workstation — print the two values the tunnel needs:
```bash
cat ~/tls/rancher.recruitai.io.vn/wireguard-server.pub
cd ~/Medical-RAG-Chatbot
terraform -chdir=infra/terraform/cluster output -raw wireguard_client_address; echo
```
The first line is the gateway's public key. The second is the laptop's VPN address, `10.99.0.2/32`
unless you changed `wireguard_cidr`.

Laptop, WireGuard app — select `medical-rag` and click **Edit**. Keep the `[Interface]` line and the
`PrivateKey = …` line exactly as they are, and add the rest, so that the tunnel reads:
```ini
[Interface]
PrivateKey = (already there — do not change this line)
Address = 10.99.0.2/32
DNS = 10.10.0.2

[Peer]
PublicKey = (the gateway's public key, from wireguard-server.pub)
Endpoint = vpn.recruitai.io.vn:51820
AllowedIPs = 10.10.0.0/16
PersistentKeepalive = 25
```
Click **Save**. Do not store this configuration in the repo.

- `AllowedIPs` sends only traffic for the cluster VPC through the tunnel; everything else uses your
  normal connection.
- `DNS = 10.10.0.2` is the VPC's own resolver. Without it the laptop keeps asking its home router, and
  many routers drop answers that point at private `10.10.x.x` addresses, so the Rancher name would not
  resolve. If browsing stalls while the gateway is down, deactivate the tunnel.
- Every cluster rebuild gives the gateway a new public address behind `vpn.recruitai.io.vn`. The
  profile stays the same, but deactivate and activate the tunnel so the new address is used.

**Verify.**

1. **Laptop:** in the WireGuard app, click **Activate** on `medical-rag`.
2. **Workstation:** check the gateway. After `make infra` it needs a few minutes to register with SSM
   and finish its setup, so the first command waits for that:
```bash
cd ~/Medical-RAG-Chatbot
WG_ID=$(terraform -chdir=infra/terraform/cluster output -raw wireguard_instance_id)
until [ "$(aws ssm describe-instance-information --filters Key=InstanceIds,Values="$WG_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text)" = Online ]; do
  echo "waiting for the gateway to register with SSM..."; sleep 15
done
COMMAND_ID=$(aws ssm send-command --instance-ids "$WG_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status --wait || true","test -f /var/log/wireguard-ready && echo READY","wg show","iptables -S WG_FWD"]' \
  --query 'Command.CommandId' --output text)
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$WG_ID"
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$WG_ID" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
```
Expect `Success`, `READY`, a `wg show` block with a recent `latest handshake`, and the firewall: the
`-N WG_FWD` line plus four rules (DNS over UDP and TCP, TCP 443, then `DROP`). If `wait` prints
`Max attempts exceeded`, run the `wait` line again. If it prints `terminal failure state`, run the last
command anyway: its output says what failed. No `latest handshake` means the laptop's tunnel was not
active yet: activate it and run the block again from `COMMAND_ID=`.

3. **Workstation:** check the listener and the names:
```bash
aws elbv2 describe-listeners \
  --load-balancer-arn $(aws elbv2 describe-load-balancers --names medical-rag-api \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text) \
  --query 'Listeners[].[Port,Protocol]' --output table
dig +short rancher.recruitai.io.vn
dig +short vpn.recruitai.io.vn
```
Expect two listeners, 6443 and 443, both `TCP`; `10.10.x.x` addresses for the Rancher name; and one
public address for the VPN name.

4. **Laptop, PowerShell** (tunnel active):
```powershell
Resolve-DnsName rancher.recruitai.io.vn
```
Expect `10.10.x.x` addresses. Nothing answers in the browser yet: TCP 443 has no service behind it
until the GitOps phase.

#### Later, after `make bootstrap` — skip this now

These checks need ingress-nginx and Rancher, which the GitOps phase installs.

**The certificate**, checked from the WireGuard gateway: the workstation has no route into the cluster
VPC, but the gateway has. Workstation:
```bash
cd ~/Medical-RAG-Chatbot
WG_ID=$(terraform -chdir=infra/terraform/cluster output -raw wireguard_instance_id)
PARAMS=$(jq -n --arg c 'openssl s_client -connect rancher.recruitai.io.vn:443 -servername rancher.recruitai.io.vn -verify_return_error </dev/null 2>&1 | grep -E "subject=|issuer=|Verify return code|verify error|errno|refused|timed out"; true' \
  '{commands: [$c]}')
COMMAND_ID=$(aws ssm send-command --instance-ids "$WG_ID" --document-name AWS-RunShellScript \
  --parameters "$PARAMS" --query 'Command.CommandId' --output text)
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$WG_ID"
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$WG_ID" \
  --query StandardOutputContent --output text
```
Expect a subject naming `rancher.recruitai.io.vn`, a Sectigo issuer and `Verify return code: 0 (ok)`
(it may appear twice). A `verify error`, `errno` or `timed out` line says what failed.

**The public load balancer does not serve Rancher.** Workstation:
```bash
cd ~/Medical-RAG-Chatbot
curl -sI -H 'Host: rancher.recruitai.io.vn' \
  "http://$(terraform -chdir=infra/terraform/cluster output -raw public_nlb_dns)/" | head -1
```
Expect `HTTP/1.1 308 Permanent Redirect`: the only answer is a redirect to an address the internet
cannot reach.

**The browser and the firewall**, on the laptop with the tunnel active: `https://rancher.recruitai.io.vn`
loads, and times out once you deactivate the tunnel. In PowerShell:
```powershell
Test-NetConnection rancher.recruitai.io.vn -Port 443    # TcpTestSucceeded : True
Test-NetConnection rancher.recruitai.io.vn -Port 6443   # TcpTestSucceeded : False
```
The Rancher name points at the internal load balancer, which also carries the Kubernetes API on 6443.
The gateway forwards only DNS and TCP 443, so 6443 stays closed.

#### Only if the laptop's WireGuard key is lost — skip this now

1. **Laptop (the new one):** in the WireGuard app, **Add empty tunnel…**, name it `medical-rag`, copy its
   public key and click **Save**. Complete it later as in *Finish the laptop's tunnel*.
2. **Workstation:** paste **only this line**, then the new public key at the prompt:
```bash
read -r -p "New laptop public key: " NEW_PUB
```
3. **Workstation:** store it in place of the old one:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
if [[ ! $NEW_PUB =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
  echo "STOP: that is not a WireGuard public key."
elif aws secretsmanager get-secret-value --secret-id medical-rag/wireguard \
       --query SecretString --output text \
     | jq -e --arg k "$NEW_PUB" '.operatorPublicKey = $k' > wg.json &&
     aws secretsmanager put-secret-value --secret-id medical-rag/wireguard \
       --secret-string file://wg.json; then
  echo "OK: the new laptop key is stored"
else
  echo "FAILED: nothing changed"
fi
shred -u wg.json 2>/dev/null
```
4. **Apply it.** The gateway reads the key only when it is created. If the cluster is destroyed (the
   usual state), nothing else is needed: the next `make infra` uses the new key. If it is running,
   replace only the gateway:
```bash
cd ~/Medical-RAG-Chatbot
make init
terraform -chdir=infra/terraform/cluster apply -replace=aws_instance.wireguard
```
The plan must show **1 to add, 1 to change, 1 to destroy**: the gateway is rebuilt, and its EIP moves
to the new instance, so the address and the `vpn` record stay the same. Afterwards the old key no
longer connects, and the new one does.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Error acquiring the state lock` | Another plan or apply is running, or one was interrupted. If nothing is running: `terraform -chdir=infra/terraform/cluster force-unlock <LOCK_ID>` (or `shared`) |
| `BucketAlreadyExists` in step 4 | The bucket name is taken. Check `project` and the account ID in the name |
| `make: *** missing separator` | A Makefile recipe line starts with spaces instead of a tab |
| `no matching ECR Repository found` or a similar lookup error in step 9 | The shared stack is missing or in another region: run step 8 first |
| `AccessDenied` on the workstation | `aws sts get-caller-identity` must show the workstation role |
| `Author identity unknown` on `git commit` | Run the `git config --global` lines of step 7 |
| `InvalidParameterCombination: The specified instance type is not eligible for Free Tier` | The account is on the AWS Free plan: only free-tier-eligible types may be launched. Use `t3.small` or `m7i-flex.large`, or upgrade the account to a paid plan |
| `InsufficientInstanceCapacity` | Temporary shortage in one AZ: retry later, or fall back to `c7i-flex.large` (4 GB, the only other free-tier type big enough) and cut Prometheus retention |
| `no space left on device` during `terraform init` in CloudShell | `TF_DATA_DIR` is not set: the AWS provider needs about 830 MB and the CloudShell home folder holds 1 GB. Run `rm -rf .terraform`, then the exports in step 4.3 again |
| Budget stays at 0 USD | The `project` cost allocation tag is not active (step 6) |
| `dig NS` still shows the registrar's name servers | The change has not propagated, or it was entered in the wrong place: it is the **name server** setting of the domain, not a record inside the zone |
| The hosted-zone check in 17.2 prints two zone IDs | A second zone for the domain was created by hand. Keep the one whose name servers match `terraform -chdir=infra/terraform/shared output route53_name_servers`; in the Route 53 console, delete the records of the other zone, then the zone |
| `InvalidChangeBatch … is not permitted in zone` | The CNAME name was entered without `.recruitai.io.vn`. Run the two `read` lines of 17.2 again with the full name |
| Sectigo stays *pending validation* | `dig +short CNAME <full name> @1.1.1.1` must print Sectigo's value. If it is empty, the name is missing in Route 53, or doubled at the registrar (`….recruitai.io.vn.recruitai.io.vn`). Check the validation method is DNS (CNAME) |
| A `CAA` lookup names another certificate authority | Delete that `CAA` record in Route 53 and at the registrar, or add one that allows `sectigo.com` |
| `rancher.crt:0` in 17.3 | None of the pasted certificates was issued for `rancher.recruitai.io.vn`. Check the order's domain, paste every file Sectigo sent, and repeat 17.3 |
| `unable to get local issuer certificate` in 17.3 | `ca-bundle.crt` is empty or incomplete: an intermediate file was not pasted. Repeat 17.3 with every file |
| `Could not read certificate` or `unable to load certificate` | A paste lost a `BEGIN` or `END` line. Repeat 17.3 |
| `MISMATCH` in 17.3 | The certificate was issued for a different request, usually because a new key was made after ordering. Reissue it on the Sectigo website with the current `rancher.csr` |
| `make infra` in step 18: `Tried to create resource record set … but it already exists` | A `rancher` or `vpn` record was copied into Route 53 in 17.1. Delete it in the console and run `make infra` again |
| `no matching Route 53 Hosted Zone found` in step 18 | Step 16 was not applied, or the two stacks use different domains |
| Existing records stopped resolving after step 17 | The DNS inventory was incomplete, or DNSSEC still has a stale DS record. Restore the missing records before continuing |
| WireGuard has no handshake | Check `vpn.recruitai.io.vn`, UDP 51820 and the server public key. If the tunnel was recreated on the laptop, it has a new key: store its public key again (see *Only if the laptop's WireGuard key is lost*) |
| VPN connects but `rancher.recruitai.io.vn` does not resolve | The profile is missing `DNS = 10.10.0.2`, so the home router answered and dropped the private address. Add the line and reconnect; in PowerShell, `Resolve-DnsName rancher.recruitai.io.vn -Server 10.10.0.2` must return `10.10.x.x` addresses |
| VPN connects but Rancher is unreachable | Confirm the client routes `10.10.0.0/16`, `iptables -S WG_FWD` on the gateway lists the 443 rule, and the internal NLB has a healthy 30443 target |
| Anything other than Rancher times out through the VPN | By design: the gateway forwards only DNS and TCP 443. Reach the Kubernetes API with `make tunnel` on the workstation |
| The gateway never prints `READY` | cloud-init failed after its retries. From the workstation, `aws ssm start-session --target "$WG_ID"`, then `sudo tail -50 /var/log/cloud-init-output.log`. A failure at `get-secret-value` usually means `medical-rag/wireguard` has no value yet (17.4) |
| `wg-quick` fails with `Chain already exists` | An earlier start stopped half-way. In a session on the gateway: `sudo iptables -D FORWARD -i wg0 -j WG_FWD; sudo iptables -F WG_FWD; sudo iptables -X WG_FWD; sudo systemctl restart wg-quick@wg0` |
| A node shows `ConnectionLost` in SSM | NAT gateway or route problem: check step 10, then reboot the instance |
