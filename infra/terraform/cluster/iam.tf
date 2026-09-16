# What the nodes are allowed to do in AWS. They authenticate with this role, so no access key exists
# on any machine. Known limitation of a self-managed cluster: every pod on a node can reach the node's
# role, which is why each statement names its exact resources.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nodes" {
  name               = "${local.name}-nodes"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",          # Session Manager and Ansible over SSM
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy", # volumes for Jenkins and Prometheus
  ])

  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}

# The project-specific permissions, written as one inline policy.
data "aws_iam_policy_document" "nodes" {
  # The only action in this policy AWS cannot scope to a repository: it is registry-wide.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Pull for the nodes, push for the Jenkins build pods. This repository only.
  statement {
    sid = "EcrPullPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }

  # Listing a bucket and reading its objects are different permissions on different ARNs, so both
  # statements are needed: the shared artifacts bucket plus the two cluster buckets.
  statement {
    sid       = "S3ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = concat([data.aws_s3_bucket.artifacts.arn], [for b in aws_s3_bucket.this : b.arn])
  }

  statement {
    sid       = "S3ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = concat(["${data.aws_s3_bucket.artifacts.arn}/*"], [for b in aws_s3_bucket.this : "${b.arn}/*"])
  }

  # Read by External Secrets, which turns them into Kubernetes Secrets.
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for s in data.aws_secretsmanager_secret.app : s.arn]
  }

  # Sign, not decrypt: the CI pipeline asks KMS to sign image digests with the cosign key.
  statement {
    sid       = "CosignSign"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [data.aws_kms_alias.cosign.target_key_arn]
  }
}

resource "aws_iam_role_policy" "nodes" {
  name   = "${local.name}-nodes"
  role   = aws_iam_role.nodes.id
  policy = data.aws_iam_policy_document.nodes.json
}

resource "aws_iam_instance_profile" "nodes" {
  name = "${local.name}-nodes"
  role = aws_iam_role.nodes.name
}
