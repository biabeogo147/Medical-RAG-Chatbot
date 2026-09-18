# Terraform guide — Part 5: Private access: domain, certificate and secrets (steps 16–17)

[← Part 4](4-cluster-nodes-and-load-balancers.md) · [Index](../guide.md) · [Part 6 →](6-wireguard-and-private-rancher.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 4 done; the cluster may be destroyed. A domain you control, and time for DNS delegation and the Sectigo certificate (up to a day).

**Done when:** step 17 — DNS records survive the delegation; the Rancher password and certificate chain are in Secrets Manager, and outputs show names only.

**Every step here follows [the loop](../guide.md#the-loop-for-every-workstation-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As tf`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

Rancher is a cluster-admin UI, so TCP 443 is never exposed to the internet. Argo CD installs the
chart later; these steps create the persistent DNS and secrets, a WireGuard gateway, and a private
TCP path through the existing internal NLB.

The split follows the same rule as everywhere else. What must survive a teardown — the zone, the
certificate, password and VPN keys — goes in the **shared** stack. The gateway, internal listener
and DNS records are rebuilt with the **cluster** stack.

**Why a domain at all.** Rancher insists on being served at the root of its own hostname; it cannot
live under `/rancher` next to the app. With a name of its own, ingress-nginx routes by host and there
is no clash: `rancher.recruitai.io.vn` on 443 goes to Rancher, and the load balancer's own name on 80
still goes to the app.

## Step 16 — The zone and the private-access secrets

**Goal:** Route 53 owns the domain and the empty Rancher, TLS and WireGuard secrets survive every
cluster rebuild.

Create `infra/terraform/shared/rancher.tf`:
```hcl
# Persistent DNS and credentials for private Rancher access. Values are inserted later with the AWS
# CLI, never with Terraform, so private keys do not enter state.

# The hosted zone is here rather than in the cluster stack because a zone gets a new set of name
# servers every time it is created, and those name servers are typed in by hand at the domain
# registrar. Recreating it would mean repeating that step and waiting for the change to spread.
resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "Public names for ${var.project}"

  lifecycle {
    # The registrar points at this zone. Deleting it takes down every name under the domain until the
    # registrar is updated again.
    prevent_destroy = true
  }
}

# Three empty secrets, filled in once with `aws secretsmanager put-secret-value`:
#   <project>/rancher      {"bootstrapPassword": "..."}  the password for the first login
#   <project>/rancher-tls  {"tls.crt": "...", "tls.key": "..."}  the certificate bought from Sectigo
#   <project>/wireguard    {"serverPrivateKey": "...", "operatorPublicKey": "..."}
resource "aws_secretsmanager_secret" "rancher" {
  for_each = toset(["rancher", "rancher-tls", "wireguard"])

  name                    = "${var.project}/${each.key}"
  recovery_window_in_days = 7
}

variable "domain" {
  description = "Domain this stack owns the Route 53 zone for. Its name servers are set at the registrar."
  type        = string
  default     = "recruitai.io.vn"
}

# Enter these four at the registrar, once. They only change if the zone is recreated.
output "route53_name_servers" {
  value = aws_route53_zone.main.name_servers
}
```

Update `infra/terraform/shared/outputs.tf` so the inventory lists all five names, never values:
```hcl
output "secret_names" {
  value = concat(
    [for s in aws_secretsmanager_secret.app : s.name],
    [for s in aws_secretsmanager_secret.rancher : s.name],
  )
}
```

The project owns `recruitai.io.vn`; choose a different domain only before the first `make shared`.
The zone has `prevent_destroy`, so changing it later is intentionally blocked.

**Why:**

- **The certificate is in Secrets Manager, not in Git and not in a Terraform variable.** Terraform
  creates the empty secret; the value goes in with one CLI call, so the private key never reaches
  the state file. External Secrets syncs it into the cluster later.

**Run:**
```bash
cd ~/Medical-RAG-Chatbot
make shared          # expect 4 to add (the zone and three secrets), plus the changed secret_names output
```

**Verify:**
```bash
terraform -chdir=infra/terraform/shared output route53_name_servers
aws secretsmanager list-secrets \
  --query 'SecretList[?starts_with(Name, `medical-rag/`)].Name' --output text
```
The output includes four Route 53 name servers and the empty `rancher`, `rancher-tls` and
`wireguard` secrets. Do not put values in them until the DNS inventory in step 17 is complete.

**Commit:** `git add infra/terraform/shared && git commit -m "Add private Rancher access secrets"`

---

## Step 17 — Migrate DNS and store the keys

**Goal:** the domain answers from Route 53 without losing any existing record, and the certificate
and the Rancher password are stored before the cluster is built.

This step changes DNS and secret values, not code, so there is nothing to commit. It has three parts.
Do them in order; two of them end with a wait.

| Part | Where you work | Then wait |
|---|---|---|
| 17.1 Point the domain at Route 53 | Registrar website, AWS console, workstation | Minutes to hours |
| 17.2 Get the certificate from Sectigo | Workstation, Sectigo website, registrar website | Minutes to hours |
| 17.3 Put the certificate on the workstation and store it | Laptop, workstation | — |

> **Coming back in a new Session Manager window?** Run `sudo su - ubuntu`, then `tmux new -As tf`.
> Every block below starts with the `cd` it needs.

### 17.1 Point the domain at Route 53

**1. Registrar website — note the records you already have.** Open the DNS record list of
`recruitai.io.vn`. If you never added a record there (no website, no email, no verification record),
skip to 3. Otherwise write down each record's type, host, value and TTL. Leave out `rancher` and
`vpn`: Terraform creates those in step 18, and a copy would make it fail.

**2. AWS console — copy them into Route 53.** Open **Route 53 → Hosted zones → recruitai.io.vn →
Create record**, and enter each record from 1 with the same type, host, value and TTL.

**3. Workstation — check that DNSSEC is off.**
```bash
dig +short DS recruitai.io.vn @1.1.1.1
```
Empty output is the usual case: continue. If it prints something, DNSSEC is switched on at the
registrar. Switch it off in the registrar's DNSSEC settings, wait a day, and run the command again
until it prints nothing; otherwise every lookup for the domain fails once Route 53 starts answering.

**4. Change the name servers.** Workstation — print the four names:
```bash
cd ~/Medical-RAG-Chatbot
terraform -chdir=infra/terraform/shared output route53_name_servers
```
Registrar website — open the domain's **name server** setting. It is separate from the record list
and is usually called *Name servers* or *DNS servers*. Choose custom name servers, enter the four
names without quotes (and without a final dot, if the form rejects it), and save. Leave the old
records at the registrar untouched for 48 hours; you do not have to wait that long to continue.

**5. Workstation — verify**, a few minutes to a few hours later:
```bash
dig +short NS recruitai.io.vn @1.1.1.1
```
Expect the four `awsdns` names. `@1.1.1.1` asks Cloudflare's public DNS, so this is what the rest of
the internet sees. If you copied records in 2, check each one the same way: `dig +short <type>
<host>.recruitai.io.vn @1.1.1.1` must print the value you wrote down.

### 17.2 Get the certificate from Sectigo

**1. Workstation — create the private key and the certificate request.** The `if` stops this from
replacing a key once a request exists for it: a new key would make the certificate Sectigo issues for
the old request useless. (A key left without a request, by a run that failed half-way, is simply
replaced.)
```bash
install -d -m 700 ~/tls/rancher.recruitai.io.vn
cd ~/tls/rancher.recruitai.io.vn
umask 077
if [ -e rancher.csr ]; then
  echo "STOP: rancher.csr already exists. Keep it and rancher.key; do not create new ones."
else
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout rancher.key -out rancher.csr \
    -subj "/CN=rancher.recruitai.io.vn" \
    -addext "subjectAltName=DNS:rancher.recruitai.io.vn"
fi
openssl req -in rancher.csr -noout -subject
openssl req -in rancher.csr -noout -text | grep -A1 "Subject Alternative Name"
ls
```
Expect a subject naming `rancher.recruitai.io.vn`, the line `DNS:rancher.recruitai.io.vn`, and two
files: `rancher.csr`, the request you send to Sectigo, and `rancher.key`, the private key, which never
leaves this directory. There is no certificate yet: Sectigo creates it from the request.

**2. Order the certificate.** Workstation — print the request:
```bash
cat ~/tls/rancher.recruitai.io.vn/rancher.csr
```
Select everything from `-----BEGIN CERTIFICATE REQUEST-----` to `-----END CERTIFICATE REQUEST-----`
with the mouse, and copy it.

Sectigo website (or your reseller's) — start the certificate order and paste the request when asked.
For the server type choose *Other* or *Nginx*. For the validation method choose **DNS (CNAME)**, not
email or HTTP file.

**3. Add the validation record.** Sectigo shows a name such as `_1A2B3C4D.rancher.recruitai.io.vn` and
a value such as `5E6F7A8B.c3d4e5.sectigo.com`. Add the record in both places below, because some
resolvers may still ask the old name servers.

Registrar website — add a `CNAME` record. Most panels append the domain themselves, so enter the name
**without** `.recruitai.io.vn` (for example `_1A2B3C4D.rancher`), and the value as shown.

Workstation — first confirm that the domain has exactly one hosted zone:
```bash
aws route53 list-hosted-zones-by-name --dns-name recruitai.io.vn \
  --query "HostedZones[?Name=='recruitai.io.vn.'].Id" --output text
```
Expect one `/hostedzone/Z…`. Two IDs mean a second zone was created by hand; see [Troubleshooting](troubleshooting.md).

Paste **only this line** and press Enter. At the prompt, paste the **full** name from Sectigo, ending
in `.recruitai.io.vn`, and press Enter:
```bash
read -r -p "CNAME name: " DCV_NAME
```
Then **only this line**, the same way, for the value:
```bash
read -r -p "CNAME value: " DCV_VALUE
```
`read` waits for what you type next, so pasting a whole block would feed it the following command
instead. Now paste the rest:
```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name recruitai.io.vn \
  --query "HostedZones[?Name=='recruitai.io.vn.'].Id | [0]" --output text)
CHANGE_ID=$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query ChangeInfo.Id --output text --change-batch "$(jq -n \
    --arg name "$DCV_NAME" --arg value "$DCV_VALUE" \
    '{Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: "CNAME", TTL: 300,
      ResourceRecords: [{Value: $value}]}}]}')")
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
dig +short CNAME "$DCV_NAME" @1.1.1.1
dig +short CAA recruitai.io.vn @1.1.1.1
dig +short CAA rancher.recruitai.io.vn @1.1.1.1
```
Expect Sectigo's value from the first `dig`, and nothing from the two `CAA` lookups (or answers that
include `sectigo.com`). A `CAA` record that names another certificate authority blocks the order; see
[Troubleshooting](troubleshooting.md).

**4. Wait for Sectigo.** It checks the record every few minutes, and issuing can take a few hours.
You are done when the order page says *Issued* or the certificate email arrives.

### 17.3 Put the certificate on the workstation and store it

Sectigo sends the certificate to you — usually a `.zip` by email, or a download on the order page — so
the files land on the laptop. Session Manager has no upload button, but certificates are plain text,
so you move them by pasting into two files.

**1. Laptop — find the two files.** Extract the `.zip`. It contains:

- **your certificate**, issued to `rancher.recruitai.io.vn`. Double-click a `.crt` file to check: the
  window shows *Issued to: rancher.recruitai.io.vn*.
- **the CA bundle**, usually a file ending in `.ca-bundle`, with Sectigo's certificates that link
  yours to a trusted root.

Open both in Notepad (right-click → Open with → Notepad). Each shows text between
`-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----`; the bundle has several such blocks.

**2. Workstation — paste your certificate.**
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
cat > rancher.crt <<'EOF'
```
The prompt changes to `>`. The shell is not stuck: it is writing what you paste into `rancher.crt`.
In Notepad, open **your certificate** and press Ctrl+A, Ctrl+C. Paste into Session Manager (Ctrl+V, or
right-click → Paste), press Enter, type `EOF` and press Enter. The normal prompt comes back. If
something went wrong, press Ctrl+C and run the block again: the file is written from scratch.

**3. Workstation — paste the CA bundle,** the same way:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
cat > ca-bundle.crt <<'EOF'
```
Paste **all** of the `.ca-bundle` file, press Enter, type `EOF` and press Enter.

**4. Workstation — check the two files.**
```bash
cd ~/tls/rancher.recruitai.io.vn
openssl x509 -in rancher.crt -noout -subject -issuer -enddate
openssl verify -untrusted ca-bundle.crt rancher.crt
if [ "$(openssl x509 -in rancher.crt -pubkey -noout | openssl sha256)" = \
     "$(openssl pkey -in rancher.key -pubout | openssl sha256)" ]; then
  echo "OK: the certificate matches rancher.key"
else
  echo "MISMATCH: this certificate was not issued for rancher.csr"
fi
```
Expect a subject naming `rancher.recruitai.io.vn` and a Sectigo issuer, then `rancher.crt: OK` (the
chain is complete), then `OK: the certificate matches rancher.key`. If the subject names a Sectigo CA
instead, the two files were swapped: repeat 2 and 3. For other errors, see [Troubleshooting](troubleshooting.md).

**5. Workstation — store the certificate.** Run the commands one at a time. All of them are safe to
run again, for example after a renewal.

Join your certificate and the CA bundle into one file, in the order a web server sends them:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
cat rancher.crt ca-bundle.crt > fullchain.crt
```

Put the chain and the private key into one JSON file, the format the secret uses:
```bash
jq -n --rawfile crt fullchain.crt --rawfile key rancher.key '{"tls.crt": $crt, "tls.key": $key}' > rancher-tls.json
```

Upload it to Secrets Manager:
```bash
aws secretsmanager put-secret-value --secret-id medical-rag/rancher-tls --secret-string file://rancher-tls.json
```
Expect a few lines ending with a `VersionId`. If it prints an error instead, fix the cause and run the
`jq` command again before retrying, because the next command deletes the file.

Delete the JSON file, which holds a copy of the private key:
```bash
shred -u rancher-tls.json
```

Check that the secret now holds both parts, without printing them:
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/rancher-tls --query SecretString --output text | jq -c 'keys'
```
Expect `["tls.crt","tls.key"]`.

**6. Workstation — create the Rancher password.** Run the commands one at a time. Do this only once:
creating it again would replace the password.

First check whether a password already exists:
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/rancher --query VersionId --output text
```
- **It prints an ID:** the password already exists. Skip the rest of this part.
- **It prints an error mentioning `can't find the specified secret value`:** there is no password yet.
  Continue.

Generate a random password and put it into a JSON file:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
openssl rand -base64 24 | jq -Rn '{bootstrapPassword: input}' > rancher-password.json
```

Upload it to Secrets Manager:
```bash
aws secretsmanager put-secret-value --secret-id medical-rag/rancher --secret-string file://rancher-password.json
```
Expect a few lines ending with a `VersionId`.

Delete the JSON file:
```bash
shred -u rancher-password.json
```

You need the password at the first Rancher login, in the GitOps phase. This prints it on screen:
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/rancher --query SecretString --output text | jq -r '.bootstrapPassword'
```

The certificate's private key now exists in two places: `rancher.key` in this directory, which only
`ubuntu` can open, and Secrets Manager. The GitOps phase adds a third, the `tls-rancher-ingress`
Secret.

---

[← Part 4](4-cluster-nodes-and-load-balancers.md) · [Index](../guide.md) · [Part 6 →](6-wireguard-and-private-rancher.md) · [Troubleshooting](troubleshooting.md)
