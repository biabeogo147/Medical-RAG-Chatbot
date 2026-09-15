# Medical RAG Chatbot — Self-Managed Kubernetes on AWS (Ops Upgrade Design)

- **Date:** 2026-09-15
- **Timebox:** Days 1–3 of a 7-day plan shared with Anime-Recommender (EKS)
- **Budget:** ~0.46 USD/hour while running in ap-southeast-1 (plus ~0.06 USD/hour for the ops workstation); destroyed when idle
- **Target role:** DevOps / Platform / SRE (LLMOps as a bonus)

## 1. Goal

Rebuild this project's operations the way a company running Kubernetes itself would. The four pillars:

- **Reproducible infrastructure:** Terraform + Ansible, with no manual steps.
- **GitOps delivery:** Jenkins does CI and Argo CD does CD, with dev → prod promotion by pull request.
- **Supply-chain security:** scan, SBOM, KMS-backed signing, and admission verification.
- **Day-2 operations:** etcd backup/restore and cluster upgrades.

Every P0 item must leave measurable evidence in `docs/evidence/` for the CV and for interviews.

This project is the **self-managed** counterpart to Anime-Recommender, which runs on **EKS**. Features are split deliberately so the two projects tell different stories:

| Concern | Medical (this repo) | Anime (EKS) |
|---|---|---|
| Cluster | kubeadm on EC2, HA control plane | EKS managed |
| CI | Jenkins in-cluster | GitHub Actions |
| Image signing | Cosign with AWS KMS key | Cosign keyless (GitHub OIDC) |
| Focus | Cluster ops, delivery, supply chain | SLOs, canary, autoscaling, LLM observability |

### Non-goals
- A custom domain or TLS certificate (the public NLB serves HTTP; P2 is cert-manager).
- Multi-region operation or disaster recovery of AWS resources beyond etcd.
- A service mesh.
- Canary rollouts and SLO burn-rate alerting (these belong to Anime).

## 2. Current state (verified 2026-09-15)

**App:**
- Flask dev server on :8000.
- LangChain RetrievalQA (k=1) over FAISS, built from one 759-page PDF (7,079 chunks at 500/50).
- Gemini API `gemma-3n-e2b-it`; embeddings via the HF Inference API.

**Delivery and infrastructure today:**
- `docker-entrypoint.sh` rebuilds the whole index on **every pod start**, before Flask listens.
- A 6-stage Jenkinsfile on a separate VM pushes to Docker Hub and runs `kubectl apply` with a raw admin kubeconfig.
- Cluster setup scripts live in the `MLops-Common` submodule: bash, manual, on-prem IPs.

**Known issues this design fixes:**
1. The index is rebuilt at each start. Startup is slow, costs HF API quota, and the liveness probe can kill the pod mid-build.
2. `create_qa_chain()` reloads FAISS and the LLM client on every request.
3. The Flask dev server runs in production, and the only health check is `/`.
4. The Secret name in the README (`medical-rag-chatbot-secret`) does not match the Deployment (`...-secrets`). The Ingress is still named `streamlit-ingress`.
5. CI deploys by push with cluster-admin credentials, there is no image scanning or signing, and the image tag is `sed`-replaced.
6. `embed_documents` sends all chunks in one request, with no batching and no retry.

### Prerequisites
- An AWS account and an identity with admin access, used once from **AWS CloudShell** to apply the bootstrap stack.
- **Nothing is installed on the operator's Windows laptop** beyond an editor and git. Every ops command (Terraform, Ansible, kubectl, Helm, Docker, cosign) runs on the **ops workstation**, an EC2 Ubuntu 24.04 instance created by the bootstrap stack (see §4.0).
- An HF token **with the "Inference Providers" permission**; the current token returns 403. A Gemini API key.

## 3. Architecture

