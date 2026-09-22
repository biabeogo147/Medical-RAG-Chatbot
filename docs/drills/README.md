# Drills: three claims this project cannot yet make

Start here. This page says what is wrong, what will be built, and how you will know it worked.
[`concepts.md`](concepts.md) defines every idea the work uses — read the sections this page sends you to
before you open the guide. [`guide.md`](guide.md) is the how: eighteen steps, each with its commands and its
check.

## Where the project stands

Five phases are finished. Terraform builds the account, Ansible builds a three-node kubeadm cluster, Argo CD
installs everything that runs inside it, the app serves from dev and prod, and an in-cluster Jenkins pipeline
takes a commit to a scanned, signed image and opens a pull request for prod.

That is Day 1 — the system exists. This phase is Day 2: **the system keeps working when something goes
wrong, when something untrusted arrives, and when something changes version.**

Three claims are written in the design and none of them is true yet.

---

## Problem 1 — the backup deletes itself

**What is wrong.** etcd is the only place the cluster keeps state; every object anyone has ever applied lives
there. Nothing backs it up. And the bucket the design nominates for snapshots,
`medical-rag-etcd-backups-<account>`, is defined in the **cluster** Terraform stack with
`force_destroy = true` — so `make down` deletes the bucket and everything in it. The GitOps phase already
recorded this as a known limit and said what to do about it: *"Move it to the shared stack before relying on
backups (day-2 phase)."*

A backup destroyed together with the thing it backs up is not a backup.

