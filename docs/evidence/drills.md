# Drills phase — evidence

Measurements for design criteria **#12** (etcd restore), **#13** (Kyverno), **#14** (upgrade), plus the
rebuild that preceded them. AWS account `<account-id>`, region `ap-southeast-1`. Every command ran on the ops
workstation unless a line says otherwise. Checks not listed here returned the output the
[guide](../drills/guide.md) expects.

**Nothing below has been measured yet.** This file is the shape the numbers go into, written before the run so
that a missing number is visible as a missing number rather than as an absence nobody notices.

## Results

| # | Criterion | Status | Number |
|---|---|---|---|
| 12 | etcd restore | Not measured | RTO: *pending* |
| 13 | Kyverno | Not measured | Admission error: *pending* |
| 14 | Upgrade | Not measured | Failed requests: *pending*. **Note:** the design words #14 as a *minor* upgrade; this drill exercises the patch path only, so the best outcome here is *partially measured* |

| Question | Answer |
|---|---|
| How much cluster state can be lost? | RPO is set by the CronJob schedule: **6 hours** by design. Confirm against the first two snapshots' timestamps |
| How long does a restore take? | *pending* — measured from the decision to restore to every Application `Healthy` |
| Does prod refuse an unsigned image? | *pending* |
| Does a rolling upgrade drop requests? | *pending* |

---

## Part 0 — The rebuild

The cluster stack was destroyed on 2026-09-21. `shared` and `bootstrap` survived.

| Step | What to record |
|---|---|
| 3 | `make shared` plan summary. Expected **1 to change** (`MUTABLE -> IMMUTABLE`) and **5 to add** (the moved bucket) |
| 4 | `time make infra`, `time make cluster`, the `PLAY RECAP` line, and the node policy read back from `get-role-policy` |
| 5 | `time make bootstrap`, the `kubectl wait application/root` duration, and the `make apps` table (14 Applications) |
| 6 | The two `oidc-check` lines |
| 7 | The certificate's `notAfter`, and whether any `CertificateRequest` appeared |

**Comparison available.** The GitOps phase measured a full rebuild at **14 m 11 s** on 2026-09-18 — but that
cluster had no Jenkins and no app in it. This rebuild carries 13 Applications across eight waves, so a larger
number is expected and is not a regression.

---

## Part 1 — etcd

| Step | What to record |
|---|---|
| 8 | That the Application went `Healthy`, and the CronJob's schedule line. This proves the object exists and nothing more |
| 9 | The job's duration, the object's size in S3, and the `etcdutl snapshot status` table from the initContainer's log: hash, revision, total keys |
| 10 | t1 (restore begins), t2 (all Applications `Healthy`), **RTO = t2 − t1**, and which point in time the snapshot was from |
| 11 | The RPO, the RTO, and anything that did not come back |

**What the restore must also answer**, beyond the RTO: what did *not* come back. Anything created between the
snapshot and the deletion is lost by definition — the RPO made visible. Name it rather than letting it pass.

---

## Part 2 — Kyverno

| Step | What to record |
|---|---|
| 12 | That `diff` against `cosign public-key` reports no difference, and the curve is `NIST CURVE: P-256` |
| 13 | The **Kyverno chart version chosen**, and the `policyreport` rows for dev and prod while in `Audit`. **A report with zero rows is a failure**, not a pass |
| 14 | The admission error **verbatim**, and that a signed image still deploys afterwards |

**The distinction this phase has to hold.** A policy that allows everything and a policy that matches nothing
look identical from the outside: no denials either way. The Audit step exists to tell them apart before
`Enforce` is switched on.

---

## Part 3 — The upgrade

| Step | What to record |
|---|---|
| 15 | `apt-cache madison kubeadm` output. If `1.36.4-1.1` is the highest, there is nothing to upgrade — record that and mark #14 not measured |
| 16 | The chart version and its `kubeVersion`, and the pass/fail against the target |
| 17 | The `--syntax-check` result and the `--list-hosts` play membership |
| 18 | `time` for the playbook, each node's version afterwards, and the failed-request count |

**If the count is not zero**, line each failure's timestamp up against the drains. Two replicas with
`minAvailable: 1` spread across nodes should give zero; a non-zero count means the spread or the budget is not
doing what it claims, and that is a more valuable finding than a clean run.

---

## What these results decided

*To be written after the run.*

## Problems found and fixed

*To be written after the run.*

## Still to check

- The etcd snapshot CronJob uses the **node's instance role** through IMDS rather than a role of its own. It
  therefore carries whatever else that role holds — eight Secrets Manager secrets and the ACME TXT record. A
  dedicated IRSA role through the existing issuer would be tighter; not done.
- Restoring to a point *before* the test namespace existed and restoring to a point *after* it prove different
  things. Whichever the drill does, the evidence must say which.
- The upgrade drill measures one path: a patch inside 1.36. A minor upgrade also requires moving Rancher
  first, and that is untested.
- etcd metrics are still plain HTTP on port 2381, a limit inherited from the GitOps phase and not addressed
  here.
- **Design §4.6 also asks for baseline Pod Security policies under Kyverno.** This phase does not add them:
  the two Jenkins namespaces already carry Pod Security labels and a `ValidatingAdmissionPolicy`, and the
  app namespaces enforce `restricted`. Criterion #13 is therefore met on the signature half only.
- Kyverno at wave -2 becomes a new single point of failure for every rebuild: if it never reports `Healthy`
  and `Synced`, nothing from wave -1 onward syncs. Record the rebuild time it adds.