```
                         ┌──────────────────────── AWS VPC 10.10.0.0/16 (3 AZ) ─────────────────────────┐
 Internet ──► public NLB :80 ──► NodePort 30080 ingress-nginx ──► medical-rag (prod | dev namespaces)       │
                         │                                                                                  │
 Operator ──► SSM Session Manager (no SSH, no bastion)                                                      │
                         │  private subnets                                                                 │
                         │  ┌─────────── node-1 ───────────┐ ┌── node-2 ──┐ ┌── node-3 ──┐                   │
                         │  │ control-plane + worker       │ │   same     │ │   same     │  t3.large ×3      │
                         │  │ etcd, containerd, Calico     │ └────────────┘ └────────────┘                   │
                         │  └──────────────────────────────┘                                                  │
                         │  internal NLB :6443 ──► kube-apiserver ×3 (kubeadm controlPlaneEndpoint)          │
                         │  NAT GW (1 AZ) ──► Gemini API, HF Inference API, GitHub, ECR                     │
                         └──────────────────────────────────────────────────────────────────────────────────┘
 AWS services: ECR (images + signatures) · S3 (FAISS index artifacts, etcd snapshots, SSM transfer, TF state)
               KMS (cosign key) · Secrets Manager (API keys) · Budgets (50/100 USD alarms)
```

### In-cluster components
All components except Argo CD are installed **by Argo CD** from `deploy/argocd/`:

| Component | Purpose |
|---|---|
| Argo CD | GitOps controller. Bootstrapped once by `make bootstrap`, then self-managed. |
| ingress-nginx | NodePort 30080/30443, targeted by the public NLB |
| aws-ebs-csi-driver | PersistentVolumes for Jenkins and Prometheus (IAM via instance profile) |
| external-secrets | Syncs Secrets Manager into K8s Secrets (instance-profile auth) |
| kube-prometheus-stack | Cluster and app metrics, Grafana (reached by port-forward only) |
| Jenkins (Helm, JCasC) | CI controller. Agents are ephemeral pods. |
| medical-rag (Helm chart) | The app, as 2 Argo CD Applications: `medical-rag-dev`, `medical-rag-prod` |
| kyverno (P1) | Image signature verification + baseline pod policies |

## 4. Components

### 4.0 Ops workstation (`infra/terraform/bootstrap/`)
The bootstrap stack is applied once from AWS CloudShell and creates the two things every other stack depends on:
- **State bucket:** versioned, encrypted, Block Public Access, TLS-only policy, `prevent_destroy`. After the first apply, the bootstrap stack's own state is migrated into this bucket (key `bootstrap/terraform.tfstate`).
- **Ops workstation:**
  - `t3.medium` Ubuntu 24.04 in its own small VPC (`10.20.0.0/24`, one public subnet, no NAT), so it does not depend on the default VPC; 30 GB gp3 encrypted.
  - No inbound rules, no key pair, IMDSv2 required.
  - Reached only with SSM Session Manager from the AWS Console.
  - IAM role with `AdministratorAccess` (lab trade-off, documented) and `AmazonSSMManagedInstanceCore`, so no access keys exist anywhere.
  - cloud-init (`workstation-init.sh`) installs pinned versions of Terraform, Ansible, kubectl, Helm, Docker, make, AWS CLI v2, the Session Manager plugin, cosign, yq and gh.
  - Stopped when idle; `make down` never touches it.

**Workflow:** edit on the laptop → push to GitHub → `git pull` on the workstation → run `make`.


### 4.1 Terraform (`infra/terraform/`)
- **Stacks split by lifetime,** all with state in the bootstrap bucket (native S3 lockfile, `use_lockfile = true`):
  - `bootstrap/` (§4.0): state bucket and ops workstation. Applied from CloudShell only.
  - `shared/`: ECR, the index artifacts bucket, the cosign KMS key, Secrets Manager secrets, budgets. Kept, so a daily cluster teardown never loses the index, secret values, the signing key or images.
  - `cluster/`: everything below except those. Looks up shared resources with data sources by name; destroyed when idle.
- A step-by-step build guide is in `docs/terraform-guide.md`.
- **Network:** VPC with 3 public and 3 private subnets and 1 NAT gateway (cost choice, documented as a single point of failure).
- **Compute:**
  - 3× `t3.large` Ubuntu 24.04 across 3 AZs, gp3 encrypted root volumes.
  - IMDSv2 required, no public IPs, no key pair.
  - The SSM agent is present on the Ubuntu AMI.
- **Load balancers:**
  - Internal NLB TCP 6443 → the 3 nodes.
  - Public NLB TCP 80 → NodePort 30080 on the 3 nodes.
