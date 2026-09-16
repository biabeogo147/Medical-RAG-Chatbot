# The S3 bucket that stores the Terraform state of all three stacks.
# State is the record of what Terraform created; losing it means losing control of the resources.

# A `data` source reads from AWS instead of creating anything. This one answers "which account is this?".
data "aws_caller_identity" "current" {}

# Values computed once and reused. "${...}" inserts a value into a string.
locals {
  # S3 bucket names are unique across every AWS account in the world, hence the account ID suffix.
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# A `resource` is something Terraform creates and owns.
# "aws_s3_bucket" is the type, "state" is the local name used in references (aws_s3_bucket.state.id).
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    # Terraform refuses to delete this bucket, even with `terraform destroy`.
    prevent_destroy = true
  }
}

# Each bucket feature is its own resource. Before AWS provider v4 they were blocks inside aws_s3_bucket.
# `bucket = aws_s3_bucket.state.id` is a reference: it passes the name AND tells Terraform to create
# the bucket first. References are how Terraform works out the order; you never write the order yourself.

# Keeps the previous copy of every overwritten object, so a broken state file can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# AES256 uses keys AWS manages, at no cost. aws:kms would add a charge per request, pointless for state.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Four switches that make it impossible to expose the bucket publicly, even by accident later.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Builds an IAM policy in HCL and renders it to JSON: easier to read and review than a JSON blob.
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport" # a name for the statement, visible in the console
    effect  = "Deny"                  # an explicit Deny always wins, whatever else allows the action
    actions = ["s3:*"]

    principals {
      type        = "*" # applies to everyone
      identifiers = ["*"]
    }

    # Both ARNs are needed: the bucket itself (listing) and the objects inside it.
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    # The Deny applies only when the request did NOT use TLS, so HTTPS keeps working and plain HTTP fails.
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # No reference links these two, but AWS can reject a bucket policy while it decides whether the
  # policy is "public", so the public access block must exist first.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {} # empty filter = every object. Required: without it the rule is rejected

    # Versioning protects you, but without this the bucket would grow forever.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Interrupted uploads are otherwise kept and billed invisibly.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # A rule about old versions only makes sense once versioning is enabled.
  depends_on = [aws_s3_bucket_versioning.state]
}
