# App guide

A step-by-step guide that puts the chatbot on the cluster: first an AWS identity for its own pods, then
its image and index, then a Helm chart that Argo CD deploys to dev and prod. The architecture and the
decisions behind it are in [`README.md`](README.md) next to this file. Every file is commented, so the
code you copy explains itself. Follow the steps in order: each one ends with a check, and the next step
assumes it passed.

## How this guide works

**Start here when** the [GitOps guide](../gitops/guide.md) is finished. After a rebuild, every Application
is `Synced` and `Healthy`, and the wildcard certificate came back from its backup.

**Where commands run.** No ops tool is installed on your laptop.

| Where | What you do there |
|---|---|
| **Laptop:** editor + Git Bash | Write the files shown in each step, commit, push to GitHub |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager | `git pull`, `make`, `terraform`, `kubectl`, `docker`, `aws`, checks |

The workstation already has everything this guide uses: terraform, ansible, kubectl, helm, yq, jq,
docker with buildx, the AWS CLI, openssl and python3. No step installs a tool. The only exception is a
troubleshooting row, for when the AWS CLI turns out to be too old.

**Every step has the same shape:** goal → files → why → **check before** → commit and push → apply → check.

The GitOps phase lost a day to changes that were only checked after they had taken effect. The rules
below exist because of that.

1. **Check before it takes effect.** Every step names a check that runs before anything changes, and says
   what it must print. For Terraform, that is the plan with an exact count: if the count differs, type
   `no`. For Ansible, `--syntax-check`, plus a task that validates the kubeadm file's structure on the
   node. For code, the test stage of the image. For anything shared, a read of the current value.
2. **One step, one push.** Before each push, `git status --short` must list exactly the files in the
   step's table. Never merge two steps into one push: when something breaks, you need to know which
   change did it.
3. **Stop at a gate.** A step that touches something shared or irreversible has a box that starts with
   **Shared state** or **Irreversible**. Examples: ECR tags, S3 objects, Secrets Manager values, the
   issuer bucket. The box runs a read first and says what it must print. If it prints anything else,
   stop, and do not run the rest of the step.
4. **Nothing is assumed silently.** A mechanism the design depends on is proven on the real cluster
   before the next step relies on it. Step 7 does this for Part 1. Parts 3 and 4 are written only after
   it passes.
5. **Expected output is specific:** a count, a string, an ARN. "It works" is not a check.
6. **Full resource names in kubectl:** `applications.argoproj.io`, not `app`. Rancher also defines an
   `app`.

**Commands are short on purpose.** Each line does one thing, and a value you need twice is saved in a
variable on its own line first. When something fails, you know exactly which part.

**Versions:** Kubernetes 1.36.4, Argo CD v3.5.3, Terraform AWS provider 6.64. Region `ap-southeast-1`.

## Roadmap

