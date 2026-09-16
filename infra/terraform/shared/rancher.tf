# Persistent DNS and credentials for private Rancher access. Values are inserted later with the AWS
# CLI, never with Terraform, so private keys do not enter state.

# The hosted zone is here rather than in the cluster stack because a zone gets a new set of name
# servers every time it is created, and those name servers are typed in by hand at the domain
# registrar. Recreating it would mean repeating that step and waiting for the change to spread.
resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "Public names for ${var.project}"

  lifecycle {
    # The registrar points at this zone. Deleting it takes down every name under the domain until the
    # registrar is updated again.
    prevent_destroy = true
  }
}

# Three empty secrets, filled in once with `aws secretsmanager put-secret-value`:
#   <project>/rancher      {"bootstrapPassword": "..."}  the password for the first login
#   <project>/rancher-tls  {"tls.crt": "...", "tls.key": "..."}  the certificate bought from Sectigo
#   <project>/wireguard    {"serverPrivateKey": "...", "operatorPublicKey": "..."}
resource "aws_secretsmanager_secret" "rancher" {
  for_each = toset(["rancher", "rancher-tls", "wireguard"])

  name                    = "${var.project}/${each.key}"
  recovery_window_in_days = 7
}

variable "domain" {
  description = "Domain this stack owns the Route 53 zone for. Its name servers are set at the registrar."
  type        = string
  default     = "recruitai.io.vn"
}

# Enter these four at the registrar, once. They only change if the zone is recreated.
output "route53_name_servers" {
  value = aws_route53_zone.main.name_servers
}
