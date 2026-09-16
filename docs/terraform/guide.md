# Terraform guide

A step-by-step guide to build every AWS resource of this project with Terraform. Each file is commented, so the code you copy explains itself; the architecture overview is in [`README.md`](README.md) next to this file. Follow the steps in order: each one ends with a check, and the next step assumes it passed.

## How this guide works

**Where commands run.** Nothing is installed on your laptop.

| Where | What you do there |
|---|---|
| **Laptop:** editor + **Git Bash** | Write the files shown in each step, commit, push to GitHub |
| **AWS CloudShell** (browser) | The bootstrap stack only (steps 4 and 6) |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager in the browser | Everything else: `git pull`, `make`, checks |

> Run laptop git commands in **Git Bash** (installed with Git). Windows PowerShell 5.1 does not understand `&&`.

**Three Terraform stacks.** They are split by lifetime, so the daily teardown never deletes data that took time to build.

| Stack | Folder | Creates | Applied from | Lifetime |
|---|---|---|---|---|
| bootstrap | `infra/terraform/bootstrap/` | State bucket, ops workstation and its small VPC | CloudShell | Kept |
| shared | `infra/terraform/shared/` | ECR registry, index artifacts bucket, cosign KMS key, secrets, budget | Workstation | Kept |
| cluster | `infra/terraform/cluster/` | VPC, security groups, IAM, 3 nodes, 2 NLBs, etcd and SSM buckets | Workstation | **Destroyed when idle** |

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

## Cost

| What | When it costs | About |
|---|---|---|
| State bucket, artifacts bucket, ECR images | Always | < 0.50 USD/month |
| KMS key + 2 secrets | Always | 1.80 USD/month |
| Ops workstation (`t3.small`, 30 GB) | Hourly while running; disk always | 0.03 USD/hour + 2.90 USD/month |
| Cluster (3 × `m7i-flex.large`, NAT gateway, 2 NLBs, public IPs, 120 GB disks) | While it exists | **0.50 USD/hour** |

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

Create `infra/terraform/shared/budgets.tf`:
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

Create `infra/terraform/shared/outputs.tf`:
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
# The firewalls. Three groups, and eight rules between them. Rules are separate resources, so each
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

# The only inbound rule in the whole stack open to the internet.
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
| Public NLB ← internet, 80 | The only inbound rule open to `0.0.0.0/0` |

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
  --query 'SecurityGroupRules[?CidrIpv4==`0.0.0.0/0` && !IsEgress].[GroupId,FromPort,ToPort]' --output table   # only port 80
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
- **Known limitation:** on a self-managed cluster every pod on a node can use the node's role, and the IMDS hop limit is 2 precisely so pods can reach it. The mitigations are this tightly scoped policy and, later, a NetworkPolicy that blocks pod access to the metadata address.

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
| A node shows `ConnectionLost` in SSM | NAT gateway or route problem: check step 10, then reboot the instance |
