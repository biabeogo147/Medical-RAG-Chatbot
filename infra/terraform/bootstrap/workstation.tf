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
