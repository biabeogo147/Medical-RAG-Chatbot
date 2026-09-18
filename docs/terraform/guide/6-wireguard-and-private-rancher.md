# Terraform guide — Part 6: Private access: WireGuard and the Rancher entry point (step 18)

[← Part 5](5-domain-certificate-and-secrets.md) · [Index](../guide.md) · [Part 7 →](7-internal-uis.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 5 done: the zone is delegated and the Rancher secrets hold values. The WireGuard client is installed on the laptop.

**Done when:** 18.5 — a WireGuard handshake is recorded, the internal NLB lists 6443 and 443, and the Rancher name resolves to private addresses.

**Every step here follows [the loop](../guide.md#the-loop-for-every-workstation-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As tf`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 18 — WireGuard and the private Rancher entry point

**Goal:** the laptop's WireGuard tunnel connects, and the private Rancher name and TCP 443 listener
exist. Rancher itself answers only after `make bootstrap` in the GitOps phase.

This step has five parts. Do them in order: the gateway reads its keys when it first boots, so the
keys (18.2) must exist before the cluster is built (18.3).

| Part | Where you work |
|---|---|
| 18.1 Write the Terraform files | Laptop |
| 18.2 Create the WireGuard keys | Laptop, workstation |
| 18.3 Build the cluster | Workstation |
| 18.4 Finish the laptop's tunnel | Workstation, laptop |
| 18.5 Verify | Laptop, workstation |

> **Coming back in a new Session Manager window?** Run `sudo su - ubuntu`, then `tmux new -As tf`.
> Every block below starts with the `cd` it needs.

### 18.1 Write the Terraform files

**Laptop.** Create three files in `infra/terraform/cluster/`, then change one block in `main.tf`:

| File | What it creates |
|---|---|
| `wireguard.tf` | The WireGuard gateway: a small EC2 machine with an Elastic IP, its firewall, its IAM role, and the name `vpn.recruitai.io.vn` |
| `wireguard-init.sh` | The script the gateway runs once, on its first boot: it installs WireGuard, reads its keys and sets up its firewall |
| `rancher.tf` | A TCP 443 listener on the internal load balancer, and the name `rancher.recruitai.io.vn` |
| `main.tf` (one block changes) | Lets the nodes read the two Rancher secrets |

Create `infra/terraform/cluster/wireguard.tf`:
```hcl
variable "wireguard_cidr" {
  description = "VPN address range. Must not overlap the VPC, pod or Service CIDRs."
  type        = string
  default     = "10.99.0.0/24"
}

variable "wireguard_instance_type" {
  description = "Small gateway type known to be launchable by this account's Free plan."
  type        = string
  default     = "t3.small"
}

data "aws_secretsmanager_secret" "wireguard" {
  name = "${var.project}/wireguard"
}

resource "aws_iam_role" "wireguard" {
  name               = "${local.name}-wireguard"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "wireguard_ssm" {
  role       = aws_iam_role.wireguard.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "wireguard" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [data.aws_secretsmanager_secret.wireguard.arn]
  }
}

resource "aws_iam_role_policy" "wireguard" {
  name   = "read-wireguard-secret"
  role   = aws_iam_role.wireguard.id
  policy = data.aws_iam_policy_document.wireguard.json
}

resource "aws_iam_instance_profile" "wireguard" {
  name = "${local.name}-wireguard"
  role = aws_iam_role.wireguard.name
}

resource "aws_security_group" "wireguard" {
  name        = "${local.name}-wireguard"
  description = "WireGuard gateway; no SSH"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "wireguard_udp" {
  security_group_id = aws_security_group.wireguard.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  description       = "WireGuard handshake; unauthenticated packets are discarded"
}

resource "aws_vpc_security_group_egress_rule" "wireguard_all" {
  security_group_id = aws_security_group.wireguard.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Secrets Manager, SSM and private VPC destinations"
}

resource "aws_instance" "wireguard" {
  ami                    = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  instance_type          = var.wireguard_instance_type
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  iam_instance_profile   = aws_iam_instance_profile.wireguard.name
  # Gives cloud-init internet access immediately. Attaching the EIP below swaps this temporary
  # address for the stable VPN endpoint a few seconds after boot, which drops any connection open at
  # that moment, so every network step in wireguard-init.sh is retried.
  associate_public_ip_address = true
  # source_dest_check stays at its default (on). The gateway SNATs everything from the tunnel, so every
  # packet on its network card carries its own address, and AWS has nothing to block.

  user_data = templatefile("${path.module}/wireguard-init.sh", {
    region         = var.region
    secret_id      = data.aws_secretsmanager_secret.wireguard.name
    server_address = "${cidrhost(var.wireguard_cidr, 1)}/${split("/", var.wireguard_cidr)[1]}"
    peer_address   = cidrhost(var.wireguard_cidr, 2)
    wireguard_cidr = var.wireguard_cidr
    vpc_cidr       = var.vpc_cidr
    vpc_resolver   = cidrhost(var.vpc_cidr, 2) # the Route 53 Resolver sits at the VPC range plus two
  })
  # A changed script or address must reach the gateway. Without this, AWS would stop the instance, swap
  # the user data and start it again, but cloud-init runs the script only on the first boot.
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${local.name}-wireguard" }
  lifecycle { ignore_changes = [ami] }
}

resource "aws_eip" "wireguard" {
  domain   = "vpc"
  instance = aws_instance.wireguard.id
  tags     = { Name = "${local.name}-wireguard" }
}

resource "aws_route53_record" "vpn" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "vpn.${var.domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.wireguard.public_ip]
}

output "wireguard_instance_id" {
  value = aws_instance.wireguard.id
}

output "wireguard_public_ip" {
  value = aws_eip.wireguard.public_ip
}

# The address to put in the client profile. It is derived from wireguard_cidr, so changing that
# variable changes the server, the peer and this value together.
output "wireguard_client_address" {
  value = "${cidrhost(var.wireguard_cidr, 2)}/32"
}
```

Create `infra/terraform/cluster/wireguard-init.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# The EIP is attached a few seconds after boot and replaces the public address, which drops any
# connection open at that moment. Every step that uses the network is therefore retried, and fails
# the script only after ten attempts.
retry() {
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    "$@" && return 0
    sleep 10
  done
  return 1
}

# On first boot unattended-upgrades holds the dpkg lock for minutes. Wait for it inside apt, as the
# workstation does, rather than failing fast and burning the retries.
APT="apt-get -o DPkg::Lock::Timeout=600"
retry $APT update
retry $APT install -y wireguard-tools jq unzip iptables

# AWS CLI v2 from AWS's own URL, as on the ops workstation. Ubuntu's awscli package is not v2.
cd /tmp
retry curl -fsSL -o awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q awscliv2.zip
./aws/install --update

umask 077
retry aws --region "${region}" secretsmanager get-secret-value \
  --secret-id "${secret_id}" --query SecretString --output text > /run/wireguard-secret.json
jq -e '.serverPrivateKey and .operatorPublicKey' /run/wireguard-secret.json >/dev/null
PRIVATE_KEY=$(jq -r .serverPrivateKey /run/wireguard-secret.json)
PEER_KEY=$(jq -r .operatorPublicKey /run/wireguard-secret.json)
rm -f /run/wireguard-secret.json
INTERFACE=$(ip route show default | awk '{print $5; exit}')

# The tunnel is for Rancher. From wg0 the gateway forwards only DNS to the VPC
# resolver and TCP 443 into the VPC; everything else is dropped, including the Kubernetes API on 6443.
# Replies are let back in, but nothing in the VPC can open a connection towards the laptop, and
# nothing from the tunnel reaches the gateway itself. The rules live in their own chain, so PostDown
# removes them cleanly.
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${server_address}
ListenPort = 51820
PrivateKey = $PRIVATE_KEY
PostUp = iptables -N WG_FWD
PostUp = iptables -A WG_FWD -d ${vpc_resolver}/32 -p udp --dport 53 -j ACCEPT
PostUp = iptables -A WG_FWD -d ${vpc_resolver}/32 -p tcp --dport 53 -j ACCEPT
PostUp = iptables -A WG_FWD -d ${vpc_cidr} -p tcp --dport 443 -j ACCEPT
PostUp = iptables -A WG_FWD -j DROP
PostUp = iptables -A FORWARD -i wg0 -j WG_FWD
PostUp = iptables -A FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j DROP
PostUp = iptables -A INPUT -i wg0 -j DROP
PostUp = iptables -t nat -A POSTROUTING -s ${wireguard_cidr} -o $INTERFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${wireguard_cidr} -o $INTERFACE -j MASQUERADE
PostDown = iptables -D INPUT -i wg0 -j DROP
PostDown = iptables -D FORWARD -o wg0 -j DROP
PostDown = iptables -D FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j WG_FWD
PostDown = iptables -F WG_FWD
PostDown = iptables -X WG_FWD

[Peer]
PublicKey = $PEER_KEY
AllowedIPs = ${peer_address}/32
EOF

chmod 600 /etc/wireguard/wg0.conf
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard.conf
sysctl --system
systemctl enable --now wg-quick@wg0
touch /var/log/wireguard-ready
```

Create `infra/terraform/cluster/rancher.tf`:
```hcl
# Private TCP 443 on the existing internal NLB. Rancher itself is installed later by Argo CD; this
# file only creates its network path and stable name.

variable "ingress_https_nodeport" {
  description = "NodePort of ingress-nginx for HTTPS, targeted by the internal NLB."
  type        = number
  default     = 30443
}

variable "domain" {
  description = "Domain of the Route 53 zone the shared stack created. Must match its `domain`."
  type        = string
  default     = "recruitai.io.vn"
}

# TLS passes through the NLB unchanged; the load balancer never terminates it and never sees the key.
resource "aws_lb_target_group" "ingress_https" {
  name        = "${local.name}-ingress-https"
  port        = var.ingress_https_nodeport
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  # Rancher agents connect back through this NLB. Disabling preservation prevents a target that is
  # routed back to itself from failing NAT loopback. Rancher therefore sees NLB addresses, not the
  # client's; with a single WireGuard peer, any VPN session is that one operator.
  preserve_client_ip = false

  # Like the HTTP target group, a plain TCP check: the targets stay unhealthy until ingress-nginx is
  # installed, which does not happen until the GitOps phase.
  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "ingress_https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_https.arn
  }
}

resource "aws_lb_target_group_attachment" "ingress_https" {
  count = var.node_count

  target_group_arn = aws_lb_target_group.ingress_https.arn
  target_id        = aws_instance.nodes[count.index].id
  port             = var.ingress_https_nodeport
}

# TCP 443 is private. WireGuard SNATs the peer to the gateway's VPC address, and Rancher agents also
# originate inside the VPC.
resource "aws_vpc_security_group_ingress_rule" "api_nlb_https_from_vpc" {
  security_group_id = aws_security_group.api_nlb.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Private Rancher HTTPS from the VPC and WireGuard"
}

resource "aws_vpc_security_group_egress_rule" "api_nlb_to_nodes_https" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = var.ingress_https_nodeport
  to_port                      = var.ingress_https_nodeport
  description                  = "Forward and health-check to ingress-nginx TLS"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_ingress_https" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  ip_protocol                  = "tcp"
  from_port                    = var.ingress_https_nodeport
  to_port                      = var.ingress_https_nodeport
  description                  = "ingress-nginx TLS NodePort from the internal NLB"
}

# --- the name ----------------------------------------------------------------------------------------
data "aws_route53_zone" "main" {
  name         = "${var.domain}."
  private_zone = false
}

resource "aws_route53_record" "rancher" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "rancher.${var.domain}"
  type    = "A"

  # Internal load balancer names are publicly resolvable to private addresses. DNS works everywhere,
  # but only a client with a route into the VPC can connect: from outside, that means WireGuard.
  # Inside the VPC, Rancher's own agents connect to this name as well.
  alias {
    name    = aws_lb.api.dns_name
    zone_id = aws_lb.api.zone_id

    # With no healthy target there is nowhere else to send the query, so target health is not a
    # useful DNS signal here.
    evaluate_target_health = false
  }
}

output "rancher_url" {
  description = "The Rancher UI, once the GitOps phase has installed the chart"
  value       = "https://${aws_route53_record.rancher.name}"
}
```

**Change `infra/terraform/cluster/main.tf`.** Find the block `data "aws_secretsmanager_secret" "app"`
and replace it with this one. Replace it, do not add a second one: two blocks with the same name make
every `terraform` command fail.
```hcl
data "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github", "rancher", "rancher-tls"])
  name     = "${var.project}/${each.key}"
}
```
The nodes can now read the two Rancher secrets. The `wireguard` secret is deliberately not in this
list: of the roles in this stack, only the gateway's can read it.

Argo CD installs Rancher later; its chart pin, values, secret wiring and upgrade gate are in
[design §4.2.1](../../selfmanaged-k8s-ops-design.md#421-rancher-gitops-contract-and-compatibility-gate).

**Why:**

- **A dedicated gateway** keeps internet-facing UDP away from the administrator workstation and its
  `AdministratorAccess` role.
- **The tunnel is for Rancher only.** Security groups open the internal NLB to the whole VPC, because
  Rancher's own agents need it, so without a filter the VPN would also reach the Kubernetes API on
  6443. The gateway forwards only DNS and TCP 443, and the internal NLB is the only 443 listener in
  the VPC. The laptop has no `kubectl` anyway; the API stays reachable through `make tunnel` on the
  workstation.
- **Public DNS, private addresses.** The internal NLB's name resolves publicly to private addresses,
  so normal DNS and a public certificate work, while the network path still requires WireGuard.
- **TLS passes through unchanged.** ingress-nginx holds the key, and Rancher's agents avoid NLB
  hairpin failures because the HTTPS target group disables client-IP preservation.

**Commit and push** (laptop, Git Bash):
```bash
git add infra/terraform/cluster
git commit -m "Add private Rancher access through WireGuard"
git push
```

### 18.2 Create the WireGuard keys

WireGuard uses two key pairs: one for the laptop, one for the gateway. Each private key stays where it
was made; only the public keys are exchanged. The gateway reads its keys from Secrets Manager when it
first boots, which is why this part comes before `make infra`.

**1. Laptop — install WireGuard.** Download WireGuard for Windows from
<https://www.wireguard.com/install/>, install it, and open it.

**2. Laptop — create the laptop's key pair.**

- Click the small arrow next to **Add Tunnel**, then **Add empty tunnel…**.
- In **Name**, type `medical-rag`.
- The window shows a **Public key** line. Select the key after it and copy it (Ctrl+C); you paste it in
  part 5.
- Click **Save**.

The private key was generated inside this tunnel and stays there. In 18.4 you edit this same tunnel.
Do not create a second one: it would have a different key, which the gateway does not know.

**3. Workstation — install the WireGuard tools.**
```bash
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get -o DPkg::Lock::Timeout=600 install -y wireguard-tools
```

**4. Workstation — check that the keys are not stored yet.**
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/wireguard --query VersionId --output text
```
- **It prints an ID:** the keys already exist. Skip to 18.3. To replace the laptop's key, see *Only if
  the laptop's WireGuard key is lost* at the end of this step.
- **It prints an error mentioning `can't find the specified secret value`:** continue.

**5. Workstation — enter the laptop's public key.** Paste **only this line** and press Enter. At the
`Laptop public key:` prompt, paste the key from part 2 and press Enter:
```bash
read -r -p "Laptop public key: " OPERATOR_PUBLIC_KEY
```
Check what the variable now holds:
```bash
echo "${#OPERATOR_PUBLIC_KEY} $OPERATOR_PUBLIC_KEY"
```
Expect `44`, a space, then the key, ending in `=`. Anything else: run the `read` line again.

The variable exists only in this window. Run parts 6 and 7 in the same window; if the window closes,
run the `read` line again first.

**6. Workstation — create the gateway's key pair.**
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
wg genkey > wireguard-server.key
wg pubkey < wireguard-server.key > wireguard-server.pub
```
`umask 077` makes the files created from now on readable only by you. `wg genkey` writes a new private
key into `wireguard-server.key`; `wg pubkey` derives its public key into `wireguard-server.pub`.

**7. Workstation — store the keys in Secrets Manager.**

Put the gateway's private key and the laptop's public key into one JSON file:
```bash
jq -n \
  --rawfile serverPrivateKey wireguard-server.key \
  --arg operatorPublicKey "$OPERATOR_PUBLIC_KEY" \
  '{serverPrivateKey: ($serverPrivateKey | rtrimstr("\n")), operatorPublicKey: $operatorPublicKey}' \
  > wireguard.json
```
This reads the private key from the file (dropping its final newline), takes the laptop's key from the
variable, and writes both into `wireguard.json`. Check that both are there, without printing them:
```bash
jq -c 'keys' wireguard.json
jq -r '.operatorPublicKey | length' wireguard.json
```
Expect `["operatorPublicKey","serverPrivateKey"]`, then `44`. A `0` means the variable was empty: go
back to part 5.

Upload it:
```bash
aws secretsmanager put-secret-value --secret-id medical-rag/wireguard --secret-string file://wireguard.json
```
Expect a few lines ending with a `VersionId`. If it prints an error, fix the cause and run the upload
again. **Do not run the next command until the upload succeeds:** it deletes the only copy of the
gateway's private key.

Delete the private key file and the JSON file:
```bash
shred -u wireguard.json wireguard-server.key
```

Check the stored secret, without printing it:
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/wireguard --query SecretString --output text | jq -c 'keys'
```
Expect `["operatorPublicKey","serverPrivateKey"]`. The gateway's private key is now only in Secrets
Manager; `wireguard-server.pub` keeps its public key for 18.4.

### 18.3 Build the cluster

**Workstation.**
```bash
cd ~/Medical-RAG-Chatbot
git pull
make infra
```
Terraform prints the plan, then asks `Enter a value:`. Check the summary line, then type `yes`.

Expect **84 to add, 0 to change**: the cluster was destroyed at the end of step 15, so Terraform builds
the 65 resources of steps 9–14 plus the 19 new ones. If the cluster is still running from an earlier
session, expect 19 to add and 1 to change instead; the change is the node policy growing from two
secrets to four. Final baselines: 17 managed resources in `shared`, 84 in `cluster`.

### 18.4 Finish the laptop's tunnel

**1. Workstation — print the two values the tunnel needs.** The gateway's public key:
```bash
cat ~/tls/rancher.recruitai.io.vn/wireguard-server.pub
```
The laptop's address inside the VPN:
```bash
cd ~/Medical-RAG-Chatbot
terraform -chdir=infra/terraform/cluster output wireguard_client_address
```
It prints `"10.99.0.2/32"` unless you changed `wireguard_cidr`; use it without the quotes.

**2. Laptop — complete the tunnel.** In the WireGuard app, select `medical-rag` and click **Edit**. The
editor shows two lines, `[Interface]` and `PrivateKey = …`. Leave both exactly as they are. Below them,
add these lines, and replace `PASTE_THE_GATEWAY_PUBLIC_KEY_HERE` with the key printed in 1:
```ini
Address = 10.99.0.2/32
DNS = 10.10.0.2

[Peer]
PublicKey = PASTE_THE_GATEWAY_PUBLIC_KEY_HERE
Endpoint = vpn.recruitai.io.vn:51820
AllowedIPs = 10.10.0.0/16
PersistentKeepalive = 25
```
Click **Save**. Do not store this configuration in the repo.

What each line does:

- `Address` is the laptop's address inside the VPN.
- `DNS = 10.10.0.2` is the VPC's own resolver. Without it the laptop keeps asking its home router, and
  many routers drop answers that point at private `10.10.x.x` addresses, so the Rancher name would not
  resolve. If browsing stalls while the gateway is down, deactivate the tunnel.
- `Endpoint` is where the gateway listens. Every cluster rebuild gives the gateway a new public address
  behind this name. The profile stays the same, but deactivate and activate the tunnel so the new
  address is used.
- `AllowedIPs = 10.10.0.0/16` sends only traffic for the cluster VPC through the tunnel; everything
  else uses your normal connection.
- `PersistentKeepalive = 25` stops your home router from dropping the connection while it is idle.

### 18.5 Verify

Wait about five minutes after `make infra` finishes: on its first boot the gateway installs WireGuard and
reads its keys. Then do two checks on the laptop. `make infra` finishing without errors already proves
the load balancer listener and the DNS records exist; the 443 path itself can only be tested after
`make bootstrap`, below.

**1. The tunnel connects.** In the WireGuard app, click **Activate** on `medical-rag`. Within a few
seconds, **Latest handshake** shows a time, such as `5 seconds ago`.

A handshake proves the gateway is running with WireGuard started, `vpn.recruitai.io.vn` points at it,
UDP 51820 gets through, and each side has the other's correct public key. No handshake: see *If there is
no handshake* below.

**2. Traffic reaches the VPC.** With the tunnel active, open PowerShell (Start menu, type `PowerShell`)
and run:
```powershell
Resolve-DnsName rancher.recruitai.io.vn -Server 10.10.0.2
```
Expect three `10.10.x.x` addresses. `10.10.0.2` is the VPC's own DNS server, and it can only be reached
through the tunnel, so an answer proves the gateway forwards your traffic into the VPC and the Rancher
name exists. Keep `-Server`: without it, Windows may answer from public DNS, which returns the same
addresses even with the tunnel off. If it times out, see [Troubleshooting](troubleshooting.md).

That is all for this step.

**If there is no handshake.** Look inside the gateway. On the workstation:
```bash
cd ~/Medical-RAG-Chatbot
WG_ID=$(terraform -chdir=infra/terraform/cluster output -raw wireguard_instance_id)
aws ssm start-session --target "$WG_ID"
```
If it prints `TargetNotConnected`, the gateway is still starting, or was only just rebuilt: wait two or
three minutes and run the last command again. When the prompt changes to `$`, you are on the gateway.
Run:
```bash
cloud-init status --wait
```
It prints dots while the gateway is still setting itself up, then one of two answers.

**`status: error`** — the setup script stopped. Show its last lines, then leave the gateway:
```bash
sudo tail -20 /var/log/cloud-init-output.log
exit
```
The lines just above `Failed to run module scripts_user` show what went wrong:

- `ResourceNotFoundException` or `can't find the specified secret value`: the keys were not stored yet
  when the gateway booted. Store them (18.2).
- No error line above it: a key is missing from the secret. Check 18.2, part 7.
- Anything else: fix the cause it names.

Then rebuild only the gateway. On the workstation:
```bash
cd ~/Medical-RAG-Chatbot
make init
terraform -chdir=infra/terraform/cluster apply -replace=aws_instance.wireguard
```
`-replace` rebuilds that one machine. The plan must say **1 to add, 1 to change, 1 to destroy**: the
gateway is rebuilt and its Elastic IP moves to it, so the `vpn` address stays the same. If it shows
more, type `no` and check `git status`. Otherwise type `yes`, wait five minutes, and activate the tunnel
again.

**`status: done`** — the gateway is ready. Compare the keys:
```bash
sudo wg show
exit
```

- `public key:`, near the top, is the gateway's key. It must match `wireguard-server.pub` and the
  `PublicKey` under `[Peer]` in the laptop's tunnel.
- `peer:` must match the laptop's key: in the WireGuard app, the **Public key** under **Interface**.

If `peer:` differs, the laptop's tunnel was recreated: see *Only if the laptop's WireGuard key is lost*.
If `wg show` prints nothing, WireGuard did not start: see [Troubleshooting](troubleshooting.md), *Chain already exists*.

If both keys match, check that the laptop finds the gateway's current address. On the workstation:
```bash
cd ~/Medical-RAG-Chatbot
terraform -chdir=infra/terraform/cluster output wireguard_public_ip
```
On the laptop, in PowerShell:
```powershell
Resolve-DnsName vpn.recruitai.io.vn
```
The two addresses must be the same. If they differ, wait a minute, then deactivate and activate the
tunnel. If they are the same, your network may block UDP 51820: try again from a phone hotspot.

### Later, after `make bootstrap` — skip this now

These checks need ingress-nginx and Rancher, which the GitOps phase installs.

**1. The certificate, checked from the gateway.** The workstation has no route into the cluster VPC,
but the gateway has. Workstation — open a shell on the gateway:
```bash
cd ~/Medical-RAG-Chatbot
WG_ID=$(terraform -chdir=infra/terraform/cluster output -raw wireguard_instance_id)
aws ssm start-session --target "$WG_ID"
```
On the gateway:
```bash
openssl s_client -connect rancher.recruitai.io.vn:443 -servername rancher.recruitai.io.vn -brief </dev/null
exit
```
Expect a `Peer certificate:` line naming `rancher.recruitai.io.vn`, and `Verification: OK`. Anything else
after `Verification:` says what is wrong with the certificate chain.

**2. The public load balancer does not serve Rancher.** Workstation:
```bash
cd ~/Medical-RAG-Chatbot
PUBLIC_NLB=$(terraform -chdir=infra/terraform/cluster output -raw public_nlb_dns)
curl -sI -H 'Host: rancher.recruitai.io.vn' "http://$PUBLIC_NLB/"
```
The first line must be `HTTP/1.1 308 Permanent Redirect`: the only answer is a redirect to an address
the internet cannot reach.

**3. The browser and the firewall.** Laptop, with the tunnel active: `https://rancher.recruitai.io.vn`
loads. Deactivate the tunnel and it times out. With the tunnel active again, in PowerShell:
```powershell
Test-NetConnection rancher.recruitai.io.vn -Port 443
Test-NetConnection rancher.recruitai.io.vn -Port 6443
```
Expect `TcpTestSucceeded : True` for 443 and `False` for 6443. The Rancher name points at the internal
load balancer, which also carries the Kubernetes API on 6443; the gateway forwards only DNS and TCP
443, so 6443 stays closed.

### Only if the laptop's WireGuard key is lost — skip this now

**1. Laptop (the new one).** Install WireGuard, create an empty tunnel named `medical-rag`, and copy
its public key, exactly as in 18.2, parts 1 and 2.

**2. Workstation — enter the new public key.** Paste **only this line**, then the key at the prompt:
```bash
read -r -p "New laptop public key: " NEW_PUB
```
Check it:
```bash
echo "${#NEW_PUB} $NEW_PUB"
```
Expect `44`, a space, then the key, ending in `=`.

**3. Workstation — put the new key into the stored secret.** Download the current secret:
```bash
cd ~/tls/rancher.recruitai.io.vn
umask 077
aws secretsmanager get-secret-value --secret-id medical-rag/wireguard --query SecretString --output text > wireguard.json
```
Replace the laptop's key in it, and check the result:
```bash
jq --arg key "$NEW_PUB" '.operatorPublicKey = $key' wireguard.json > wireguard-new.json
jq -r '.operatorPublicKey' wireguard-new.json
```
The second command must print the new key. Upload it:
```bash
aws secretsmanager put-secret-value --secret-id medical-rag/wireguard --secret-string file://wireguard-new.json
```
Expect a `VersionId`. Then delete both files, which hold the gateway's private key:
```bash
shred -u wireguard.json wireguard-new.json
```

**4. Apply it.** The gateway reads the key only when it is created.

- **Cluster destroyed** (the usual state): nothing else to do. The next `make infra` uses the new key.
- **Cluster running:** replace only the gateway, with the commands below.

```bash
cd ~/Medical-RAG-Chatbot
make init
terraform -chdir=infra/terraform/cluster apply -replace=aws_instance.wireguard
```
`-replace` rebuilds that one machine. Check that the plan says **1 to add, 1 to change, 1 to destroy**
(the gateway is rebuilt, and its Elastic IP moves to the new instance, so the address and the `vpn`
record stay the same), then type `yes`. Afterwards the old key no longer connects and the new one does.
Finish the new laptop's tunnel as in 18.4.

---

[← Part 5](5-domain-certificate-and-secrets.md) · [Index](../guide.md) · [Part 7 →](7-internal-uis.md) · [Troubleshooting](troubleshooting.md)