| Part | Step | Before this step | Result | How it helps | Still missing after | Check before | Done when |
|---|---|---|---|---|---|---|---|
| [1](guide/1-pod-identity.md) | [1](guide/1-pod-identity.md#step-1--read-only-checks-before-anything-is-created) | Nobody knows whether this account allows a public bucket policy, or whether the bucket name is free | Read-only checks | Rules out the one blocker that would change the design (CloudFront instead of S3) before anything is created | Nothing exists yet: no key, no bucket | – | Account block allows a public policy; bucket name free; no provider yet |
| [1](guide/1-pod-identity.md) | [2](guide/1-pod-identity.md#step-2--the-signing-key) | kubeadm makes a new signing key on every rebuild, so no public key could stay trusted | Stable signing key in Secrets Manager | Gives every future rebuild one key to sign with, and only the workstation can read it | Nowhere public holds the key yet, and the cluster still uses its own key | plan: 1 to add; `VersionIdsToStages` is `null` | Round-trip `MATCH`; node role cannot read it |
| [1](guide/1-pod-identity.md) | [3](guide/1-pod-identity.md#step-3--the-issuer-bucket) | AWS has nowhere to fetch a public key from | Issuer bucket | Gives the issuer a permanent HTTPS URL whose two documents anyone can read, and that Terraform refuses to destroy | The bucket is empty, and the API server does not name it yet | plan: 5 to add, no `replace` | `IsPublic: true`; issuer URL answers `403` (empty) |
| [1](guide/1-pod-identity.md) | [4](guide/1-pod-identity.md#step-4--build-the-cluster-with-the-stable-key-and-the-public-issuer) | The API server signs with a key made at init and names an in-cluster issuer | Cluster rebuilt with the stable key and the S3 issuer | Tokens now carry an issuer AWS can reach, signed with a key that survives rebuilds | AWS cannot verify them yet: the bucket is still empty | `--syntax-check`; `kubeadm config validate` on node 1 | Discovery `issuer` = S3 URL; same `sa.pub` on 3 nodes, equal to step 2's hash; every Application `Synced` and `Healthy`; a second `make cluster` shows `changed=0` |
| [1](guide/1-pod-identity.md) | [5](guide/1-pod-identity.md#step-5--publish-the-issuer-documents) | The bucket is empty, so a token cannot be verified | Issuer documents published | AWS can fetch the key set and check a token's signature | IAM does not trust the issuer yet, and no role exists | laptop: `git status`; workstation: `bash -n`, `make -n`, `make oidc-check` prints `MISSING` twice | `make oidc-check`: two `same` |
| [1](guide/1-pod-identity.md) | [6](guide/1-pod-identity.md#step-6--the-oidc-provider-and-three-roles) | A valid token still grants nothing: IAM trusts no issuer | OIDC provider and three roles | Each ServiceAccount maps to one role with only what it needs | Nothing has shown it works on the real cluster | `make oidc-check`; plan: 7 to add | Trust policy has `aud` and `sub` conditions |
| [1](guide/1-pod-identity.md) | [7](guide/1-pod-identity.md#step-7--prove-it-with-a-pod) | The chain is only designed, not shown to work | Proof on the cluster | Shows the real token gets the right role, and that each boundary holds | The app still has no per-environment secret, and the node role can still use the bucket | – | Role ARN `medical-rag-app-dev`; read allowed; write and other prefixes denied; wrong ServiceAccount refused; IMDS times out while the S3 listing still works |
| [1](guide/1-pod-identity.md) | [8](guide/1-pod-identity.md#step-8--one-secret-per-environment-for-the-app) | Dev and prod would share one set of keys, including the Flask session key | `medical-rag/app-dev` and `medical-rag/app-prod` | Each environment's keys can be replaced without touching the other | Both secrets still hold the same values until you replace them per environment; every pod can still read and write the artifacts bucket through the node role | plan: 2 to add, then 1 to change; both `null` | Three key names in each |
| [1](guide/1-pod-identity.md) | [9](guide/1-pod-identity.md#step-9--take-the-artifacts-bucket-away-from-the-node-role) | The node role still holds the artifacts bucket, so the IRSA roles add rights but remove none | Artifacts bucket removed from the node role | Only pods with a role for it can touch the index, and none can write it through IMDS | The app has no image in ECR and no corpus the Job can read | `grep` finds no `aws_s3_bucket.artifacts` in `cluster/`; plan: 1 to change | A pod on the node role gets `AccessDenied`; the app role still reads |
| [2](guide/2-image-and-index.md) | [10](guide/2-image-and-index.md#step-10--the-index-cli-corpus-from-s3-a-version-command-a-pinned-build) | The Job cannot get the PDF; nothing ties the pinned version to the build; `LATEST` moves on every build | Index CLI: corpus from S3, `version`, pinned build | The cluster's build is checked against the pinned version before any embedding call | The code exists only in Git: no image | laptop: `git status` lists 4 files | Test stage: `26 passed` |
| [2](guide/2-image-and-index.md) | [11](guide/2-image-and-index.md#step-11--make-image-build-test-and-push-one-immutable-image) | ECR is empty | First image, tag = commit | One immutable image per commit, tested before the push | The index version has been measured only locally, not by this image | laptop: `git status`; workstation: `make -n image` | Tag and digest printed; scan `COMPLETE`; a second run stops at the gate |
| [2](guide/2-image-and-index.md) | [12](guide/2-image-and-index.md#step-12--the-index-version-computed-by-that-image) | The version was computed locally, not by the image that will build it | Index version, computed by that image | The value in the values files comes from the exact code that builds it | The PDF is not where the Job reads it | – | `cc759ae1a093` |
| [2](guide/2-image-and-index.md) | [13](guide/2-image-and-index.md#step-13--the-corpus-in-s3) | The PDF exists only in Git | Corpus in S3 | The Job can read the exact bytes Git holds | Nothing deploys the app: no DNS name, no chart | `head-object`: 404 | S3 checksum equals the file's |
| 3 (plan) | 14 | The app has no name: the public NLB answers only its DNS name | DNS: `dev.` and `app.recruitai.io.vn` → public NLB | Each environment gets its own host, so no URL prefix and no shared cookie | No chart: nothing builds the index or serves the app, so both names get nginx's 404 | `make infra` plan: 2 to add | `dig` returns the NLB's addresses; `curl` gets nginx's `404` |
| 3 (plan) | 15 | No index exists in S3, and nothing in the cluster can build one | Chart v0, dev: ServiceAccounts, ExternalSecret (wave 0), index build Job as a Sync hook (wave 1), NetworkPolicy (DNS + 443, no IMDS), `medical-rag-dev` Application | Builds the index in the cluster with its own role and IMDS closed, and proves the Sync hook runs after the Secret exists | No pod serves the app | `helm lint`; `helm template` → `kubectl apply --dry-run=server` | The Secret exists before the Job's pod; Job log `Built index cc759ae1a093 … 7079 chunks` (criterion #6, first half) |
| 3 (plan) | 16 | The index is built but nobody serves it | Deployment, Service, init container pulling the pinned index, probes | A pod downloads the pinned index with its own role, with IMDS closed | The Job has not been shown to skip; only a port-forward reaches the pod | same as step 15 | Pod `Ready`, time recorded (criterion #7); IMDS times out from the app pod |
| 3 (plan) | 17 | Not shown: does a second sync embed again? | A values change forces a second sync | Proves a sync costs nothing when the version exists | Only a port-forward reaches the pod | same | Job log `already exists, skipping` (criterion #6, second half) |
| 3 (plan) | 18 | Only a port-forward reaches the app | Ingress `dev.recruitai.io.vn` | A user can open the app by name | Prometheus does not scrape the app | same, the server dry-run includes ingress-nginx's admission webhook | `curl` returns the page; a question gets an answer |
| 3 (plan) | 19 | App metrics exist but nothing collects them | ServiceMonitor | Request, retrieval and LLM latency reach Prometheus | Prod does not exist | same | Prometheus `up{namespace="medical-rag-dev"} == 1` |
| 4 (plan) | 20 | Only dev runs, with one replica | Prod: `medical-rag-prod` Application, `app-prod` ExternalSecret, host `app.recruitai.io.vn`, 2 replicas spread across nodes, PDB | Survives a node loss and a drain | Requests and limits are guesses | same, with prod values | Pods on 2 nodes; PDB allows 1 disruption; the Job skips; `curl` on `app.recruitai.io.vn` returns the page |
| 4 (plan) | 21 | Requests and limits are guesses | Measurements, then requests and limits | Resources are set from measured numbers | Jenkins: images are still built by hand | same, with both values files | Job peak memory from Prometheus; app `kubectl top`; values updated |

**Parts:** [1. An AWS identity for the app's own pods](guide/1-pod-identity.md) ·
[2. The image, the corpus and the index version](guide/2-image-and-index.md) ·
[Troubleshooting](guide/troubleshooting.md)

**Parts 3 and 4 are a plan, not instructions yet.** They are written once step 7 has proven Part 1 on the
cluster, because every one of their pods depends on it. The rows above say what each step will prove.

---

## The loop for every step

1. **Laptop:** create or edit the files, then in Git Bash:
   ```bash
   git status --short        # exactly the files in the step's table, nothing else
   git add <those files>
   git commit -m "<the message given in the step>"
   git push
   ```
2. **Workstation:** open Session Manager, then:
   ```bash
   sudo su - ubuntu
   tmux new -As app                       # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot
   git pull
   ```
3. **Workstation:** run the step's checks, in the order the step gives them.

**tmux windows.** Window 0 for everything. Window 1 for `make tunnel`, open whenever a step uses kubectl:
steps 4 (including `make down`), 5, 6, 7 and 9. If window 1 closes, kubectl answers `connection refused`:
open it again and run `make tunnel`. After a rebuild the old tunnel points at a node that no longer
exists: `Ctrl-C` in window 1, then `make tunnel` again.

**Record as you go.** Each step ends with **Record**. Copy those outputs from the workstation into
`docs/evidence/app.md` **on the laptop**, while they are on the screen. The GitOps phase had to
reconstruct evidence afterwards, and could not recover everything. Commit that file on its own before you
start the next step (`git add docs/evidence/app.md`, message `Evidence: app step N`), so each step's
`git status --short` again lists only that step's files. Never edit it on the workstation: `make image`
refuses a working tree that differs from Git.

---

Start with [Part 1: An AWS identity for the app's own pods](guide/1-pod-identity.md).
