#!/bin/bash
# cloud-init user data for the ops workstation. Runs once, as root, on first boot.
# Progress: /var/log/cloud-init-output.log. Finished when /var/log/workstation-ready exists.
#
#   -e  stop at the first failing command, instead of continuing on a broken machine
#   -u  an undefined variable is an error, not an empty string
#   -x  print each command, so the log shows exactly where it stopped
#   -o pipefail  a failure anywhere in a pipeline fails the pipeline
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive # apt never stops to ask: nobody is here to answer

# Pinned versions: rebuilding this machine installs exactly the same tools.
TERRAFORM_VERSION=1.16.2
KUBECTL_VERSION=v1.35.8
HELM_VERSION=v4.3.0
COSIGN_VERSION=v3.1.3
YQ_VERSION=v4.53.6
GH_VERSION=2.100.0

# On first boot unattended-upgrades holds the apt/dpkg lock: wait for it, and retry the index update.
# If all 20 attempts fail the loop still exits 0, so the install continues on a stale package index.
APT="apt-get -o DPkg::Lock::Timeout=600"
for i in $(seq 20); do $APT update && break; sleep 15; done
# python3-boto3 is what Ansible's AWS modules and its SSM connection plugin need later.
$APT install -y git make unzip jq curl ca-certificates bash-completion tmux \
  docker.io docker-buildx ansible python3-boto3 python3-botocore
# Lets you run docker without sudo. It applies at the next login, hence `sudo su - ubuntu`.
usermod -aG docker ubuntu

# Default region for the AWS CLI and Terraform, read from instance metadata.
# 169.254.169.254 is reachable only from the instance itself. The PUT first, then the token header,
# is IMDSv2, required by http_tokens = "required".
IMDS_TOKEN=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/placement/region)
# Every login shell exports it, so no AWS command needs --region.
echo "export AWS_REGION=${REGION} AWS_DEFAULT_REGION=${REGION}" > /etc/profile.d/aws-region.sh

cd "$(mktemp -d)" # work in a throwaway folder

# Each download below is checked against the checksum file published with the release:
#   curl -f fail on HTTP errors, -s silent, -S still show real errors, -L follow redirects, -O keep the name
#   grep ... | sha256sum -c -   picks this file's line out of the checksum list and verifies it

# Terraform
curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
grep " terraform_${TERRAFORM_VERSION}_linux_amd64.zip$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -
unzip -o "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" terraform -d /usr/local/bin

# kubectl
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  kubectl" | sha256sum -c -
install -m 0755 kubectl /usr/local/bin/kubectl # copy and set the executable bit in one step

# Helm: --strip-components=1 drops the leading folder of the archive
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz" --strip-components=1 -C /usr/local/bin linux-amd64/helm

# cosign
curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt"
grep " cosign-linux-amd64$" cosign_checksums.txt | sha256sum -c -
install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign

# yq: its checksum file uses the BSD format, so sed rewrites the line into "<hash>  <file>"
curl -fsSLO "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
curl -fsSLO "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums-bsd"
grep "^SHA256 (yq_linux_amd64) " checksums-bsd | sed 's/^SHA256 (\(.*\)) = \(.*\)$/\2  \1/' | sha256sum -c -
install -m 0755 yq_linux_amd64 /usr/local/bin/yq

# GitHub CLI
curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.deb"
curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt"
grep " gh_${GH_VERSION}_linux_amd64.deb$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c -

# AWS CLI v2 and the Session Manager plugin, needed by Ansible over SSM and by the kubectl tunnel.
# Both come from AWS's own vendor URLs, which publish no SHA256 checksum file (the AWS CLI has only a
# detached GPG signature).
curl -fsSL -o awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q awscliv2.zip
./aws/install --update
curl -fsSLO https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb

# Installed through apt, not `dpkg -i`, because only apt waits for the dpkg lock. With set -e a locked
# dpkg would abort the whole script.
$APT install -y ./session-manager-plugin.deb "./gh_${GH_VERSION}_linux_amd64.deb"

touch /var/log/workstation-ready # the finish flag checked in step 5 of the guide
