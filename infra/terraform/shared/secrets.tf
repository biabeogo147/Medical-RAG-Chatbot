# Terraform creates empty secrets only: the names and who may read them. Values are set once with
#   aws secretsmanager put-secret-value --secret-id medical-rag/app-dev --secret-string '{...}'
# so they never appear in the Terraform state file or in Git. External Secrets syncs them into
# Kubernetes later.
resource "aws_secretsmanager_secret" "app" {
  # medical-rag/llm: nothing in deploy/ reads it any more; the app reads app-dev and app-prod.
  # medical-rag/github: bot token.
  # medical-rag/app-dev and medical-rag/app-prod: GOOGLE_API_KEY, HUGGINGFACEHUB_API_TOKEN and
  # FLASK_SECRET_KEY for each environment, replaced independently (app guide step 8).
  for_each = toset(["llm", "github", "app-dev", "app-prod"])

  name = "${var.project}/${each.key}"

  # A deleted secret can still be restored for 7 days. That is also why the name cannot be reused
  # immediately after a destroy.
  recovery_window_in_days = 7
}

# SMTP settings Alertmanager sends alert email with. Filled in once with put-secret-value (below).
resource "aws_secretsmanager_secret" "alertmanager" {
  name                    = "${var.project}/alertmanager"
  recovery_window_in_days = 7
}

# A backup of the wildcard certificate cert-manager obtains from Let's Encrypt. Let's Encrypt issues at
# most 5 certificates for the same set of names in 7 days, and this cluster is rebuilt more often than
# that. So External Secrets writes the certificate here after it is issued, and puts it back into a
# rebuilt cluster before cert-manager would ask for a new one.
resource "aws_secretsmanager_secret" "wildcard_tls" {
  name                    = "${var.project}/wildcard-tls"
  recovery_window_in_days = 7

  # External Secrets writes only to secrets carrying this tag, so that it never overwrites a secret it
  # does not own. A resource tag replaces the provider's default tag with the same key.
  tags = {
    managed-by = "external-secrets"
  }
}

# The private key the API server signs service-account tokens with (app guide step 2). Every rebuild
# uses the same key, so the public key set AWS trusts never changes. It is set once with
# put-secret-value, so Terraform never sees the value.
#
# Deliberately NOT in the node role's list (cluster/main.tf). Whoever holds this key can mint a token for
# any service account, and so take every role that trusts this cluster. Only the workstation reads it,
# while Ansible builds the cluster.
resource "aws_secretsmanager_secret" "sa_signer" {
  name                    = "${var.project}/sa-signer"
  recovery_window_in_days = 7
}