**Concepts to read first.**
[§1 etcd, and why a snapshot is not a volume backup](concepts.md#1-etcd-and-why-a-snapshot-is-not-a-volume-backup) ·
[§2 `snapshot save`, `snapshot status`, `snapshot restore`](concepts.md#2-snapshot-save-snapshot-status-snapshot-restore) ·
[§3 RTO and RPO](concepts.md#3-rto-and-rpo)

**The solution.** Move the bucket to the `shared` stack, where the registry, the signing key and the artifacts
bucket already live and survive every teardown. Then a CronJob on a control-plane node takes a snapshot every
six hours, **verifies it before uploading**, and writes it to S3.

**Desired outcome — criterion #12.** Delete a namespace, restore the cluster from a snapshot, and get the
namespace back. The number that closes it is the **RTO**, measured from the decision to restore to the moment
every Argo CD Application is `Healthy` again. The **RPO** is a design choice, not a measurement: six hours,
set by the schedule.

---

## Problem 2 — the signature nobody checks

**What is wrong.** Since the Jenkins phase, every image built on `main` is signed with an asymmetric KMS key
whose private half never leaves AWS. Nothing reads those signatures. The Jenkins README says so in its own
limits table, and `docs/terraform/README.md` repeats it: *"Nothing verifies signatures yet: Kyverno is not
installed."*

A signature nobody verifies proves an image *could* be checked, not that any image *was*.

There is a sharper version of the gap. The pipeline's skip guard ends any build whose commit touched only
`deploy/`. So a digest hand-edited into `deploy/envs/prod/values.yaml` is never built, never scanned, never
signed — and today nothing downstream objects. **The whole pipeline can be walked around with one file edit.**

**Concepts to read first.**
[§4 Admission control, and where Kyverno sits](concepts.md#4-admission-control-and-where-kyverno-sits) ·
[§5 Verifying a signature: by key, or by log](concepts.md#5-verifying-a-signature-by-key-or-by-log)

**The solution.** Export the public half of the KMS key — it is not a secret, so Git is the right place for
it — and install Kyverno with an `ImageValidatingPolicy` that checks the app's images against it. `Audit` in
dev, `Deny` in prod. The key is static and the transparency log is off, because the pipeline deliberately
signs without one. `ImageValidatingPolicy` rather than the older `verifyImages` rule, because cosign v3 stores
each signature only as a sigstore bundle OCI referrer (guide step 13).

**Desired outcome — criterion #13.** Deploy an unsigned image to prod and be refused. The evidence is the
**admission error** itself, captured verbatim.

---

## Problem 3 — the upgrade nobody has rehearsed

**What is wrong.** The cluster is pinned to Kubernetes 1.36.4 and has never been upgraded. There is no
`upgrade.yml`, although the design's repo layout has listed one since the beginning. Upgrading three control
planes by hand is where mistakes happen, and etcd accepts one membership change at a time.

**Concepts to read first.**
[§6 `kubeadm upgrade apply` and `kubeadm upgrade node`](concepts.md#6-kubeadm-upgrade-apply-and-kubeadm-upgrade-node) ·
[§7 cordon, drain, and the disruption budget](concepts.md#7-cordon-drain-and-the-disruption-budget)

**The solution.** A playbook that moves one node at a time: drain, upgrade, uncordon, and **wait for that node
to be `Ready` and every Argo CD Application `Healthy` before touching the next**. In front of it, the
compatibility gate the design already specifies — Rancher's chart declares `kubeVersion: < 1.37.0-0`, so the
cluster may not cross 1.37 until Rancher moves first.

**Desired outcome — criterion #14.** Run the upgrade while a loop sends requests to prod, and count the
failures. Prod runs two replicas spread across nodes with a PodDisruptionBudget of `minAvailable: 1`, so the
expected count is **zero** — and a non-zero count is the more valuable result, because it means the spread or
the budget is not doing what it claims.

**One honest limit.** The design words criterion #14 as a *minor* upgrade. This phase exercises a **patch**
inside 1.36, because a minor would fail the compatibility gate and require moving Rancher first — a second
change with its own risk, nested inside a drill. #14 will close as *partially measured*.

---

## The idea that ties the three together

Each problem could be answered by building the machinery and stopping there: a CronJob exists, a policy
exists, a playbook exists. All three would then be true in the sense that the code is present, and all three
would be untested.

The Jenkins phase ended with **five checks that had passed while the thing they guarded was broken**, and the
lesson written down was that *a check that cannot fail is worse than no check, because it buys confidence
that was never earned.* A backup nobody has restored, a policy nobody has tripped and an upgrade nobody has
run under load are the same shape.

So every control here is paired with a drill that makes the bad thing happen on purpose:

| Control | The bad thing | What closes the criterion |
|---|---|---|
| etcd snapshots to S3 | A namespace is deleted | **RTO** — time to every Application `Healthy` |
| Kyverno `ImageValidatingPolicy` | An unsigned image is deployed to prod | The **admission error** |
| `upgrade.yml`, one node at a time | Kubernetes changes version while traffic flows | The **failed-request count** |

[§8 Why each control is paired with a drill](concepts.md#8-why-each-control-is-paired-with-a-drill) names the
specific way each one can be silently broken.

---

## Before any of it: the cluster has to come back

`make down` ran on 2026-09-21, so the **cluster** stack is destroyed. The `shared` and `bootstrap` stacks were
not — ECR, the KMS key, the artifacts bucket, Secrets Manager, the OIDC issuer, the DNS zone, the state bucket
and the ops workstation are all still there.

Two things about the rebuild are worth knowing before you start, because both mislead:

- **The Terraform `bootstrap` stack is never destroyed.** It holds the state bucket and the workstation you
  are typing on. The thing called `make bootstrap` installs Argo CD — a different job with an unfortunate
  name.
- **`shared` has a change waiting.** Commit `ddb3b28` set the tools repository to `IMMUTABLE` and was never
  applied. It has to land before `make infra`, because the cluster stack reads two data sources out of
  `shared`.

Part 0 of the guide is that rebuild, in six steps. It is a prerequisite, not a goal — nothing in it is new
work, and the numbers it produces are for comparison against the GitOps phase's 14 m 11 s.

**And the bucket move belongs in Part 0, not Part 1.** Right now the cluster stack is destroyed, so the
backup bucket exists neither on AWS nor in any state file: moving it is a *create*. Once `make infra` runs,
the cluster stack owns that name again and the same move becomes a migration that fails. This is the cheapest
moment there will ever be.

---

## What gets built

| Where | What |
|---|---|
| `infra/terraform/shared/storage.tf` | The etcd backup bucket, without `force_destroy` |
| `infra/terraform/cluster/{main,iam,storage}.tf` | The bucket removed from this stack, looked up by name, and its ARN added back to the node policy |
| `deploy/argocd/manifests/etcd-backup/` | Namespace and the snapshot CronJob |
| `deploy/argocd/manifests/kyverno-policies/` | The two `ImageValidatingPolicy` objects (dev, prod) and the public key |
| `deploy/argocd/apps/` | Three new Applications: `etcd-backup`, `kyverno`, `kyverno-policies` |
| `deploy/argocd/values/kyverno.yaml` | Chart values, including two admission-controller replicas and their disruption budget |
| `infra/ansible/upgrade.yml`, `infra/ansible/tasks/upgrade-kubelet.yml` | The rolling upgrade playbook and the per-node steps it repeats |
| `infra/ansible/inventory/group_vars/all.yml` | Two version pins |

Nothing in the app's chart changes, and no existing Application is touched.

---

## What this phase deliberately does not do

| Not done | Why | What it would take |
|---|---|---|
| A dedicated IAM role for the snapshot job | It uses the node's instance role through IMDS, which already has the grant. Simpler, and the trade-off is recorded rather than hidden | Another IRSA role through the existing issuer |
| Baseline Pod Security policies in Kyverno, which design §4.6 also asks for | The two Jenkins namespaces already carry Pod Security labels and an admission policy, and the app namespaces enforce `restricted` | A second Kyverno policy set |
| A minor Kubernetes upgrade | It fails the compatibility gate until Rancher moves first | Upgrading Rancher, then repeating the drill |
| etcd metrics over TLS | Inherited limit from the GitOps phase; port 2381 is plain HTTP and reachable only from the other nodes | Scraping with etcd's client certificates |

One consequence to accept knowingly: **Kyverno at sync-wave -2 becomes a new single point of failure for every
rebuild.** If it never reports `Healthy` and `Synced`, nothing from wave -1 onward syncs — the certificate
restore, monitoring, Rancher, the app, Jenkins. The guide says how to get out of that, and the evidence
records the rebuild time it adds.

---

## Reading order

1. **This page** — what is broken and what "done" means.
2. **[`concepts.md`](concepts.md)** — the eight ideas the work uses. Read the sections each problem above
   points at; you should not meet a new term for the first time inside a command.
3. **[`guide.md`](guide.md)** — eighteen steps. Part 0 rebuilds the cluster, Parts 1 to 3 are the three
   drills.
4. **[`../evidence/drills.md`](../evidence/drills.md)** — written before the run, so a missing number shows up
   as a missing number. Filled in on 2026-09-22.
5. **[`questions.md`](questions.md) · [`answers.md`](answers.md)** — interview questions on the three drills and the
   CV measurements, in Vietnamese.

Design source: [§4.6 and criteria #12–#14](../selfmanaged-k8s-ops-design.md). Day-to-day operation of what
already exists: [`../runbook.md`](../runbook.md).
