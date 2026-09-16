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

# The tunnel reaches Rancher and nothing else. From wg0 the gateway forwards only DNS to the VPC
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