- **Security groups:**
  - 6443 only from inside the VPC.
  - NodePorts only from the NLB subnets.
  - Node-to-node traffic for Calico (BGP 179 or VXLAN 4789, per the chosen mode), etcd 2379–2380, and kubelet 10250.
- **IAM instance profile:**
  - `AmazonSSMManagedInstanceCore`
  - ECR read + write, the latter scoped to the repository for Jenkins BuildKit pushes
  - S3 read/write on the artifacts and backup buckets
  - `secretsmanager:GetSecretValue` on the `medical-rag/*` prefix
  - `kms:Sign` and `kms:GetPublicKey` on the cosign key
  - The EBS CSI policy
- **Registry, storage and keys:**
  - ECR `medical-rag` with scan on push and a lifecycle policy keeping the last 20 images.
  - S3 buckets `*-artifacts` (versioned), `*-etcd-backups` (lifecycle 14 days) and `*-ssm-transfer`, all with Block Public Access and TLS-only policies.
  - KMS asymmetric key `ECC_NIST_P256` / `SIGN_VERIFY`, alias `alias/medical-rag-cosign`.
- **Secrets Manager:** empty secrets `medical-rag/llm` (GOOGLE_API_KEY, HUGGINGFACEHUB_API_TOKEN, FLASK_SECRET_KEY) and `medical-rag/github` (bot token). Values are set with the AWS CLI, never in Terraform.
- **Budgets:** alarms at 50 and 100 USD.
- **Tagging:** default tags `project`, `env`, `owner`, `managed-by=terraform`.
- **Inputs:** `shared/terraform.tfvars` (from the `.example`): budget email. Everything else has defaults.
- **Outputs:** instance IDs, NLB DNS names, bucket names, ECR URL, and KMS ARN. Ansible and Helm values consume these outputs; nothing is hard-coded.

### 4.2 Ansible (`infra/ansible/`)
These roles replace the `MLops-Common` bash scripts and must be idempotent: a second run reports `changed=0`.

- **Inventory:** `amazon.aws.aws_ec2` filtered by tag. Connection plugin `amazon.aws.aws_ssm`, using the SSM transfer bucket. No SSH.
- **Roles:**
  - `common`: swap off, kernel modules, sysctl, time sync.
  - `containerd`: `SystemdCgroup=true`, pinned version.
  - `kubernetes_packages`: kubelet, kubeadm and kubectl from pkgs.k8s.io, **pinned to minor N-1** (currently 1.35) so the upgrade drill has somewhere to go. Packages are held.
  - `ecr_credential_provider`:
    - Installs `ecr-credential-provider` from kubernetes/cloud-provider-aws.
    - Sets kubelet `--image-credential-provider-config`.
    - Result: nodes pull from ECR with the instance profile and no imagePullSecrets.
  - `kubeadm_init`: first node, with a `kubeadm-config.yaml` setting `controlPlaneEndpoint = internal NLB DNS:6443` and `--upload-certs`.
  - `kubeadm_join`: the remaining control planes, with the join token and certificate key passed via facts, never written to the repo.
  - `cni_calico`: operator install with a pinned version and a pod CIDR that does not overlap the VPC.
  - `untaint_control_plane`: all 3 nodes schedule workloads, matching the current design.
- **Playbooks:**
  - `site.yml`: full cluster.
  - `upgrade.yml` (P1): `serial: 1`, drain, `kubeadm upgrade apply|node`, upgrade kubelet, uncordon, then wait for Ready and for all Argo CD apps to be Healthy before the next node.

### 4.3 App changes (`src/app/`, `tests/`)

**Serving and health**
- **Server:** gunicorn (2 workers, gthread, timeout 60s) replaces `app.run`. The Dockerfile `CMD` runs gunicorn, and `docker-entrypoint.sh` is removed.
- **Chain caching:** the QA chain is built **once per worker** at startup. `create_qa_chain()` is cached.
- **Endpoints:**
  - `GET /healthz`: process alive, no dependencies checked.
  - `GET /readyz`: FAISS index loaded and LLM client constructed. Returns 503 until ready.
  - `GET /metrics`: `prometheus_client` with `http_requests_total{route,status}`, `http_request_duration_seconds` (buckets up to 30s), `rag_retrieval_duration_seconds`, `llm_request_duration_seconds` and `rag_index_info{version}`.
