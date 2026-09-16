# What the cluster stack, CI and the Helm charts need from here.

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

# What CI signs with: cosign sign --key awskms:///alias/medical-rag-cosign
output "cosign_kms_key_alias" {
  value = aws_kms_alias.cosign.name
}

output "cosign_kms_key_arn" {
  value = aws_kms_key.cosign.arn
}

output "secret_names" {
  value = concat(
    [for s in aws_secretsmanager_secret.app : s.name],
    [for s in aws_secretsmanager_secret.rancher : s.name],
  )
}
