# IAM roles for the app's own pods (app guide step 6). IAM trusts tokens from the cluster's issuer
# (oidc.tf). Each role accepts a token only for one named ServiceAccount in one named namespace, and only
# when the token is meant for AWS (audience sts.amazonaws.com).

# No thumbprint: IAM checks the issuer's TLS certificate, from S3, against its own trusted CAs. IAM
# contacts the issuer host here, and STS fetches the published documents (step 5) on every token exchange.
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = local.oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # Role name suffix => the ServiceAccounts ("namespace:name") allowed to assume it.
  irsa_roles = {
    app-dev       = ["medical-rag-dev:medical-rag"]
    app-prod      = ["medical-rag-prod:medical-rag"]
    index-builder = ["medical-rag-dev:medical-rag-index-builder", "medical-rag-prod:medical-rag-index-builder"]
  }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Only tokens minted for AWS, not the ordinary tokens pods use against the API server.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only these ServiceAccounts. A pod in another namespace, or with another ServiceAccount, is refused.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for sa in each.value : "system:serviceaccount:${sa}"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_roles

  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json
}

# Serving pods: download an index version, nothing else.
data "aws_iam_policy_document" "index_read" {
  statement {
    sid       = "ListIndexVersions"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["faiss/*"]
    }
  }

  statement {
    sid       = "ReadIndexVersions"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/*"]
  }
}

# The index build Job: read the corpus and the existing versions, write a new version. No delete, so a
# bad build can add objects but never remove one (and the bucket keeps old versions anyway).
data "aws_iam_policy_document" "index_build" {
  statement {
    sid       = "ListCorpusAndIndex"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["faiss/*", "corpus/*"]
    }
  }

  statement {
    sid       = "ReadCorpusAndIndex"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/*", "${aws_s3_bucket.artifacts.arn}/corpus/*"]
  }

  # index.faiss is large enough for a multipart upload; Abort lets a failed upload clean up its parts.
  statement {
    sid       = "WriteIndexVersions"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/*"]
  }

  # The cluster pins every version and never moves the LATEST pointer. This makes that a rule IAM enforces,
  # not only a setting (INDEX_UPDATE_LATEST=false).
  statement {
    sid       = "NeverMoveLatest"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/LATEST"]
  }
}

resource "aws_iam_role_policy" "irsa" {
  for_each = local.irsa_roles

  name   = "${local.name}-${each.key}"
  role   = aws_iam_role.irsa[each.key].id
  policy = each.key == "index-builder" ? data.aws_iam_policy_document.index_build.json : data.aws_iam_policy_document.index_read.json
}

output "irsa_role_arns" {
  value = { for k, r in aws_iam_role.irsa : k => r.arn }
}
