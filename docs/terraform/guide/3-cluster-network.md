# Terraform guide — Part 3: Cluster stack: skeleton, network, security groups (steps 9–11)

[← Part 2](2-shared-stack.md) · [Index](../guide.md) · [Part 4 →](4-cluster-nodes-and-load-balancers.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 2 applied: the cluster stack looks the shared resources up by name.

**Done when:** step 11 — 6 subnets in 3 AZs, NAT gateway `available`, only port 80 open to the internet.

**Every step here follows [the loop](../guide.md#the-loop-for-every-workstation-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As tf`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 9 — Cluster stack skeleton

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

## Step 10 — Network

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

## Step 11 — Security groups

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

[← Part 2](2-shared-stack.md) · [Index](../guide.md) · [Part 4 →](4-cluster-nodes-and-load-balancers.md) · [Troubleshooting](troubleshooting.md)
