# Names for the internal UIs. Like rancher.<domain> (rancher.tf), each one points at the internal load
# balancer: the name resolves anywhere, but only a client inside the VPC, which from outside means
# WireGuard, can connect. ingress-nginx then routes by name and refuses addresses outside the VPC.

variable "internal_ui_hosts" {
  description = "First labels of the internal UI names; each becomes <label>.<domain>."
  type        = set(string)
  default     = ["argocd", "grafana", "prometheus", "alertmanager", "jenkins"]
}

resource "aws_route53_record" "internal_ui" {
  for_each = var.internal_ui_hosts

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = false
  }
}

output "internal_ui_urls" {
  description = "The internal UIs, reachable with the VPN on once the GitOps phase has installed them"
  value       = [for r in aws_route53_record.internal_ui : "https://${r.name}"]
}