- **Probes:** startupProbe on `/readyz` (failureThreshold × period = 5 min), readinessProbe on `/readyz`, livenessProbe on `/healthz`.

**Index as a versioned artifact**
- **CLI:** new `python -m app.index build` command.
- **Version hash:** `sha256(pdf bytes + chunk_size + chunk_overlap + embedding model id)`, truncated to 12 hex characters.
- **Idempotent upload:** if `s3://<artifacts>/faiss/<version>/index.faiss` already exists, exit 0 without re-embedding. Otherwise embed in **batches of 64 with exponential-backoff retry on 429/5xx**, then upload `index.faiss`, `index.pkl` and `manifest.json` (version, chunk count, model, build time, duration).
- **Kubernetes Job:** the build runs as a Job defined as an Argo CD **PreSync hook** in the chart, so a new index version is built before the Deployment rolls.
- **Pinned in values:** `index.version` in `deploy/envs/<env>/values.yaml`. An initContainer (aws-cli image) syncs that version into an `emptyDir`. **Rolling back the index = reverting one line in Git.**

**Container hardening**
- Multi-stage build.
- Non-root UID 10001, `readOnlyRootFilesystem: true`, drop ALL capabilities, `seccompProfile: RuntimeDefault`.
- Writable `emptyDir` for `/tmp` and the index.
- `.dockerignore` excludes `.git`, `data/` (the PDF comes from S3 in the Job), logs and vectorstore.

**Tests (pytest)**
- Chunking parameters.
- Index version hashing is deterministic.
- `/healthz` and `/readyz` status codes with a stubbed chain.
- Batch embedding retry logic with a fake client.

### 4.4 Helm chart and environments (`deploy/`)

```
deploy/
  charts/medical-rag/        Deployment, Service, Ingress, index-build Job (PreSync hook), ExternalSecret,
                             ServiceMonitor, PDB, NetworkPolicy, ServiceAccount
  envs/dev/values.yaml       1 replica, image.tag, index.version, ingress path /dev
  envs/prod/values.yaml      2 replicas, topologySpreadConstraints (hostname), PDB minAvailable 1
  argocd/root.yaml           app-of-apps
  argocd/apps/*.yaml         addons + medical-rag-dev + medical-rag-prod
```

- **Ingress routing:** without a domain, the public NLB routes by path: `/dev` → dev and `/` → prod. The app must therefore honor `SCRIPT_NAME` / prefix.
- **NetworkPolicy:** default deny ingress in the app namespaces; allow from the `ingress-nginx` and `monitoring` namespaces; allow egress DNS + TCP 443.
- **Sync policies:** Argo CD automated sync with prune and selfHeal for dev. **prod syncs automatically, but its values file changes only through a reviewed PR.**

### 4.5 CI pipeline (Jenkins, `Jenkinsfile`)

**Jenkins setup**
- Jenkins is installed by Argo CD with the Helm chart and JCasC.
- **Job:** a Multibranch Pipeline on this repo polls SCM every 2 minutes, because there's no public webhook endpoint.
- **Agents:** pod templates run `python:3.12`, `moby/buildkit:rootless`, `aquasec/trivy`, `anchore/syft`, `cosign` and `alpine/git`.
- **Why not Kaniko:** Kaniko was archived upstream, so the design uses rootless BuildKit.
- **Kubernetes RBAC:** the Jenkins service account has **no cluster RBAC beyond its own namespace**. CI never talks to the Kubernetes API for deploys.

**Stages**
1. **Skip guard:** abort the build as NOT_BUILT if the commit author is `jenkins-bot` or the change set touches only `deploy/**`. This prevents a loop.
2. **Lint & test:** `ruff check`, `pytest -q`, `hadolint Dockerfile`.
3. **Build & push:** BuildKit → ECR `medical-rag:<git-sha>`, with registry cache in ECR.
4. **Scan:** `trivy image --severity CRITICAL --ignore-unfixed --exit-code 1`. The HIGH count is recorded in the report but does not fail the build. The JSON report is archived.
5. **SBOM:** `syft` → SPDX JSON, archived.
6. **Sign & attest:**
   - `cosign sign --key awskms:///alias/medical-rag-cosign <digest>`
   - `cosign attest --type spdxjson` with the same KMS key
   - The instance profile provides the KMS permission.
