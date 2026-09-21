# Buckets whose content is only useful while this cluster exists. The FAISS index and the etcd snapshots
# live in the shared stack instead, so a teardown never throws them away (shared/storage.tf).
locals {
  buckets = {
    ssm-transfer = 1 # days to keep the temporary files Ansible copies through SSM
  }
}

# for_each over the map creates one bucket per key, and the same protections are written once for all
# of them. Each instance is addressed as aws_s3_bucket.this["ssm-transfer"].
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = "${local.name}-${each.key}-${local.account_id}"
  force_destroy = true # lets `make infra-destroy` delete the bucket even with objects in it
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this # iterating over the resource keeps the same keys

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "expire-objects"
    status = "Enabled"

    filter {} # every object

    expiration {
      days = each.value # the number from the map above
    }
  }
}

# Same TLS-only rule as the state bucket: requests over plain HTTP are denied.
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [each.value.arn, "${each.value.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = data.aws_iam_policy_document.tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
