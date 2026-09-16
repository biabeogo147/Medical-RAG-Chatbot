#!/usr/bin/env bash
# Installs Terraform into ~/bin. Used once in AWS CloudShell, which has no Terraform, to create the
# workstation that does. No -x here: you run this by hand, so keep the output quiet unless it fails.
set -euo pipefail

VERSION="${TERRAFORM_VERSION:-1.16.2}" # use the environment variable if set, otherwise this default

# Pick the right build, and refuse anything else instead of downloading a binary that cannot run.
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$HOME/bin"  # the guide adds this folder to PATH
cd "$(mktemp -d)"     # download into a throwaway folder: the CloudShell home holds only 1 GB

curl -fsSLO "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_${ARCH}.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_SHA256SUMS"
grep " terraform_${VERSION}_linux_${ARCH}.zip$" "terraform_${VERSION}_SHA256SUMS" | sha256sum -c -
unzip -o "terraform_${VERSION}_linux_${ARCH}.zip" terraform -d "$HOME/bin" # extract only the binary
"$HOME/bin/terraform" version