7. **Promote to dev:**
   - Clone the repo using a GitHub token from ExternalSecret.
   - `yq` sets `image.tag` (and `index.version` if the corpus or chunk config changed) in `deploy/envs/dev/values.yaml`.
   - Commit as `jenkins-bot`, push to `main`.
8. **Open prod PR:**
   - `gh pr create` with the same change applied to `deploy/envs/prod/values.yaml`.
   - The body includes the Trivy summary and the image digest.
   - A human merges.

Images are referenced **by digest** in values as `tag@sha256:...`, so what was signed is exactly what runs.

### 4.6 Day-2 operations (P1)
- **etcd backup:**
  - A CronJob on control-plane nodes (nodeSelector + toleration, hostPath `/etc/kubernetes/pki/etcd`).
  - Runs `etcdctl snapshot save` every 6h and uploads to S3. `snapshot status` is verified before upload.
- **Restore drill** (`docs/runbooks/etcd-restore.md`):
  1. Delete a test namespace.
  2. Restore the latest snapshot on all 3 members.
  3. Verify the namespace is back.
  4. **Record the RTO** from the start of restore to all Argo CD apps Healthy.
- **Kyverno:**
  - `verifyImages` for `*.dkr.ecr.*/medical-rag*` with the KMS public key. Mode `Enforce` in prod and `Audit` in dev.
  - Baseline Pod Security policies.
  - Demo: deploying an unsigned image to prod is rejected, with the admission error captured as evidence.
- **Upgrade drill:** `ansible-playbook upgrade.yml` takes 1.35 → 1.36. k6 or a curl loop hits prod throughout, and failed requests are recorded; the target is 0.

## 5. Error handling and failure modes

| Failure | Behavior |
|---|---|
| HF API 429/5xx during index build | Batched retry with backoff (max 6 attempts). After that the Job fails, the Argo CD sync fails, and **the old Deployment keeps serving the old index**. |
| Index version missing in S3 at pod start | The initContainer fails, the pod never becomes Ready, and the rolling update stalls because old pods stay up (maxUnavailable 0). |
| Gemini API error at request time | 502 with a JSON error; counted in `http_requests_total{status="502"}`. No retry storm: 1 retry with jitter. |
| Trivy finds a fixable CRITICAL | Pipeline fails before signing or promotion, and nothing reaches Git. |
| One node lost | 2 remaining etcd members keep quorum; prod stays available via PDB and the topology spread. |
| Jenkins down | Nothing running breaks. Deploys pause, and Argo CD still reconciles the cluster from Git. |

## 6. Verification and evidence (definition of done)

Each P0 item is done only when its check passes and the evidence is saved under `docs/evidence/`.

| # | Item | Verification | Evidence for CV |
|---|---|---|---|
| 1 | Terraform | `terraform apply` from empty, then `plan` shows no changes | resource count, apply duration |
| 2 | Ansible | `site.yml` builds the cluster; a second run gives `changed=0` | playbook recap, cluster build time |
| 3 | HA API | Stop node-1: `kubectl get nodes` still works through the NLB | terminal capture |
| 4 | Argo CD bootstrap | All addon apps Synced and Healthy | screenshot |
| 5 | Index artifact | First Job embeds 7,079 chunks; a second sync skips the build | Job logs, build duration |
| 6 | App readiness | Pod Ready in N seconds (vs rebuild-at-start before) | before/after startup time |
| 7 | Pipeline | Commit → dev running | end-to-end minutes, stage durations |
| 8 | Supply chain | `cosign verify --key awskms://...` passes; Trivy report archived | CRITICAL/HIGH counts before vs after base-image hardening |
| 9 | Promotion | Prod PR opened by the bot, merged, prod synced | PR link |
| 10 | Image size | `docker image ls` before vs after the multi-stage build | MB before/after |
| 11 (P1) | etcd restore | Drill per runbook | RTO |
| 12 (P1) | Kyverno | Unsigned image rejected in prod | admission error |
| 13 (P1) | Upgrade | 1.35 → 1.36 under load | failed requests during upgrade |

