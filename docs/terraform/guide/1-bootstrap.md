# Terraform guide — Part 1: Bootstrap: state bucket and ops workstation (steps 1–6)

[Index](../guide.md) · [Part 2 →](2-shared-stack.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** an AWS account with an admin identity; git and an editor on the laptop.

**Done when:** step 6 — the bootstrap state lives in S3 and `terraform plan` shows `No changes`.

---

## Step 1 — Prepare the repo (laptop)

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

## Step 2 — Bootstrap: provider, variables and the state bucket (laptop)

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

## Step 3 — Bootstrap: the ops workstation (laptop)

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

## Step 4 — Apply the bootstrap stack (CloudShell)

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

**Keep this CloudShell tab open:** `/tmp` is cleared when the session ends, and step 6 continues here. If the tab was closed, redo item 3 of step 4, then `cd ~/Medical-RAG-Chatbot/infra/terraform/bootstrap && terraform init`.

---

## Step 5 — Connect to the workstation (Session Manager)

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

**If a tool is missing:** read `/var/log/cloud-init-output.log`. Fix `workstation-init.sh` on the laptop and push. Then in CloudShell (redo item 3 of step 4 if the tab was closed):
```bash
cd ~/Medical-RAG-Chatbot && git pull
cd infra/terraform/bootstrap && terraform init
terraform apply -replace=aws_instance.workstation
```

---

## Step 6 — Move the bootstrap state into S3 (laptop + CloudShell)

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

[Index](../guide.md) · [Part 2 →](2-shared-stack.md) · [Troubleshooting](troubleshooting.md)
