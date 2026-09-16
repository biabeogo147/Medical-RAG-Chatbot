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
