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
