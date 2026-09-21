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

# The pipeline's tools image. The kubelet pulls it with the node role, so the node policy must name it
# (Jenkins guide step 11). Created by the shared stack.
data "aws_ecr_repository" "ci" {
  name = "${var.project}-ci"
}

# Where the etcd snapshot CronJob writes (drills guide step 8). Created by the shared stack so that
# `make down` cannot delete the backups together with the cluster they back up.
data "aws_s3_bucket" "etcd_backups" {
  bucket = "${var.project}-etcd-backups-${local.account_id}"
}

data "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github", "rancher", "rancher-tls", "alertmanager", "wildcard-tls", "app-dev", "app-prod"])
  name     = "${var.project}/${each.key}"
}
