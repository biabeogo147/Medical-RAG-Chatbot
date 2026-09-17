# Runbook

The whole life of the platform in one page, in order. Each step names the guide that explains it; the
commands here are the short form.

| Guide | Covers |
|---|---|
| [`terraform/guide.md`](terraform/guide.md) | AWS: state bucket, ops workstation, shared services, cluster network and machines, DNS, VPN, internal UI names |
| [`ansible/guide.md`](ansible/guide.md) | The HA Kubernetes cluster on those machines |
| [`gitops/guide.md`](gitops/guide.md) | Argo CD and everything it installs |

## Prerequisites

- An AWS account with an admin identity, and a browser.
- On the laptop only: git, an editor and the WireGuard client. Every other tool runs on the ops
  workstation in AWS, and application images are built in the cluster.
- The domain `recruitai.io.vn` and a Sectigo certificate order for `rancher.recruitai.io.vn`.
- A Hugging Face token with the *Inference Providers* permission and a Gemini API key.
- A GitHub token that can push to this repository and open pull requests.
- A mailbox with an app password for alert email.

## 1. Once per account: state bucket and ops workstation

In **AWS CloudShell** ([Terraform guide, Part A](terraform/guide.md#part-a--bootstrap)):
```bash
git clone https://github.com/biabeogo147/Medical-RAG-Chatbot
cd Medical-RAG-Chatbot
./infra/terraform/bootstrap/install-terraform.sh
terraform -chdir=infra/terraform/bootstrap init
terraform -chdir=infra/terraform/bootstrap apply
```
Then finish [Terraform guide step 6](terraform/guide.md#step-6--move-the-bootstrap-state-into-s3-laptop--cloudshell)
(laptop + CloudShell), which moves the bootstrap state into S3.

Every later step runs on the **ops workstation**, opened from **EC2 → Instances → Connect → Session
Manager**:
```bash
sudo su - ubuntu
git clone https://github.com/biabeogo147/Medical-RAG-Chatbot
cd Medical-RAG-Chatbot
```
Edit on the laptop, push, and `git pull` on the workstation.

## 2. Once: long-lived services

ECR, the index artifacts bucket, the cosign KMS key, the Route 53 zone, empty secrets and the budget
alarm ([Terraform guide, Part B](terraform/guide.md#part-b--shared-stack-kept)). They survive every
cluster teardown.
```bash
cp infra/terraform/shared/terraform.tfvars.example infra/terraform/shared/terraform.tfvars   # set budget_email
make shared
```

## 3. Once: DNS, certificate, VPN keys, secret values

- **Before changing the name servers, copy every existing DNS record to Route 53**, or the domain's
  web and mail records go dark. Then delegate the zone, create the Sectigo CSR outside the repository,
  and store the Rancher password and certificate chain:
  [Terraform guide step 17](terraform/guide.md#step-17--migrate-dns-and-store-the-keys).
- Create the WireGuard keys: [step 18](terraform/guide.md#step-18--wireguard-and-the-private-rancher-entry-point).
  **The keys must be in Secrets Manager before the first `make infra`**, because the gateway reads them
  once, when it first boots.
- Store the SMTP settings for alert email: [step 19](terraform/guide.md#step-19--internal-ui-names-dns-permission-for-cert-manager-two-secrets).
- Store the application keys:
  ```bash
  aws secretsmanager put-secret-value --secret-id medical-rag/llm \
    --secret-string '{"GOOGLE_API_KEY":"...","HUGGINGFACEHUB_API_TOKEN":"...","FLASK_SECRET_KEY":"..."}'
  aws secretsmanager put-secret-value --secret-id medical-rag/github \
    --secret-string '{"token":"..."}'
  ```

## 4. Every session: build the platform

```bash
make infra                 # network, 3 nodes, 2 load balancers, WireGuard gateway, DNS names
make ansible-deps          # once per workstation
make ping                  # all 3 nodes answer over SSM before anything is installed
make cluster               # HA kubeadm cluster over SSM; writes the kubeconfig
```
In a second tmux window, and keep it open:
```bash
make tunnel                # kubectl reaches the internal API through node 1
```
Back in the first window:
```bash
kubectl get nodes          # 3 nodes, all Ready
make bootstrap             # Argo CD, which then installs everything in deploy/argocd/
make apps                  # every Application Synced and Healthy
```
`make bootstrap` and `make apps` are added to the Makefile in
[GitOps guide step 3](gitops/guide.md#step-3--the-root-application-and-argo-cd-managing-itself), `make down` in
[step 12](gitops/guide.md#step-12--make-down).

The very first time, finish the laptop's tunnel profile and verify the handshake after this
`make infra` (Terraform guide steps 18.4 and 18.5). After every rebuild, deactivate and activate the
tunnel: the gateway has a new public address.

Connect WireGuard on the laptop, then open the internal UIs:

| UI | Address |
|---|---|
| Argo CD | `https://argocd.recruitai.io.vn` |
| Grafana | `https://grafana.recruitai.io.vn` |
| Prometheus | `https://prometheus.recruitai.io.vn` |
| Alertmanager | `https://alertmanager.recruitai.io.vn` |
| Rancher | `https://rancher.recruitai.io.vn` |

Without the VPN, each of them times out.

## 5. Ship a change

Push to `main`. Jenkins polls every 2 minutes ([design §4.5](selfmanaged-k8s-ops-design.md#45-ci-pipeline-jenkins-jenkinsfile)), then:

1. runs lint and tests
2. builds the image with rootless BuildKit and pushes it to ECR
3. scans it with Trivy and generates the SBOM with Syft
4. signs it with Cosign, using the KMS key
5. updates `deploy/envs/dev/values.yaml`; Argo CD rolls out `dev`
6. opens a pull request with the same change for `prod`

Merging the pull request releases to `prod`.

## 6. Verify a release

```bash
NLB=$(terraform -chdir=infra/terraform/cluster output -raw public_nlb_dns)
curl "http://$NLB/readyz"             # prod
curl "http://$NLB/dev/readyz"         # dev
IMAGE_REPO=$(yq .image.repository deploy/envs/prod/values.yaml)
IMAGE_TAG=$(yq .image.tag deploy/envs/prod/values.yaml)
cosign verify --key awskms:///alias/medical-rag-cosign "${IMAGE_REPO}:${IMAGE_TAG}"
```

## 7. Operating the app

- **Index refresh:** changing the PDF, the chunk settings or the embedding model produces a new index
  version. An Argo CD PreSync Job builds it before the pods roll, and skips the build if that version
  already exists.
- **Index rollback:** revert `index.version` in `deploy/envs/<env>/values.yaml`. Argo CD syncs the
  previous index back.
- **Retrieval and model tuning:** set `RETRIEVER_K` or `MODEL_NAME` in the environment values and promote
  through `dev` → `prod`. Changing `EMBEDDING_MODEL_NAME` also produces a new `index.version`, so promote
  both together.
- **Cluster day-2:** etcd snapshots to S3, and Kubernetes upgrades one node at a time after the
  [Rancher compatibility gate](selfmanaged-k8s-ops-design.md#421-rancher-gitops-contract-and-compatibility-gate)
  passes ([design §4.6](selfmanaged-k8s-ops-design.md#46-day-2-operations-p1)).

## 8. End of every session

```bash
make down                  # needs `make tunnel` open: releases the EBS volumes, then destroys the cluster stack
```
Then stop the workstation (EC2 → Instances → Instance state → Stop). The shared stack, the secrets and
the certificate backup stay; the next session starts again at step 4.
