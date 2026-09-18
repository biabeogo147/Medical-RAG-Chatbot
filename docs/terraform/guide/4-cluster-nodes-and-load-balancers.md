# Terraform guide — Part 4: Cluster stack: IAM, nodes, load balancers, rebuild test (steps 12–15)

[← Part 3](3-cluster-network.md) · [Index](../guide.md) · [Part 5 →](5-domain-certificate-and-secrets.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 3 applied (`make plan` → `No changes`). This part continues the cluster stack, which is destroyed when idle.

**Done when:** step 15 — destroy and apply work from nothing (65 resources), `plan` shows `No changes`, and the cluster is destroyed again.

**Every step here follows [the loop](../guide.md#the-loop-for-every-workstation-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As tf`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 12 — Cluster buckets and the node IAM role

**Goal:** the buckets that live with the cluster, and the permissions of the nodes, with no access key anywhere.

Create `infra/terraform/cluster/storage.tf`:
```hcl
# Buckets whose content is only useful while this cluster exists. The FAISS index lives in the shared
# stack instead, so a teardown never throws it away.
locals {
  buckets = {
    etcd-backups = 14 # days to keep etcd snapshots
    ssm-transfer = 1  # days to keep the temporary files Ansible copies through SSM
  }
}

# for_each over the map creates one bucket per key, and the same protections are written once instead
# of twice. Each instance is addressed as aws_s3_bucket.this["etcd-backups"].
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
```

Create `infra/terraform/cluster/iam.tf`:
```hcl
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
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "buckets" {
  value = { for k, b in aws_s3_bucket.this : k => b.bucket }
}
```

**Why:**
- **`for_each` over a map of buckets:** two buckets get the same protections without copying the code. Only the expiry differs.
- **`force_destroy = true`:** `make infra-destroy` can delete these buckets even with content; etcd snapshots of a deleted cluster are useless.

| Permission | Used by |
|---|---|
| `AmazonSSMManagedInstanceCore` | Session Manager and Ansible over SSM |
| `AmazonEBSCSIDriverPolicy` | The EBS CSI driver creates disks for Jenkins and Prometheus |
| ECR pull + push, **this repository only** | Nodes pull the app image; Jenkins BuildKit pods push it |
| S3, **the project's three buckets only** | Index artifacts, etcd backups, Ansible file transfers |
| Secrets Manager, **the two project secrets only** | External Secrets reads the API keys |
| KMS `Sign` / `GetPublicKey`, **the cosign key only** | Jenkins signs images |

- **Least privilege:** every statement names its exact resources, except `ecr:GetAuthorizationToken`, which AWS only supports on `*`.
- **Known limitation:** on a self-managed cluster every pod on a node can use the node's role. The design doc lists the mitigations (IMDS hop limit, NetworkPolicy).

**Run:** `make plan` (expect 15 to add), then `make infra`.

**Verify with the IAM policy simulator:**
```bash
ROLE_ARN=$(aws iam get-role --role-name medical-rag-nodes --query Role.Arn --output text)
KEY_ARN=$(terraform -chdir=infra/terraform/shared output -raw cosign_kms_key_arn)
aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" \
  --action-names kms:Sign --resource-arns "$KEY_ARN" \
  --query 'EvaluationResults[].EvalDecision'                      # ["allowed"]
aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" \
  --action-names s3:GetObject --resource-arns "arn:aws:s3:::some-other-bucket/file" \
  --query 'EvaluationResults[].EvalDecision'                      # ["implicitDeny"]
```

---

## Step 13 — Kubernetes nodes

**Goal:** 3 Ubuntu EC2 instances, one per Availability Zone, ready for Ansible.

Create `infra/terraform/cluster/compute.tf`:
```hcl
# The three Kubernetes machines. Terraform only creates them; Ansible turns them into a cluster.

data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "nodes" {
  count = var.node_count # creates nodes[0], nodes[1], nodes[2]

  ami           = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  instance_type = var.node_instance_type # 2 vCPU for kubeadm, 8 GB for Jenkins, Prometheus and the app

  # node 1 to AZ a, node 2 to AZ b, node 3 to AZ c. Losing one AZ leaves 2 of 3 etcd members, which
  # keeps quorum, so the cluster survives. There are always 3 subnets, so a 4th node would wrap onto
  # the first one again.
  subnet_id = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]

  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.nodes.name
  # No public IP and no key pair: the only way in is Session Manager.

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 2 hops, unlike the workstation's 1: pods run in their own network namespace, so External Secrets
    # and the EBS CSI driver need one extra hop to reach the metadata service.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.node_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-node-${count.index + 1}"
    # Ansible's aws_ec2 inventory selects the nodes by this tag, so no IP address is ever written down.
    k8s-cluster = local.name
  }

  lifecycle {
    # Canonical publishes new images constantly; without this every apply would replace the nodes.
    ignore_changes = [ami]
  }
}
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "node_instance_ids" {
  value = aws_instance.nodes[*].id
}

output "node_private_ips" {
  value = aws_instance.nodes[*].private_ip
}
```

**Why:**
- **`count` + `count.index % length(...)`:** node 1 goes to AZ a, node 2 to AZ b, node 3 to AZ c. Losing one AZ leaves 2 of 3 etcd members, which keeps quorum.
- **`m7i-flex.large` (2 vCPU, 8 GB):** kubeadm needs at least 2 vCPU and 2 GB; the rest is for Jenkins, Prometheus and the app. On an AWS Free plan account it is also one of the few types that may be launched at all (see the note in [step 4](1-bootstrap.md#step-4--apply-the-bootstrap-stack-cloudshell)).
- **No public IP, no key pair:** access is Session Manager only, through the NAT gateway.
- **`http_put_response_hop_limit = 2`:** IMDSv2 answers requests from inside pods (one extra network hop), which External Secrets and the EBS CSI driver need.
- **`k8s-cluster` tag:** Ansible finds the nodes by this tag, so no IP address is written in the inventory.

**Run:** `make plan` (expect 3 to add), then `make infra`.

**Verify** (the SSM agent needs 2–3 minutes after boot):
```bash
aws ssm describe-instance-information \
  --filters Key=tag:k8s-cluster,Values=medical-rag \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,PlatformVersion]' --output table   # 3 × Online, Ubuntu, 24.04
aws ec2 describe-instances --filters Name=tag:k8s-cluster,Values=medical-rag Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Placement.AvailabilityZone,PublicIpAddress,MetadataOptions.HttpTokens]' --output table   # 3 AZs, None, required
```

---

## Step 14 — Network Load Balancers

**Goal:** a stable internal address for the Kubernetes API and a public entry point for the app.

Create `infra/terraform/cluster/loadbalancers.tf`:
```hcl
# Two Network Load Balancers: one inside the VPC for the Kubernetes API, one facing the internet for
# the app. A target group is the list of machines behind a load balancer; a listener is the port it
# accepts traffic on.

# --- internal NLB: one stable address for the 3 API servers (kubeadm controlPlaneEndpoint) ---

resource "aws_lb" "api" {
  name               = "${local.name}-api"
  internal           = true # no public address
  load_balancer_type = "network"
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.api_nlb.id]

  # Each AZ's load balancer node may send traffic to targets in the other AZs, so an API server stays
  # reachable even if two of the three AZs have none running.
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api"
  port        = var.api_port
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # A node calling the API through the NLB can be routed back to itself. With client IP preservation
  # on, AWS drops that "hairpin" connection and kubeadm join and kubelet time out. Turning it off makes
  # the NLB the source address, which works. The API server does not need to see the real client IP.
  preserve_client_ip = false

  # /readyz answers 200 only when the API server is really ready, which is stricter than "port 6443 is
  # open". kubeadm allows anonymous access to it, and the NLB does not validate the certificate.
  health_check {
    protocol            = "HTTPS"
    path                = "/readyz"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = var.api_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Registers each node in the target group: one attachment per node.
resource "aws_lb_target_group_attachment" "api" {
  count = var.node_count

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.nodes[count.index].id
  port             = var.api_port
}

# --- public NLB: internet -> ingress-nginx NodePort ---

resource "aws_lb" "ingress" {
  name                             = "${local.name}-ingress"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = module.vpc.public_subnets
  security_groups                  = [aws_security_group.ingress_nlb.id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "ingress_http" {
  name        = "${local.name}-ingress-http"
  port        = var.ingress_http_nodeport # 30080, where ingress-nginx will listen on every node
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # A plain TCP check: ingress-nginx is not installed yet, so targets stay unhealthy until it is.
  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "ingress_http" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_http.arn
  }
}

resource "aws_lb_target_group_attachment" "ingress_http" {
  count = var.node_count

  target_group_arn = aws_lb_target_group.ingress_http.arn
  target_id        = aws_instance.nodes[count.index].id
  port             = var.ingress_http_nodeport
}
```

Append to `infra/terraform/cluster/outputs.tf`:
```hcl
output "api_nlb_dns" {
  description = "kubeadm controlPlaneEndpoint (port 6443)"
  value       = aws_lb.api.dns_name
}

output "public_nlb_dns" {
  description = "Public HTTP entry point of the app"
  value       = aws_lb.ingress.dns_name
}
```

Your `infra/terraform/cluster/outputs.tf` should now match:
```hcl
# What the next phases read from this stack, with `terraform output -raw <name>`.

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

# Ansible finds the nodes by tag, so these are for your own checks.
output "node_instance_ids" {
  value = aws_instance.nodes[*].id # [*] collects the attribute from every instance of the resource
}

output "node_private_ips" {
  value = aws_instance.nodes[*].private_ip
}

output "api_nlb_dns" {
  description = "kubeadm controlPlaneEndpoint (port 6443)"
  value       = aws_lb.api.dns_name
}

output "public_nlb_dns" {
  description = "Public HTTP entry point of the app"
  value       = aws_lb.ingress.dns_name
}

# Used in the Helm values of the etcd backup CronJob and in the Ansible SSM connection settings.
output "buckets" {
  value = { for k, b in aws_s3_bucket.this : k => b.bucket }
}
```

**Why:**
- **Internal NLB :6443:** kubeadm's `controlPlaneEndpoint`. Clients use one DNS name; if an API server dies, the NLB stops sending traffic to it.
- **`preserve_client_ip = false` on the API target group:** a node calling the API through the NLB can be routed back to itself. With client IP preservation on, AWS drops that "hairpin" connection and `kubeadm join` times out.
- **Health check `HTTPS /readyz`:** a node counts as healthy only when its API server is ready, not just when port 6443 is open.
- **Public NLB :80 → NodePort 30080:** ingress-nginx, installed later, listens on that port on every node.
- **Security groups on the NLBs:** node rules reference the load balancer's group instead of broad IP ranges.

**Run:** `make plan` (expect 12 to add), then `make infra`. The NLBs take 2–3 minutes to become active.

**Verify:**
```bash
aws elbv2 describe-load-balancers --names medical-rag-api medical-rag-ingress \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,State.Code]' --output table   # internal + internet-facing, active
TG=$(aws elbv2 describe-target-groups --names medical-rag-api --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table   # 3 targets
```
**Target state:** `initial` for the first minute, then `unhealthy`. This is expected: nothing listens on 6443 or 30080 until Kubernetes and ingress-nginx are installed.

---

## Step 15 — Rebuild test and evidence

**Goal:** prove the cluster stack is reproducible, and record the numbers.

**Run:**
```bash
make plan                                                          # No changes.
terraform -chdir=infra/terraform/cluster state list | wc -l        # managed resources (65 + data sources)
time make infra-destroy                                            # answer yes
make shared-plan                                                   # No changes: shared resources untouched
time make infra                                                    # answer yes
make plan                                                          # No changes.
```

**Verify:** the second `make infra` succeeds without editing anything, and every `plan` reports `No changes`.

**Record** in `docs/evidence/terraform.md`: resource count, destroy time, apply time, and the output of the checks from steps 10–14.

**End of the session:** `make infra-destroy`, then stop the workstation.

---

[← Part 3](3-cluster-network.md) · [Index](../guide.md) · [Part 5 →](5-domain-certificate-and-secrets.md) · [Troubleshooting](troubleshooting.md)
