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
