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
