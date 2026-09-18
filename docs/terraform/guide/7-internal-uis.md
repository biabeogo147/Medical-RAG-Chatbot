# Terraform guide — Part 7: Internal UIs, their certificate, and alert email (step 19)

[← Part 6](6-wireguard-and-private-rancher.md) · [Index](../guide.md) · [Next: Ansible guide →](../../ansible/guide.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 6 verified. A mailbox with an app password for alert email.

**Done when:** 19 managed resources in `shared`, 88 in `cluster`; `argocd.recruitai.io.vn` resolves to private addresses.

**Every step here follows [the loop](../guide.md#the-loop-for-every-workstation-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As tf`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

This part prepares AWS for the GitOps phase. Rule for the whole project: **every UI of an internal tool
is reachable only through the VPN**, exactly like Rancher. After this part:

- `argocd`, `grafana`, `prometheus` and `alertmanager` under `recruitai.io.vn` resolve to the internal
  load balancer, like `rancher` does.
- cert-manager, running in the cluster later, may create one TXT record in the zone, and nothing else.
  It uses that record to prove to Let's Encrypt that you own the domain, and gets a wildcard
  certificate `*.recruitai.io.vn`.
- Two new empty secrets exist: one to keep that certificate across cluster rebuilds, and one for the
  email account Alertmanager sends alerts from.

## Step 19 — Internal UI names, DNS permission for cert-manager, two secrets

**Goal:** the names, the permission and the secrets exist before `make bootstrap` needs them.

| File | Change |
|---|---|
| `shared/secrets.tf` | Two new secrets: `medical-rag/alertmanager` and `medical-rag/wildcard-tls` |
| `shared/outputs.tf` | `secret_names` lists the new secrets too |
| `cluster/main.tf` | The nodes may read the two new secrets |
| `cluster/iam.tf` | Two new statements: write back the certificate, and change the ACME TXT record |
| `cluster/internal-ui.tf` | New file: the four DNS names |

**Laptop.** Add to the end of `infra/terraform/shared/secrets.tf`:
```hcl
# SMTP settings Alertmanager sends alert email with. Filled in once with put-secret-value (below).
resource "aws_secretsmanager_secret" "alertmanager" {
  name                    = "${var.project}/alertmanager"
  recovery_window_in_days = 7
}

# A backup of the wildcard certificate cert-manager obtains from Let's Encrypt. Let's Encrypt issues at
# most 5 certificates for the same set of names in 7 days, and this cluster is rebuilt more often than
# that. So External Secrets writes the certificate here after it is issued, and puts it back into a
# rebuilt cluster before cert-manager would ask for a new one.
resource "aws_secretsmanager_secret" "wildcard_tls" {
  name                    = "${var.project}/wildcard-tls"
  recovery_window_in_days = 7

  # External Secrets writes only to secrets carrying this tag, so that it never overwrites a secret it
  # does not own. A resource tag replaces the provider's default tag with the same key.
  tags = {
    managed-by = "external-secrets"
  }
}
```

In `infra/terraform/shared/outputs.tf`, replace the `secret_names` output with:
```hcl
output "secret_names" {
  value = concat(
    [for s in aws_secretsmanager_secret.app : s.name],
    [for s in aws_secretsmanager_secret.rancher : s.name],
    [aws_secretsmanager_secret.alertmanager.name, aws_secretsmanager_secret.wildcard_tls.name],
  )
}
```

In `infra/terraform/cluster/main.tf`, **replace** the block `data "aws_secretsmanager_secret" "app"`
(do not add a second one):
```hcl
data "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github", "rancher", "rancher-tls", "alertmanager", "wildcard-tls"])
  name     = "${var.project}/${each.key}"
}
```
The existing `ReadAppSecrets` statement in `iam.tf` loops over this block, so the nodes can now read
all six.

In `infra/terraform/cluster/iam.tf`, add these two statements inside `data "aws_iam_policy_document"
"nodes"`, after `ReadAppSecrets`:
```hcl
  # External Secrets backs up the wildcard certificate (see shared/secrets.tf). Only this one secret
  # can be written; the other five stay read-only.
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
```

Create `infra/terraform/cluster/internal-ui.tf`:
```hcl
# Names for the internal UIs. Like rancher.<domain> (rancher.tf), each one points at the internal load
# balancer: the name resolves anywhere, but only a client inside the VPC, which from outside means
# WireGuard, can connect. ingress-nginx then routes by name and refuses addresses outside the VPC.

variable "internal_ui_hosts" {
  description = "First labels of the internal UI names; each becomes <label>.<domain>."
  type        = set(string)
  default     = ["argocd", "grafana", "prometheus", "alertmanager"]
}

resource "aws_route53_record" "internal_ui" {
  for_each = var.internal_ui_hosts

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = false
  }
}

output "internal_ui_urls" {
  description = "The internal UIs, reachable with the VPN on once the GitOps phase has installed them"
  value       = [for r in aws_route53_record.internal_ui : "https://${r.name}"]
}
```

**Why:**

- **Names, not paths under `rancher.`** Every UI gets its own name and the same wildcard certificate, so
  adding one later is a single line in `internal_ui_hosts`.
- **`ListHostedZonesByName` needs `*`.** Listing zones is not tied to one zone, so AWS offers no narrower
  resource. `GetChange` is limited to change records (`change/*`), whose IDs exist only after a change is
  made. Both are read-only.
- **Why not Amazon SES for email.** SES accepts SMTP only with SMTP credentials derived from an IAM user
  access key, and this project has no access keys anywhere. A mailbox with an app password, stored only
  in Secrets Manager, keeps that rule.

**Commit and push** (`git add infra/terraform`, message `Add internal UI names, ACME permission and two secrets`),
`git pull` on the workstation, then:
```bash
cd ~/Medical-RAG-Chatbot
make shared
```
Expect **2 to add** (the two secrets) and the changed `secret_names` output.

If the cluster is running:
```bash
make infra
```
Expect **4 to add** (the records) and **1 to change** (the inline policy). Terraform asks for `yes`
before applying. If it is destroyed, the next
`make infra` includes both.

**Store the email settings.** Alertmanager needs an SMTP account. With Gmail:

1. Turn on 2-Step Verification for the account (Google Account → Security).
2. Create an app password (Google Account → Security → App passwords). Google shows 16 letters once.

Then on the workstation. `read -s` keeps the password off the screen and out of the shell history:
```bash
read -rp "Gmail address that sends: " SMTP_USER
read -rsp "App password (16 letters, no spaces): " SMTP_PASS; echo
read -rp "Address that receives the alerts: " ALERT_TO
```
Build the JSON in a file only you can read, store it, delete the file:
```bash
umask 077
jq -n --arg u "$SMTP_USER" --arg p "$SMTP_PASS" --arg t "$ALERT_TO" \
  '{smtp_smarthost: "smtp.gmail.com:587", smtp_from: $u, smtp_username: $u, smtp_password: $p, email_to: $t}' \
  > alertmanager.json
aws secretsmanager put-secret-value \
  --secret-id medical-rag/alertmanager \
  --secret-string file://alertmanager.json
rm alertmanager.json
unset SMTP_PASS
```

Leave `medical-rag/wildcard-tls` **empty**. External Secrets fills it after the first certificate is
issued (GitOps guide step 8).

**Verify:**
```bash
aws secretsmanager get-secret-value \
  --secret-id medical-rag/alertmanager \
  --query SecretString \
  --output text | jq -c 'keys'
```
`["email_to","smtp_from","smtp_password","smtp_smarthost","smtp_username"]`: the keys, not the values.

```bash
aws secretsmanager describe-secret --secret-id medical-rag/wildcard-tls --query 'Tags'
```
The list contains `{"Key": "managed-by", "Value": "external-secrets"}`.

With the cluster running:
```bash
getent ahostsv4 argocd.recruitai.io.vn
```
`10.10.x.x` addresses: the internal load balancer, as for `rancher`. Final baselines: 19 managed
resources in `shared`, 88 in `cluster`.

---

[← Part 6](6-wireguard-and-private-rancher.md) · [Index](../guide.md) · [Next: Ansible guide →](../../ansible/guide.md) · [Troubleshooting](troubleshooting.md)
