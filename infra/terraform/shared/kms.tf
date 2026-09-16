# The key cosign signs images with. Asymmetric and SIGN_VERIFY, so the private half never leaves KMS:
# CI asks KMS to sign, and anyone can verify with the public half.
# It is kept across cluster rebuilds, because a new key would invalidate every existing signature.
resource "aws_kms_key" "cosign" {
  description              = "Cosign image signing key for ${var.project}"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7 # AWS enforces a waiting period before a key is really deleted
}

# A stable name for the key, so nothing has to reference the generated key ID:
#   cosign sign --key awskms:///alias/medical-rag-cosign
resource "aws_kms_alias" "cosign" {
  name          = "alias/${var.project}-cosign"
  target_key_id = aws_kms_key.cosign.key_id
}
