# The tools the pipeline needs, in a container with a shell. cosign and gh publish images without one, and the
# Jenkins Kubernetes plugin runs every step through a shell, so they are collected here instead.
# Everything is pinned and checked against a published checksum, like the ops workstation's own setup.
# Pinned by digest, for the same reason as the app's base image (step 13). `docker manifest inspect
# alpine:3.22 | jq -r '.manifests[0].digest'` on the workstation prints the digest to paste here.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

ARG COSIGN_VERSION=v3.1.3
ARG GH_VERSION=2.100.0

# aws-cli, git, yq and jq come from Alpine's own repositories, so apk pins them to this Alpine release.
RUN apk add --no-cache aws-cli git yq jq curl openssl ca-certificates

# cosign and gh are released as binaries with checksum files.
RUN curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
 && curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt" \
 && grep " cosign-linux-amd64$" cosign_checksums.txt | sha256sum -c - \
 && install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
 && grep " gh_${GH_VERSION}_linux_amd64.tar.gz$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && install -m 0755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf cosign-linux-amd64 cosign_checksums.txt gh_* \
 && cosign version && gh --version && aws --version && yq --version && git --version

# A real user, so that HOME exists and anything that writes a cache (git, gh, aws) has somewhere to put it.
RUN adduser -D -u 1000 ci
USER ci
ENV HOME=/home/ci