## 7. Repo layout (after)

```
src/app/ ...                 app (gunicorn, /healthz, /readyz, /metrics, index CLI)
tests/
Dockerfile  .dockerignore  Jenkinsfile  Makefile
infra/terraform/{bootstrap/, shared/, cluster/}
infra/ansible/{requirements.yml, ansible.cfg, inventory/aws_ec2.yml, roles/, site.yml, upgrade.yml}
deploy/{charts/medical-rag/, envs/{dev,prod}/, argocd/}
docs/{evidence/, runbooks/}
```

The `MLops-Common` submodule is kept for the on-prem history; the new Ansible roles supersede it. The README gains an architecture section and an "Evidence" table.

## 8. Make targets and teardown

| Target | What it does |
|---|---|
| `make shared` | `terraform apply` of the shared stack (kept) |
| `make infra` | `terraform apply` of the cluster stack |
| `make cluster` | Ansible `site.yml` |
| `make tunnel` | SSM port-forward to the internal API NLB and write the kubeconfig |
| `make bootstrap` | Install Argo CD, apply `deploy/argocd/root.yaml` |
| `make up` | infra + cluster + bootstrap |
| `make down` | Delete Argo CD apps (releases PVs), then `terraform destroy` of the cluster stack (`make infra-destroy`). The shared and bootstrap stacks are kept. |
| `make cost` | Print hours up × hourly estimate |

## 9. Schedule (days 1–3)

| Day | Work |
|---|---|
| 1 | Terraform (incl. bootstrap state, KMS, ECR, budgets) the ops workstation, and the Ansible roles. **Cluster up with the HA check.** |
| 2 | Argo CD bootstrap + addons, Helm chart, app changes (gunicorn, probes, metrics, index CLI + Job), dev env serving. |
| 3 | Jenkins + full pipeline (scan, SBOM, KMS sign, dev bump, prod PR), prod env. Capture P0 evidence. P1 items only if time remains. |

## 10. Risks

| Risk | Mitigation |
|---|---|
| HF Inference API quota for 7,079 chunks | Batching + backoff; index built once and reused via S3. Fallback: build the index locally and upload with the same CLI. |
| Ansible over SSM is slow or flaky | Run from the ops workstation in the same region; pin collection versions in `requirements.yml`. |
| Ops workstation holds `AdministratorAccess` | Anyone in the account allowed to `ssm:StartSession` on it gets admin rights. Mitigations: no inbound ports, SSM-only access, IMDSv2, stopped when idle, GitHub access through a fine-grained token limited to this repo, tool downloads verified by checksum. P2: scope the role down. |
| t3.large memory pressure (Jenkins + Prometheus + builds) | Resource requests on all addons; Prometheus retention 24h; at most 1 concurrent Jenkins build. |
| No domain for ingress | Path-based routing on the NLB DNS; TLS is out of scope. |
| **Node instance profile is shared by every pod.** Self-managed clusters have no IRSA or Pod Identity out of the box, so any pod able to reach IMDS could use the KMS sign and S3 permissions. | IMDSv2 hop limit 2 is required for pods today. NetworkPolicy egress deny to `169.254.169.254/32` for all app namespaces, allowed only for external-secrets, ebs-csi and Jenkins agents. Documented as a known limitation; P2 is self-hosted IRSA (pod-identity-webhook + S3-hosted OIDC discovery). |
| Day 1–3 overrun | Cut order: P1 items → prod PR automation (promote manually) → SBOM attestation. Never cut scan + sign + GitOps. |

## 11. Resolved decisions

| Decision | Choice |
|---|---|
| Cluster | kubeadm on EC2 (Anime uses EKS) |
| Repo layout | Everything in this repo |
| CI | Jenkins in-cluster |
| CD | Argo CD |
| Builds | BuildKit rootless (not Kaniko) |
| Signing | Cosign + AWS KMS |
| Secrets | External Secrets + Secrets Manager |
| Ops tooling | EC2 Ubuntu ops workstation via SSM (nothing installed locally) |
| Ansible runtime | Native on the ops workstation |
| Kubernetes version | Start at 1.35, upgrade drill to 1.36 |
