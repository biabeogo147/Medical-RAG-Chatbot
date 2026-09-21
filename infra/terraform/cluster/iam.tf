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

  # Pull only. The Jenkins build pods push with their own role (shared/irsa.tf, Jenkins guide step 3), and
  # no pod on a node may push through the node role any more. Both repositories stay readable: the kubelet
  # pulls the app image and, for every build pod, the pipeline's tools image.
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [data.aws_ecr_repository.app.arn, data.aws_ecr_repository.ci.arn]
  }

  # The cluster's own buckets (the Ansible transfer bucket) plus the etcd snapshot bucket, which lives in
  # the shared stack and is not in aws_s3_bucket.this: leave it out and the snapshot CronJob fails with
  # AccessDenied. The artifacts bucket is not here: the app's pods reach it through their own roles
  # (shared/irsa.tf, app guide step 6).
  statement {
    sid       = "S3ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = concat([for b in aws_s3_bucket.this : b.arn], [data.aws_s3_bucket.etcd_backups.arn])
  }

  statement {
    sid     = "S3ReadWriteObjects"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = concat(
      [for b in aws_s3_bucket.this : "${b.arn}/*"],
      ["${data.aws_s3_bucket.etcd_backups.arn}/*"],
    )
  }

  # Read by External Secrets, which turns them into Kubernetes Secrets.
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for s in data.aws_secretsmanager_secret.app : s.arn]
  }

  # External Secrets backs up the wildcard certificate (see shared/secrets.tf). Only this one secret
  # can be written; the others stay read-only.
  # External Secrets also calls DeleteResourcePolicy on every push (it removes any resource policy the
  # PushSecret does not ask for), and fails without it.
  statement {
    sid       = "BackupWildcardCertificate"
    actions   = ["secretsmanager:PutSecretValue", "secretsmanager:DeleteResourcePolicy"]
    resources = [data.aws_secretsmanager_secret.app["wildcard-tls"].arn]
  }

  # cert-manager proves domain ownership to Let's Encrypt (DNS-01) by creating one TXT record,
  # _acme-challenge.<domain>, and deleting it afterwards. The conditions limit the change permission to
  # exactly that name and type, so a pod using this role cannot change any other record in the zone.
  statement {
    sid       = "AcmeChallengeRecord"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.main.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["_acme-challenge.${var.domain}"]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  # Read-only lookups cert-manager needs: find the zone by name, list its records, and poll until
  # a change has reached every Route 53 server.
  statement {
    sid       = "AcmeZoneLookup"
    actions   = ["route53:ListResourceRecordSets"]
    resources = [data.aws_route53_zone.main.arn]
  }
  statement {
    sid       = "AcmeChangeStatus"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
  statement {
    sid       = "AcmeFindZone"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
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
