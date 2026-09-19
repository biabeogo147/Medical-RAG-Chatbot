# The public half of workload identity. Pods of the app prove who they are with a token the API server
# signs. AWS checks the signature against the key set published here (app guide steps 3 and 5).
#
# The bucket holds two objects, both public by design: a discovery document and the public key set.
# Nothing secret is ever stored here. The private key is in Secrets Manager (medical-rag/sa-signer).

resource "aws_s3_bucket" "oidc" {
  bucket = "${local.name}-oidc-${local.account_id}"

  lifecycle {
    # Every role the app's pods use trusts this exact URL. If the bucket were deleted, anyone could create
    # one with the same name, publish their own key, and have their tokens accepted.
    prevent_destroy = true
  }
}

locals {
  # The issuer URL. The API server writes it into every token (Ansible group_vars/all.yml builds the
  # same string), and IAM trusts it (irsa.tf). No dots in the bucket name, so S3's certificate covers it.
  oidc_host       = "${aws_s3_bucket.oidc.bucket}.s3.${var.region}.amazonaws.com"
  oidc_issuer_url = "https://${local.oidc_host}"

  # The two paths AWS fetches: the discovery document, then the key set it points to.
  oidc_documents = [".well-known/openid-configuration", "openid/v1/jwks"]
}

# ACLs stay blocked. Only a bucket policy may make objects public, and the one below names two keys.
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A key set overwritten by mistake can be restored from the previous version.
resource "aws_s3_bucket_versioning" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "oidc" {
  # Anyone may read the two documents. That is how OIDC works: AWS fetches them without credentials.
  statement {
    sid       = "PublicIssuerDocuments"
    actions   = ["s3:GetObject"]
    resources = [for key in local.oidc_documents : "${aws_s3_bucket.oidc.arn}/${key}"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # The same TLS-only rule as every other bucket in the project.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.oidc.arn, "${aws_s3_bucket.oidc.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  policy = data.aws_iam_policy_document.oidc.json

  # With public policies still blocked, S3 would refuse this one.
  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

output "oidc_issuer_url" {
  value = local.oidc_issuer_url
}
