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

# TLS passes through the NLB unchanged; the load balancer never terminates it or sees the key. The key is
# stored only in Secrets Manager and in the tls-rancher-ingress Secret.
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
