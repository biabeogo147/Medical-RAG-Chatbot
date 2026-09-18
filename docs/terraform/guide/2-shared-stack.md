# Terraform guide — Part 2: Shared stack: registry, artifacts, signing key, secrets (steps 7–8)

[← Part 1](1-bootstrap.md) · [Index](../guide.md) · [Part 3 →](3-cluster-network.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 1 done; the ops workstation opens in Session Manager (step 5).

**Done when:** step 8 — `make shared` applies 13 resources and plain HTTP to S3 is denied.

**Every step here follows [the loop](../guide.md#the-loop-for-every-workstation-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As tf`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 7 — Makefile, GitHub access and the shared stack skeleton

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

## Step 8 — ECR, artifacts bucket, KMS key, secrets and budget

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

[← Part 1](1-bootstrap.md) · [Index](../guide.md) · [Part 3 →](3-cluster-network.md) · [Troubleshooting](troubleshooting.md)
