# Public names for the app, one per environment (app guide step 14). Like the internal UI names
# (internal-ui.tf), each is an alias record, but these point at the public load balancer, which listens on
# port 80 only. ingress-nginx routes by name: dev.<domain> to medical-rag-dev, app.<domain> to prod.

variable "app_hosts" {
  description = "First labels of the app's public names; each becomes <label>.<domain>."
  type        = set(string)
  default     = ["dev", "app"]
}

resource "aws_route53_record" "app" {
  for_each = var.app_hosts

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.ingress.dns_name
    zone_id                = aws_lb.ingress.zone_id
    evaluate_target_health = false
  }
}

output "app_urls" {
  description = "The app's public URLs, plain HTTP"
  value       = [for r in aws_route53_record.app : "http://${r.name}"]
}
