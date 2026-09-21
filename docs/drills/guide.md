# Drills guide

Three controls, each proven by making the bad thing happen: etcd snapshots and a restore, image-signature
admission and a refusal, a rolling upgrade under load. Plus the rebuild that has to come first, because the
cluster was torn down.

Concepts are in [`concepts.md`](concepts.md); measurements go in
[`../evidence/drills.md`](../evidence/drills.md). This closes design criteria
[#12, #13 and #14](../selfmanaged-k8s-ops-design.md).

## How this guide works

**Where commands run.**

| Label | Machine | Notes |
|---|---|---|
| **Laptop** | Windows | `git` only. No `grep`, no `sed`, no backslash line continuations |
| **Workstation** | EC2 Ubuntu, reached by SSM | Every new shell opens in `/home/ubuntu`, so every command carries its own `cd ~/Medical-RAG-Chatbot &&` |

tmux **window 0** is for work, **window 1** holds `make tunnel`, and step 18 needs a **window 2**.

**Three commands stop and wait for input**, and two of them look alike: `make shared`, `make infra` and
`make down` all end in Terraform's `yes` prompt. And if `terraform.tfvars` is missing, `make shared` stops
first on `var.budget_email  Enter a value:` — read the prompt before typing, because a wrong value there
silently redirects the budget alerts.

**Six rules.**

1. Run the check before moving on. A step is not done because the command exited 0; it is done when the
   check's stated output appears.
2. When output differs from what a step expects, stop and record the real output before changing anything.
   Then find the cause. Do not work around it.
3. Every measurement goes into `../evidence/drills.md` as it is taken, not afterwards from memory.
4. Nothing here is applied to a cluster from the laptop. The laptop edits and pushes; the workstation runs.
5. On the **workstation**, after each pull: `grep -n '<[A-Za-z][A-Za-z0-9_ -]*>' FILE` on any file you filled
   in must print nothing. The space in the character class is load-bearing. The laptop has no `grep`.
6. This guide hands its file changes over in prose and tables rather than in fenced blocks, so
   `check-blocks.py` has almost nothing to check here — it skips `bash` fences by design. The one exception is
   step 13's `imageReferences` snippet:
   `python3 docs/jenkins/check-blocks.py docs/drills/guide.md 13 deploy/argocd/manifests/kyverno-policies/verify-images.yaml`.
   Everywhere else, rule 5 and the step's own Check are what catch a missing paste.

**Versions.** Kubernetes 1.36.4, etcd **3.6.8**, Rancher chart 2.15.1 (`kubeVersion: < 1.37.0-0`). The Kyverno
chart version is chosen and recorded in step 13.

---

## Roadmap

| Part | Step | Before this step | Result | How it helps | Still missing after | Check before | Done when |
|---|---|---|---|---|---|---|---|
| [0](#part-0--bring-the-cluster-back) | [1](#step-1--check-the-workstation) | A teardown left stale state on the workstation | `terraform.tfvars` present, no stale tunnel | `make shared` cannot stop on a hidden prompt | The stacks | — | `tfvars` exists, no session running |
| 0 | [2](#step-2--move-the-backup-bucket-out-of-the-cluster-stack) | The backup bucket dies with every teardown | The bucket defined in `shared` | A backup that outlives what it backs up | The bucket itself | The bucket does not exist **right now** | Five files edited and pushed |
| 0 | [3](#step-3--make-shared) | Two pending changes in `shared` | ECR immutable, bucket created | Both land before anything reads them | The cluster | `aws s3 ls` shows no `etcd-backups` | **1 to change, 5 to add** |
| 0 | [4](#step-4--the-cluster-itself) | No VPC, no nodes | A 3-node cluster, node role naming the new bucket | Everything below needs a cluster | Argo CD | Step 3 applied | `PLAY RECAP` `failed=0` |
| 0 | [5](#step-5--argo-cd-and-everything-it-installs) | An empty cluster | 14 Applications | The platform is back without being typed | The post-teardown repairs | Tunnel open in window 1 | `root` `Healthy` |
| 0 | [6](#step-6--the-issuer-check) | Nothing proves the signing key survived | Two `same` lines | Every IRSA role depends on it | The laptop repairs | Step 5 done | Two `same` lines |
| 0 | [7](#step-7--the-three-things-a-rebuild-breaks) | VPN points at a dead address | A usable VPN, the new passwords | The internal UIs open again | Any drill | Step 6 done | WireGuard handshakes |
| [1](#part-1--etcd-snapshots-and-the-restore-drill) | [8](#step-8--the-snapshot-cronjob) | Nothing writes a snapshot | A CronJob every 6 hours | etcd state leaves the cluster | Proof any of it works | Step 3 applied | The Application is `Healthy` |
| 1 | [9](#step-9--wait-for-a-real-snapshot) | The CronJob has never run | One verified snapshot in S3 | `snapshot status` is what makes it a backup | The restore | Step 8 done | A hash and a revision |
| 1 | [10](#step-10--the-restore-drill) | Nobody has restored one | A deleted namespace brought back | This is criterion #12 | Nothing for #12 | A snapshot exists | **RTO** recorded |
| 1 | [11](#step-11--record-what-the-drill-cost) | The numbers are in a terminal | RPO and RTO written down | The claim becomes a sentence with numbers | — | Step 10 done | Evidence has both |
| [2](#part-2--kyverno-and-the-admission-drill) | [12](#step-12--export-the-cosign-public-key) | The public key exists only inside KMS | A PEM in Git | Kyverno verifies with no AWS call | The controller | Step 7 done | `diff` says the keys match |
| 2 | [13](#step-13--install-kyverno-in-audit-mode) | Nothing reads a signature | Kyverno running, policy in `Audit` | Nothing blocked while the pattern is proven | Enforcement | Step 12 pushed | A `pass` row for a real image |
| 2 | [14](#step-14--switch-prod-to-enforce-and-try-an-unsigned-image) | An unsigned image reaches prod unchallenged | prod refuses it | This is criterion #13 | Nothing for #13 | `cosign verify` passes on both digests | The **admission error** captured |
| [3](#part-3--the-upgrade-drill) | [15](#step-15--find-out-whether-there-is-anything-to-upgrade) | Nobody knows if 1.36 has a newer patch | A target, or the knowledge there is none | Stops you writing a playbook with nothing to run | The gate | Step 7 done | `apt-cache madison` read |
| 3 | [16](#step-16--the-compatibility-gate) | Rancher's constraint is a memory | `kubeVersion` read from the chart | §4.2.1 becomes a check | The playbook | Step 15 done | The constraint recorded |
| 3 | [17](#step-17--write-upgradeyml) | No playbook exists | `infra/ansible/upgrade.yml` | One node at a time, with health gates | The drill | Step 16 passed | `--syntax-check` and `--list-tasks` |
| 3 | [18](#step-18--the-upgrade-drill) | The playbook has never run under load | Three nodes upgraded, failures counted | This is most of criterion #14 | #14's *minor* path | Kyverno has 2 replicas | **Failed-request count** |

**The loop for every step.** Edit on the laptop, commit, push. On the workstation:
`cd ~/Medical-RAG-Chatbot && git pull`, run the step's commands, run its check, record. Then the next step.

---

# Part 0 — Bring the cluster back

The cluster stack was destroyed. `shared` and `bootstrap` were not: ECR, the KMS signing key, the artifacts
bucket, Secrets Manager, the OIDC issuer, the DNS zone, the state bucket and this workstation are all still
there. **The Terraform `bootstrap` stack is never destroyed** — the thing called `make bootstrap` installs
Argo CD, which is a different job with an unfortunate name.

## Step 1 — Check the workstation

**Problem now.** Two leftovers from the teardown fail later in ways that look like something else.

**Why it matters.** `infra/terraform/shared/terraform.tfvars` is gitignored and `budget_email` has no default,
so `make shared` stops on `var.budget_email  Enter a value:` — a prompt easily mistaken for the `yes` prompt
you are expecting. And a stale `make tunnel` does not report an error; it simply never answers, which reads
like a broken cluster.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && git pull
cd ~/Medical-RAG-Chatbot && test -f infra/terraform/shared/terraform.tfvars && echo "tfvars ok" || echo "MISSING"
pgrep -af "ssm start-session" || echo "no tunnel running"
```

If it is missing, copy `infra/terraform/shared/terraform.tfvars.example` and type the budget email. If a
session is running, kill it — it targets a dead instance id.

**Check.** `tfvars ok` and `no tunnel running`.

## Step 2 — Move the backup bucket out of the cluster stack

**Problem now.** `medical-rag-etcd-backups-<account>` is defined in `infra/terraform/cluster/storage.tf` with
`force_destroy = true`. Every `make down` deletes it, and every snapshot in it.

**Why it matters.** A backup destroyed together with the thing it backs up is not a backup. The GitOps phase
recorded this as a known limit and said what to do: *"Move it to the shared stack before relying on backups
(day-2 phase)."* This is that phase.

**Why this step is here and not in Part 1.** The cluster stack is destroyed *right now*, so the bucket exists
neither on AWS nor in any state file — moving it is a **create**, not a migration. Once step 4 runs
`make infra`, the cluster stack owns that bucket name again and a later `make shared` fails with
`BucketAlreadyOwnedByYou`. Do it before the cluster comes back.

| File | Change |
|---|---|
| `infra/terraform/cluster/storage.tf` | Remove `etcd-backups` from `local.buckets`, leaving only `ssm-transfer` |
| `infra/terraform/shared/storage.tf` | Add the bucket, public-access block, encryption, 14-day lifecycle and TLS-only policy — **without** `force_destroy` |
| `infra/terraform/shared/outputs.tf` | Output its name and ARN |
| `infra/terraform/cluster/main.tf` | `data "aws_s3_bucket" "etcd_backups"`, by name |
| `infra/terraform/cluster/iam.tf` | Add that ARN to the `S3ListBuckets` and `S3ReadWriteObjects` statements |

The last two are the part that is easy to miss. The node policy grants S3 with
`resources = [for b in aws_s3_bucket.this : b.arn]` — a loop over the cluster's own buckets. Take
`etcd-backups` out of that map and **the node loses write access silently**; the CronJob then fails with
`AccessDenied` six steps later.

`infra/terraform/cluster/outputs.tf` iterates the same map. It needs no edit — its `buckets` output simply
loses one key — but know it is there.

**Laptop.** Make the five edits, commit, push.

**Check**, before moving on — this is the premise of the step:
```bash
aws s3 ls | grep etcd-backups || echo "not there — good"
```

> If the bucket **does** exist, step 4 has already run. Then the order reverses: `make infra` first (it
> destroys the bucket — there are no snapshots in it yet and `force_destroy` lets it go), then `make shared`,
> then `make infra` again for the data lookup.

## Step 3 — `make shared`

**Problem now.** Two changes are waiting in `shared`: the bucket you just added, and commit `ddb3b28`, which
set `medical-rag-ci` to `IMMUTABLE` in Git and was never applied — on AWS the repository is still `MUTABLE`.

**Why it matters.** `shared` must land before `infra`: the cluster stack has `data "aws_ecr_repository" "ci"`
and now also `data "aws_s3_bucket" "etcd_backups"`, and a data source fails if the thing is missing.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && git pull
cd ~/Medical-RAG-Chatbot && make shared
```

Read the plan before typing `yes`.

**Check.** **1 to change** in place — `image_tag_mutability: "MUTABLE" -> "IMMUTABLE"` — and **5 to add**: the
bucket plus its public-access block, encryption, lifecycle and policy. A second in-place change to
`aws_ecr_lifecycle_policy.ci` is also fine.

> **Stop gate.** If the plan proposes to **destroy and recreate** the ECR repository, do not type `yes`. That
> takes the pipeline's tools image with it. Send the plan output and stop.

**Record** the plan summary line.

## Step 4 — The cluster itself

**Problem now.** There is no VPC, no node, no load balancer, and no kubeconfig pointing anywhere real.

**Why it matters.** `make cluster` is the only thing that rewrites `~/.kube/config`, and the only thing that
seeds `/etc/kubernetes/pki/sa.key` from `medical-rag/sa-signer` — which is why step 6 can pass.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && time make infra
cd ~/Medical-RAG-Chatbot && make ping
cd ~/Medical-RAG-Chatbot && time make cluster
```

`make ping` goes **between** them, as `docs/runbook.md` §4 has it: a node SSM cannot reach fails here in ten
seconds rather than six minutes into the playbook. `make ansible-deps` is not repeated — the workstation
survived the teardown and the collection is still installed.

**Check.** `make infra` prints `Apply complete!`; `make ping` answers `SUCCESS` three times; `make cluster`
ends in a `PLAY RECAP` with `failed=0 unreachable=0` for all three nodes.

Then confirm the node really has the grant — read it from AWS, not from the plan:
```bash
aws iam get-role-policy --role-name medical-rag-nodes --policy-name medical-rag-nodes \
  --query 'PolicyDocument.Statement[?Sid==`S3ReadWriteObjects`].Resource'
```
Expected: both the `ssm-transfer` and the `etcd-backups` ARNs, each with `/*`.

> An `aws s3 ls` from this workstation proves nothing about the node: the workstation's role is
> `AdministratorAccess`. The only real proof the node can write is step 9's first CronJob run.

**Record** both `time` figures.

## Step 5 — Argo CD, and everything it installs

**Problem now.** The cluster is empty.

**Why it matters.** Nothing below is typed. `root` installs 13 Applications from `deploy/argocd/apps/` in
waves; Jenkins at waves 3 and 4 comes back the same way the app does.

**Workstation, window 1.**
```bash
cd ~/Medical-RAG-Chatbot && make tunnel
```

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && time make bootstrap
cd ~/Medical-RAG-Chatbot && time kubectl -n argocd wait application/root --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m
cd ~/Medical-RAG-Chatbot && make apps
```

**Check.** `application.argoproj.io/root condition met`, then **14 Applications** — the 13 files plus `root` —
every one `Synced` and `Healthy`. (`kubectl` also prints a header, so the terminal shows 15 lines.)

The wait is not optional. `make bootstrap` applies `root.yaml` and returns immediately; `make apps` seconds
later shows a near-empty table that reads like "nothing is red".

**Record** both `time` figures and the `make apps` table.

## Step 6 — The issuer check

**Problem now.** Nothing yet shows the rebuilt API server signs service-account tokens with the same key the
OIDC issuer publishes.

**Why it matters.** Every IRSA role here — the app's, the index builder's, the Jenkins build pods' — trusts
that issuer. If the key changed, all of them silently stop working.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && make oidc-check
```

**Check.** Two `same` lines.

> **Stop gate.** `DIFFERENT`, `MISSING`, or `The API server's issuer is …, expected …` all mean tokens would
> be refused. **Do not run `make oidc-publish` over it** — app guide step 4 handles this. Stop and record.

## Step 7 — The three things a rebuild breaks

**Problem now.** Three things are different after a teardown and none announces itself.

**Why it matters.** The WireGuard gateway's Elastic IP was in the destroyed stack, so it came back on a **new
public address** and `vpn.recruitai.io.vn` points elsewhere. A client that was up keeps the stale endpoint and
never handshakes — no error, just silence. And two admin passwords are generated inside the cluster.

**Laptop.** Deactivate the WireGuard tunnel, then activate it again. The keys are unchanged — they come from
Secrets Manager — only the endpoint moved.

**Workstation, window 0.**
```bash
kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n ingress-nginx get certificate wildcard-recruitai
kubectl -n ingress-nginx get certificaterequests
```

**Check.** Two 32-character passwords; the certificate `READY True`; and **`No resources found`** for the
requests — cert-manager *restored* the wildcard rather than ordering a new one.

> A `CertificateRequest` here means the restore lost its race and you have spent one of five Let's Encrypt
> issuances per seven days. Record it and do not rebuild again today.

**Record** the certificate's `notAfter`, and whether any request appeared.

---

# Part 1 — etcd snapshots and the restore drill

## Step 8 — The snapshot CronJob

**Problem now.** The bucket exists and nothing writes to it.

**Why it matters.** etcd holds every object in the cluster
([concepts §1](concepts.md#1-etcd-and-why-a-snapshot-is-not-a-volume-backup)). Six hours between snapshots is
the RPO you are choosing.

| File | Change |
|---|---|
| `deploy/argocd/manifests/etcd-backup/namespace.yaml` | Namespace `etcd-backup` |
| `deploy/argocd/manifests/etcd-backup/cronjob.yaml` | The CronJob |
| `deploy/argocd/apps/etcd-backup.yaml` | Application, sync-wave `0`, `source` (singular), `CreateNamespace=true`, no finalizer |

The CronJob's shape, and why each part is there:

- `schedule: "0 */6 * * *"` — the six hours from the design.
- `hostNetwork: true`, endpoint `https://127.0.0.1:2379` — it talks to the member on its own node.
- `nodeSelector: node-role.kubernetes.io/control-plane: ""` plus the matching toleration. Every node here is a
  control plane, but the selector states the dependency.
- `hostPath /etc/kubernetes/pki/etcd`, read-only — the CA and client certificates.
- **Two containers, not one.** An initContainer on the **etcd image** runs `etcdctl snapshot save` and then
  `etcdutl snapshot status` into a shared `emptyDir`; the main container uploads it. The etcd image ships
  `etcd`, `etcdctl` and `etcdutl` and **no AWS CLI**. For the upload container use
  `242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag-ci:<tag>@sha256:<digest>` — the pipeline's
  tools image already holds the AWS CLI, it is already in ECR, and the node role can already pull it. Pin it
  by digest the way `Jenkinsfile` does.
- `status` before the upload is the step that turns an upload into a backup; a truncated file uploads
  perfectly happily ([concepts §2](concepts.md#2-snapshot-save-snapshot-status-snapshot-restore)).
- Credentials: none configured. The upload reaches S3 with the **node's instance role** through IMDS, which
  step 2 granted. This namespace has no NetworkPolicy, so IMDS is reachable.

> **The trade-off, stated plainly.** The node role also holds eight Secrets Manager secrets and the ACME TXT
> record, so this CronJob has more than it needs. A dedicated IRSA role through the existing issuer would be
> tighter. This is the simpler path and it goes in the limits list, not out of sight.

**Laptop.** Write the three files, commit, push.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && git pull
kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd get application etcd-backup
kubectl -n etcd-backup get cronjob
```

**Check.** The Application is `Synced` and `Healthy`, and the CronJob shows `SUSPEND False` with its schedule.
**This proves the object exists and nothing else** — the image, the certificate paths and the S3 grant are all
untested until step 9's first run. Argo CD calls a CronJob Healthy the moment it exists.

## Step 9 — Wait for a real snapshot

**Problem now.** The CronJob has never fired.

**Why it matters.** A schedule is not a snapshot, and every failure mode here — a wrong certificate path, a
missing S3 permission, an image without `etcdutl` — looks identical until the first run.

**This step.** Wait for the next six-hour boundary. **Do not trigger it by hand**: a manual
`create job --from=cronjob` skips exactly the scheduling path you are testing.

**Workstation, window 0.**
```bash
kubectl -n etcd-backup get jobs
kubectl -n etcd-backup logs job/<the job name> --all-containers
aws s3api head-object --bucket medical-rag-etcd-backups-242834061265 --key <the newest key> --query ContentLength
```

**Check.** The job `COMPLETIONS 1/1`; the object's length is megabytes, not bytes; and the **initContainer's
log carries the `etcdutl snapshot status` table** — a hash, a revision, a key count and a size. A revision of
0 or a key count of 0 means the snapshot is empty and uploaded happily anyway, which is the exact failure
`status` exists to catch.

Reading the table out of the log is deliberate: the snapshot file lives on the node, `etcdutl` lives in the
etcd image, and the workstation has neither.

**Record** the job's duration, the object's size, and the revision and key count.

## Step 10 — The restore drill

**Problem now.** Nobody has restored one of these, and a restore procedure never run is a document, not a
capability.

**Why it matters.** This is criterion #12. The evidence it asks for is a number: **RTO**.

Read [concepts §2](concepts.md#2-snapshot-save-snapshot-status-snapshot-restore) first.

**Create something to lose.**
```bash
kubectl create namespace restore-drill
kubectl -n restore-drill create configmap canary --from-literal=written-at="$(date -u +%FT%TZ)"
date -u +%FT%TZ
```

Wait for the next scheduled snapshot — or record that you are restoring to a point *before* the namespace
existed. Both are valid drills but they prove different things, and the evidence must say which.

Then delete it and start the clock:
```bash
kubectl delete namespace restore-drill
date -u +%FT%TZ            # t1: the restore begins
```

**The restore is six phases, each finished on all three nodes before the next begins.** Doing all of them on
one node while the others still serve is the split-brain concepts §2 warns about: a restored single member
rejoining a live two-member quorum is either refused or silently loses data.

`make kubectl` only reaches node 1, so this goes through Ansible, which addresses all three at once:

```bash
A="cd ~/Medical-RAG-Chatbot/infra/ansible && ansible nodes -b -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=242834061265"
```

- **Phase 0 — put the snapshot on every node.** The nodes have no AWS CLI, so copy it from the workstation:
  `$A -m copy -a "src=/tmp/snap.db dest=/tmp/snap.db mode=0600"`
- **Phase 1 — stop the API server and etcd everywhere:**
  `$A -m shell -a 'mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/etcd.yaml /root/'`
  then wait until `crictl ps` shows neither on any node.
- **Phase 2 — move the old data aside everywhere:** `$A -m shell -a 'mv /var/lib/etcd /var/lib/etcd.old'`
- **Phase 3 — restore, per node, with that node's own values.** `--name` and `--initial-advertise-peer-urls`
  differ per node; `--initial-cluster`, `--initial-cluster-token` and `--data-dir` are the **same on all
  three**. `--data-dir` is not optional: without it `etcdutl` writes `./<name>.etcd` and the kubelet then
  starts etcd on an empty directory.
- **Phase 4 — put the manifests back everywhere:**
  `$A -m shell -a 'mv /root/kube-apiserver.yaml /root/etcd.yaml /etc/kubernetes/manifests/'`
- **Phase 5 — re-open `make tunnel`** in window 1. The API server restarted underneath the old port-forward.

**Check.**
```bash
cd ~/Medical-RAG-Chatbot && make kubectl CMD="get nodes"
kubectl -n restore-drill get configmap canary -o yaml
cd ~/Medical-RAG-Chatbot && make apps
date -u +%FT%TZ            # t2: every Application Healthy
```

Expected: three nodes `Ready`; the ConfigMap back with the timestamp it was written with; every Application
`Healthy`.

**RTO = t2 − t1**, measured to *every Application Healthy*, not to *etcd started*: a cluster whose etcd is up
but whose workloads have not reconciled is not recovered.

**Record** t1, t2, the RTO, and anything that did not come back.

## Step 11 — Record what the drill cost

Write into `../evidence/drills.md`: the RPO (six hours, by schedule), the RTO (measured), what was lost
between the snapshot and the deletion, and every command that did not behave as this guide says.

**Check.** Criterion #12's row names a number.

---

# Part 2 — Kyverno and the admission drill

## Step 12 — Export the cosign public key

**Problem now.** The pipeline has signed every image built on `main` since the Jenkins phase, and the public
half of the key has never left KMS.

**Why it matters.** Kyverno needs it. The alternative — Kyverno calling `kms:GetPublicKey` itself — needs an
IAM grant that **no identity in this cluster has**: the Jenkins phase removed KMS from the node role entirely,
and only `medical-rag-ci` holds it, trusted by one ServiceAccount in `jenkins-agents`.

A public key is not a secret. Git is the right place for it.

**Workstation, window 0.** `cosign` is already installed here.
```bash
cosign public-key --key awskms:///alias/medical-rag-cosign
```

**Laptop.** Save it as `deploy/argocd/manifests/kyverno-policies/cosign.pub`, commit, push.

**Check**, on the workstation after the pull:
```bash
cd ~/Medical-RAG-Chatbot && diff <(cosign public-key --key awskms:///alias/medical-rag-cosign) deploy/argocd/manifests/kyverno-policies/cosign.pub && echo "same key"
openssl pkey -pubin -in deploy/argocd/manifests/kyverno-policies/cosign.pub -text -noout | grep -E 'Public-Key|NIST CURVE'
```

Expected: `same key`, then `Public-Key: (256 bit)` and `NIST CURVE: P-256`, matching the key's
`ECC_NIST_P256` spec. The `diff` is the part that matters — a P-256 key from anywhere would pass the second
command alone.

## Step 13 — Install Kyverno, in Audit mode

**Problem now.** Nothing reads a signature.

**Why it matters.** This is the gap the Jenkins README names in its own limits table, and it is wider than it
looks: the skip guard ends any build whose commit touched only `deploy/`, so a digest hand-edited into prod's
values is never built, never scanned, never signed — and nothing downstream objects.

| File | Change |
|---|---|
| `deploy/argocd/apps/kyverno.yaml` | Chart Application: `repoURL: https://kyverno.github.io/kyverno`, `chart: kyverno`, **`targetRevision:` the version you choose below**, sync-wave `-2`, `ServerSideApply=true`, no finalizer |
| `deploy/argocd/values/kyverno.yaml` | Values, including the replica counts below |
| `deploy/argocd/manifests/kyverno-policies/verify-images.yaml` | `ClusterPolicy`, `validationFailureAction: Audit`, `background: false` |
| `deploy/argocd/manifests/kyverno-policies/cosign.pub` | From step 12 |
| `deploy/argocd/apps/kyverno-policies.yaml` | Manifests Application, sync-wave `0` |

Pick and pin the chart version first — every other chart Application here pins one:
```bash
helm repo add kyverno https://kyverno.github.io/kyverno --force-update
helm search repo kyverno/kyverno --versions | head -3
```
Write the version you choose into `apps/kyverno.yaml` **and** into the evidence.

Five decisions worth stating:

- **Wave -2 for the controller**, with the other CRD-shipping operators, so it is admitting before the app
  syncs at waves 1 and 2. The cost: from now on, if Kyverno never reports `Healthy` and `Synced`, the health
  gate stops **everything from wave -1 onward** — the certificate restore, monitoring, Rancher, the app,
  Jenkins. Four more deployments on three nodes already running Jenkins, Prometheus and Rancher is a real
  scheduling risk. Record the added rebuild time.
- **Wave 0 for the policy**, after `platform-secrets` and before the app. Separating them also means a broken
  policy can be removed without uninstalling the controller.
- **`ServerSideApply=true`**, because Kyverno's CRDs are larger than a client-side apply allows — the same
  reason `kube-prometheus-stack` sets it.
- **`admissionController.replicas: 2`, everything else one.** A single admission-controller replica with the
  chart's default `minAvailable: 1` PodDisruptionBudget makes `kubectl drain` block forever — the very row in
  this guide's troubleshooting table — and step 18 drains all three nodes. Worse, Kyverno's resource webhooks
  are `failurePolicy: Fail` excluding only `kube-system`, so while that one pod is gone **no Pod can be
  created anywhere else in the cluster**, including prod's replacement replica. Two replicas with
  anti-affinity costs about 200 Mi and removes both problems.
- **`Audit` first, in both environments.** A `verifyImages` rule in `Enforce` that is subtly wrong does not
  fail loudly; it blocks the app on **every future rebuild**, including the one you would do to fix it.

The image pattern needs care:

```yaml
imageReferences:
  - "*.dkr.ecr.*.amazonaws.com/medical-rag:*"
```

Not `medical-rag*`. That glob also matches **`medical-rag-ci`**, the pipeline's own tools image, which the
pipeline does **not** sign — an `Enforce` policy written that way would stop every Jenkins build pod from
starting. Design §4.6 writes the pattern the loose way; that is a bug in the design, and correcting it is part
of closing this phase.

The pattern covers all four places the image appears: the app container, the `index-pull` initContainer, and
the index-build Job — Kyverno checks `initContainers`, `containers` and `ephemeralContainers`.

The attestor is the static key with the transparency log **off**: there is no Rekor entry to find, because the
pipeline signs with a signing config that names no services.

**Laptop.** Write the five files, commit, push.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && git pull
kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite
kubectl -n kyverno get deploy,pdb
kubectl get clusterpolicy
kubectl -n medical-rag-dev delete pod -l app.kubernetes.io/name=medical-rag,app.kubernetes.io/component=web --wait=false
kubectl -n medical-rag-prod delete pod -l app.kubernetes.io/name=medical-rag,app.kubernetes.io/component=web --wait=false
kubectl get policyreport -A
```

Deleting a prod pod is safe: two replicas with a `minAvailable: 1` budget. Both deletions are needed because
`verifyImages` rules are **not** evaluated in background scans — a row appears only after an admission.

**Check.** Two Ready admission-controller replicas and a PDB showing `ALLOWED DISRUPTIONS 1`; the
`ClusterPolicy` `READY True`; both pods restart and **start**; and the policy report shows a `pass` for each
real image.

> A report with **zero** rows is the dangerous outcome: the pattern matches nothing, and a policy that matches
> nothing also denies nothing.
>
> A report showing `fail` on a real image is not necessarily a wrong pattern. Check whether Kyverno is looking
> for a `sha256-<digest>.sig` tag while cosign v3 wrote an untagged OCI referrer —
> `aws ecr list-images --repository-name medical-rag` shows which exists. Kyverno also has to *pull* the
> signature from a private repository; it works here because the pod picks up the node role through IMDS.

**Record** the chart version and the policy report rows for dev and prod.

## Step 14 — Switch prod to Enforce, and try an unsigned image

**Problem now.** Audit reports; it does not refuse.

**Why it matters.** This is criterion #13, and the evidence is the **admission error**.

**Prove the good path first.** On the workstation, for the digest prod actually runs:
```bash
cd ~/Medical-RAG-Chatbot && cosign verify --key awskms:///alias/medical-rag-cosign --insecure-ignore-tlog \
  242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag@sha256:$(yq '.image.tag' deploy/envs/prod/values.yaml | tr -d '"' | cut -d: -f2)
```
Expected: `The signatures were verified against the specified public key`. **If this fails, do not set
`Enforce`** — you would block prod on the next sync.

**Laptop.** In `verify-images.yaml`, change the prod rule to `validationFailureAction: Enforce`. Leave dev on
`Audit`. Commit, push.

**Workstation, window 0.** Then try an image the pipeline never signed — the app-phase image `cosign verify`
already refused is the honest choice. It needs a `securityContext`, because `medical-rag-prod` enforces Pod
Security `restricted` and a bare pod would be refused by PSA before Kyverno ever sees it:

```bash
kubectl -n medical-rag-prod run unsigned-test --restart=Never \
  --image=242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:1eaa43bf3512 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"unsigned-test","image":"242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:1eaa43bf3512","command":["sleep","10"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  --command -- sleep 10
```

**Check.** The command fails and the message **names a Kyverno webhook** (`…kyverno.svc`) with a reason of the
shape `failed to verify image … no matching signatures`. Copy it verbatim; that string is the evidence.

> If the message says `violates PodSecurity "restricted"` instead, Pod Security refused it first and this
> proves nothing about Kyverno. Fix the pod spec and run it again.
>
> If the pod is **admitted**, the policy is not matching. Check the pattern against the rendered reference
> before changing anything else.

Then confirm the good path still works: delete a prod pod and watch the Deployment replace it.

**The escape hatch, written down before you need it.** From this commit on, every rebuild carries an `Enforce`
policy at wave 0 ahead of the app at waves 1 and 2 **and Jenkins at waves 3 and 4**. If prod's image ever
stops verifying, the rebuild stalls at wave 2 and Jenkins never comes back — so there is no pipeline to build
the fix with. And `kyverno-policies` has `selfHeal: true`, so editing the `ClusterPolicy` by hand does not
hold: Argo CD restores it within minutes. Two ways out, in order:

1. `kubectl -n argocd patch application kyverno-policies --type merge --patch '{"spec":{"syncPolicy":{"automated":null}}}'`
   then `kubectl delete clusterpolicy verify-images`. Let the rebuild finish, then diagnose.
2. Revert the `Enforce` line in Git and push. Slower, but it survives the next `selfHeal`.

**Record** the admission error verbatim, and that a signed image still deploys.

---

# Part 3 — The upgrade drill

## Step 15 — Find out whether there is anything to upgrade

**Problem now.** The cluster is pinned to 1.36.4 and nobody has checked whether 1.36 has a newer patch.

**Why it matters.** If it does not, there is nothing to upgrade — a result to have **before** writing a
playbook.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && make kubectl CMD="get nodes -o wide"
cd ~/Medical-RAG-Chatbot/infra/ansible && ansible first_node -b -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=242834061265 -m shell -a 'apt-get update -qq && apt-cache madison kubeadm | head'
```

The three `-e` variables are not optional: the SSM connection settings template `project`, `aws_region` and
`aws_account_id`, and normally only the Makefile supplies them.

**Check.** The per-node `KUBELET-VERSION` column, and a list of available `1.36.x-1.1` versions. If the
highest is `1.36.4-1.1`, there is nothing to move to: record that, write the playbook and the gate anyway
(steps 16 and 17), and mark criterion #14 as not measured. That is an honest outcome and the same shape as the
Jenkins phase recording step 19 as not run.

**Record** the available versions.

## Step 16 — The compatibility gate

**Problem now.** "Rancher's chart accepts 1.36" is a memory, not a check.

**Why it matters.** Design §4.2.1 makes this a required gate before any Kubernetes version moves.

**Workstation, window 0.**
```bash
helm show chart rancher --repo https://releases.rancher.com/server-charts/stable --version 2.15.1 | yq '.version, .kubeVersion'
```

**Check.** `2.15.1` and `< 1.37.0-0`. Compare with step 15's target and write down whether it passes. Any 1.36
patch passes without touching Rancher.

> **Stop gate.** If the target is 1.37 or higher, this gate fails. Upgrading Rancher first is separate work
> with its own risk, and it is not what this drill is for.

**Record** both values and the pass/fail.

## Step 17 — Write `upgrade.yml`

**Problem now.** `infra/ansible/` has only `site.yml`. The design's §7 layout has listed `upgrade.yml` from
the beginning and it was never written.

**Why it matters.** Upgrading three control planes by hand is where mistakes happen, and the ordering
constraint is real: etcd accepts one membership change at a time, which is why `site.yml` already uses
`serial: 1` for joins.

| File | Change |
|---|---|
| `infra/ansible/inventory/group_vars/all.yml` | `kubernetes_version` and `kubernetes_apt_version` to the target |
| `infra/ansible/upgrade.yml` | The playbook |

**Only two variables change** for a patch. `kubernetes_minor` is part of the apt repository URL and its
signing-key URL — each minor has its own — so it moves only on a minor upgrade.

**Three plays, in this order.** The package must be upgraded before the command it provides is asked to do
something new: a 1.36.4 `kubeadm` refuses to apply a higher version.

1. `hosts: first_node` — upgrade **`kubeadm` only**, with `allow_change_held_packages: true` →
   `kubeadm upgrade plan` → `kubeadm upgrade apply -y v{{ kubernetes_version }}`.
2. `hosts: first_node` — drain → upgrade `kubelet` and `kubectl` → `daemon_reload` and restart kubelet →
   uncordon → **wait** for `Ready` and every Argo CD Application `Healthy`.
3. `hosts: other_nodes`, **`serial: 1`** — upgrade `kubeadm` → `kubeadm upgrade node` → drain → upgrade
   `kubelet` and `kubectl` → restart kubelet → uncordon → wait.

Three plays rather than two because `hosts: nodes` takes the inventory's order and nothing guarantees node 1
comes first. `first_node` and `other_nodes` already exist and say it explicitly, the same way `site.yml` does.

> **The trap, and it is worse than a no-op.** `kubeadm_init` re-templates `/etc/kubernetes/kubeadm-config.yaml`
> on every run, and that file carries `kubernetesVersion`. But `kubernetes_packages` already installs the
> pinned version with `allow_change_held_packages: true` — so bumping the pin and re-running `make cluster`
> **installs the new kubelet on all three nodes and dpkg restarts it**, while the control-plane static pods
> keep running the old binaries. You end with a kubelet ahead of the API server and a config file claiming the
> upgrade happened. Only `kubeadm upgrade` moves the control plane.

**Check.**
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible && ansible-playbook upgrade.yml --syntax-check
cd ~/Medical-RAG-Chatbot/infra/ansible && ansible-playbook upgrade.yml --list-hosts --list-tasks
```

Expected: the syntax check passes, and `--list-hosts` shows `medical-rag-node-1` alone in plays 1 and 2, with
`-2` and `-3` in play 3.

> `--check` is a weak gate here and is not the check: every `command` and `shell` task is skipped in check
> mode, so a clean run proves the play parses and the hosts answer, not that the upgrade works. Step 18 is the
> real check.

## Step 18 — The upgrade drill

**Problem now.** The playbook has never run while anything depended on the cluster.

**Why it matters.** This is criterion #14's measurement: the **failed-request count**. Prod runs two replicas
spread across nodes with a PodDisruptionBudget of `minAvailable: 1`, so a drain should evict one at a time and
the count should be zero. If the spread or the budget were wrong, it will not be.

**Before starting**, confirm Kyverno will survive the drains:
```bash
kubectl -n kyverno get deploy,pdb
```
Expected: the admission controller `2/2`, its PDB showing `ALLOWED DISRUPTIONS 1`. With one replica the first
drain blocks forever and no Pod can be created cluster-wide while it is gone.

**Workstation, window 2** — window 1 keeps the tunnel, because the Check below needs it:
```bash
while true; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://app.recruitai.io.vn/)
  test "$code" = 200 || echo "$(date -u +%FT%TZ) $code"
  sleep 3
done | tee /tmp/upgrade-failures.log
```

Two deliberate choices. The path is `/`, not `/healthz`: the Ingress routes only `/` and `/clear` with
`pathType: Exact`, and nginx answers 404 for the probes. And `sleep 3` is 20 requests a minute, under the
Ingress's `limit-rpm: 30` — one request a second exhausts nginx's burst after about five minutes and fills the
log with `503`s that have nothing to do with the upgrade.

**Let the loop run two minutes first** and confirm the log is still empty. That is the baseline.

**Workstation, window 0:**
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible && time ansible-playbook upgrade.yml -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=242834061265
```

**Check.** Stop the loop in window 2 with Ctrl-C, then:
```bash
wc -l /tmp/upgrade-failures.log
cd ~/Medical-RAG-Chatbot && make kubectl CMD="get nodes -o wide"
cd ~/Medical-RAG-Chatbot && make apps
cd ~/Medical-RAG-Chatbot && make oidc-check
```

Expected: three nodes on the new version and `Ready`; every Application `Healthy`; two `same` lines — the
upgrade renews control-plane certificates, and this confirms it did not disturb the service-account signing
key; and a failure count that is zero, or a small number you can explain from the log's timestamps.

**After this step.** Works: the cluster changes **patch** version without losing the service. Proven by: the
version, the health and the count. Still missing: criterion #14 as the design words it — a **minor** upgrade,
which also needs Rancher moved first. Record #14 as *partially measured: patch path only*.

**Record** the playbook's `time`, each node's version, the failure count, and — if it is not zero — which
drain each failure lines up with.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `make shared` asks `var.budget_email  Enter a value:` | `terraform.tfvars` is missing. Ctrl-C, copy the `.example`, fill it in (step 1). Typing a value at the prompt redirects the budget alerts |
| `make shared` fails `BucketAlreadyOwnedByYou` | `make infra` already recreated the bucket in the cluster stack. Run `make infra` (it destroys it), then `make shared`, then `make infra` again (step 2) |
| The shared plan wants to **destroy** the ECR repository | Do not apply. Stop and read the plan (step 3) |
| `make tunnel` connects but `kubectl` hangs | The tunnel targets an instance id from before the teardown. Ctrl-C and open a new one |
| `make apps` shows two or three rows a minute after `make bootstrap` | `bootstrap` does not wait. Use the `kubectl wait application/root` line (step 5) |
| `make oidc-check` says `DIFFERENT` | The cluster was built with a different signing key. **Do not** `make oidc-publish` over it — app guide step 4 |
| The VPN will not connect after a rebuild | New Elastic IP behind `vpn.recruitai.io.vn`. Deactivate and re-activate the client (step 7) |
| A `CertificateRequest` exists after a rebuild | The restore lost its race with cert-manager; one Let's Encrypt issuance was spent. Do not rebuild again today |
| The CronJob fails with `AccessDenied` on S3 | The node policy loops over the cluster's own buckets and the bucket moved to `shared`. Add the ARN back through the `data` lookup (step 2) |
| `etcdctl: unknown command "status"` | etcd 3.6 removed `snapshot status` and `snapshot restore` from `etcdctl`. Both are `etcdutl` |
| `snapshot status` prints revision 0 | The snapshot is empty and uploaded anyway. Check the etcd endpoint and the certificate paths |
| After the restore, etcd will not form a cluster | The three members disagree. All three must be restored from the same file, with the same `--initial-cluster` and `--initial-cluster-token`, before any of them starts |
| After the restore, etcd starts on an empty database | `--data-dir` was omitted, so `etcdutl` wrote `./<name>.etcd` instead |
| `kubectl get policyreport -A` returns nothing | The policy matches nothing, which also means it denies nothing. Compare `imageReferences` with the rendered reference (step 13) |
| The policy reports `fail` with an authentication or `MANIFEST_UNKNOWN` error | Kyverno could not read the signature from ECR. Check its registry credential helper, and that its namespace does not block `169.254.169.254` |
| Jenkins build pods stop starting after Kyverno | The pattern is `medical-rag*` and is catching `medical-rag-ci`, which is never signed. Narrow it to `medical-rag:*` |
| The unsigned-image test is refused with `violates PodSecurity "restricted"` | PSA refused it before Kyverno saw it. Add the `securityContext` overrides (step 14) |
| A rebuild stalls at wave 2 and Jenkins never appears | An `Enforce` policy is refusing the app's image. Use the escape hatch in step 14 — a hand edit does not hold against `selfHeal` |
| `kubectl version --short` → `unknown flag` | Removed in 1.28. Use `version -o yaml`, or `get nodes -o wide` for the kubelet versions |
| `apt-cache madison` shows no version above 1.36.4 | There is nothing to upgrade. Record it, keep the playbook, mark #14 not measured (step 15) |
| `kubeadm upgrade apply` says the target is higher than kubeadm | The `kubeadm` package was not upgraded first. That is play 1's job (step 17) |
| The upgrade "succeeds" but the control plane is unchanged | `site.yml` installed the new kubelet and rewrote the config without upgrading. Only `kubeadm upgrade` moves the control plane (step 17) |
| A drain hangs forever | A PodDisruptionBudget cannot be satisfied — usually one replica with `minAvailable: 1`. Kyverno's admission controller is the likely one (step 13) |
| The load loop logs `503` from the start | The path is `/healthz`, which the Ingress does not route, or the rate is above `limit-rpm: 30` (step 18) |

---

[Concepts](concepts.md) · [Evidence](../evidence/drills.md) · [Design](../selfmanaged-k8s-ops-design.md) · [Runbook](../runbook.md)
