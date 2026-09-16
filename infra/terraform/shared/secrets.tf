# Terraform creates empty secrets only: the names and who may read them. Values are set once with
#   aws secretsmanager put-secret-value --secret-id medical-rag/llm --secret-string '{...}'
# so they never appear in the Terraform state file or in Git. External Secrets syncs them into
# Kubernetes later.
resource "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github"]) # medical-rag/llm: Gemini + HF keys. medical-rag/github: bot token

  name = "${var.project}/${each.key}"

  # A deleted secret can still be restored for 7 days. That is also why the name cannot be reused
  # immediately after a destroy.
  recovery_window_in_days = 7
}
