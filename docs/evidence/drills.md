# Drills phase — evidence

Measurements for design criteria **#12** (etcd restore), **#13** (Kyverno), **#14** (upgrade), plus the
rebuild that preceded them. AWS account `242834061265`, region `ap-southeast-1`. Every command ran on the ops
workstation unless a line says otherwise. Checks not listed here returned the output the
[guide](../drills/guide.md) expects. The problems these close are stated in
[`../drills/README.md`](../drills/README.md).

**The run started on 2026-09-22.** This file was written before it as the shape the numbers go into, so that
a missing number is visible as a missing number rather than as an absence nobody notices. Rows still marked
*pending* have not been measured.

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

**Measured.**

- **Step 3.** Plan summary: *pending*. Read back after the apply: the bucket
  `medical-rag-etcd-backups-242834061265` exists (creation time `2026-09-21 23:54:10` as `aws s3 ls` prints it,
  in the workstation's local time), and `aws ecr describe-repositories` reports `medical-rag-ci` as `IMMUTABLE`.
- **Step 4.** `time make infra`: **3 m 50 s**. `time make cluster`: **6 m 23 s**; `PLAY RECAP` line: *pending*.
  The node policy read back with `get-role-policy`, statement `S3ReadWriteObjects`, lists both
  `arn:aws:s3:::medical-rag-ssm-transfer-242834061265/*` and `arn:aws:s3:::medical-rag-etcd-backups-242834061265/*`.
  The first `make ping` failed on node 2 (`i-00f6ac0724e0966bb`) with `TargetNotConnected`; nodes 1 and 3
  answered. A second `make ping` a few minutes later, with nothing changed, answered `SUCCESS` on all three.
  So this time the agent registered late rather than never, unlike the Ansible-phase incident in
  [`ansible.md`](ansible.md), which needed a reboot. The SSM record and console log were not read, so the two
  cannot be told apart by cause.
- **Step 5.** `time make bootstrap`: **56.9 s**. The guide's
  `kubectl -n argocd wait application/root --for=jsonpath='{.status.health.status}'=Healthy` printed
  `condition met` after **1 m 18 s**, yet the `make apps` run straight after showed `root` `OutOfSync`
  `Progressing` with 6 Applications. **The wait passed falsely**: `root` read `Healthy` for a moment before its
  waves ran, and the wait caught that moment. Several `make apps` runs later: 10 Applications, waves -3 to 0
  all `Synced` `Healthy`, none of waves 1 to 4 (`medical-rag-dev`, `medical-rag-prod`, `jenkins-platform`,
  `jenkins`) created, and `root` `OutOfSync` `Healthy`. Nothing was stuck: read a few minutes later, `root`'s
  last operation was `Succeeded` (`successfully synced (all tasks run)`) and `make apps` showed **14
  Applications, every one `Synced` `Healthy`**. The later waves had simply still been running. **The defect is
  the check**: `root` reports `Healthy` *while* its sync is in progress, so a wait on health alone can return at
  any point. Waiting for `Synced` first, then `Healthy`, would mark the end, because `root` is `Synced` only once
  the last wave's Application exists. **The rebuild time for step 5 was therefore not measured on this run**;
  the 1 m 18 s is when the wait returned, not when the platform was up.
- **Step 6.** `make oidc-check` against `https://medical-rag-oidc-242834061265.s3.ap-southeast-1.amazonaws.com`:
  `same  .well-known/openid-configuration` and `same  openid/v1/jwks`. The rebuilt API server signs with the key
  the issuer publishes.
- **Step 7.** Certificate `wildcard-recruitai` `READY True`, `notAfter` **2026-12-17T13:08:54Z**, and
  `kubectl -n ingress-nginx get certificaterequests` printed `No resources found`: the wildcard was restored
  from the PushSecret backup, and no Let's Encrypt issuance was spent. Both admin passwords were read (32
  characters each; not recorded). WireGuard handshake: *not reported*.

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

**Measured.**

- **Step 8.** Application `etcd-backup` `Synced` `Healthy` at 00:47:03 UTC on 2026-09-22, about 20 s after the
  refresh. CronJob `etcd-snapshot`: `0 */6 * * *`, `TIMEZONE Etc/UTC`, `SUSPEND False`, no last schedule.
  As the guide says, this proves the object exists and nothing more. The first scheduled run is 06:00 UTC.
  The etcd image is the one kubeadm runs, read from the etcd pods' `imageID`: identical on all three nodes,
  `registry.k8s.io/etcd:3.6.8-0@sha256:397189418d1a00e500c0605ad18d1baf3b541a1004d768448c367e48071622e5`.
  The CronJob mounts three certificate files rather than `/etc/kubernetes/pki/etcd`, because that directory
  also holds `ca.key`, `server.key` and `peer.key`.

**What the restore must also answer**, beyond the RTO: what did *not* come back. Anything created between the
snapshot and the deletion is lost by definition — the RPO made visible. Name it rather than letting it pass.

---

## Part 2 — Kyverno

| Step | What to record |
|---|---|
| 12 | That `diff` against `cosign public-key` reports no difference, and the curve is `NIST CURVE: P-256` |
| 13 | The **Kyverno chart version chosen**, and the `policyreport` rows for dev and prod while in `Audit`. **A report with zero rows is a failure**, not a pass |
| 14 | The admission error **verbatim**, and that a signed image still deploys afterwards |

**Measured.**

- **Step 12.** `diff` between `cosign public-key --key awskms:///alias/medical-rag-cosign` and
  `deploy/argocd/manifests/kyverno-policies/cosign.pub`: no difference (`same key`). `openssl pkey` reports
  `Public-Key: (256 bit)` and `NIST CURVE: P-256`.
- **Step 13, before choosing anything.**
  - **Where the signatures are.** `cosign tree` on prod's digest (`sha256:f5b6789a…269e`, also dev's) lists
    only OCI referrers, of two kinds: `https://sigstore.dev/cosign/sign/v1` (signatures) and
    `https://spdx.dev/Document` (SBOM attestations). The repository has **no `sha256-*` tag at all**, so a
    verifier that looks only for cosign v2's `.sig` tag would report `fail` on every signed image.
  - **Chart version.** `helm search repo kyverno/kyverno` offered 3.9.1 (v1.19.1), 3.9.0 (v1.19.0) and 3.8.2
    (v1.18.2). **Chosen: 3.8.2**, `kubeVersion: '>=1.25.0-0'`. Not 3.9.x: kyverno/kyverno#17363 reports that
    v1.19.0 fails to verify a key-signed image whose signature exists only as a sigstore bundle referrer —
    this repository's exact case — and that v1.18.1 verifies it. The fix is milestoned for 1.19.2. Whether
    v1.18.2 behaves like v1.18.1 is what the Audit run has to show.
  - **Policy type.** `ImageValidatingPolicy`, not the guide's `ClusterPolicy` with `verifyImages`: the working
    configuration in that issue is an `ImageValidatingPolicy`, and the `verifyImages` documentation does not
    cover cosign v3 referrers.
  - **The guide was wrong about the PDB.** The chart's `admissionController.podDisruptionBudget` defaults to
    `enabled: false` (with `minAvailable: 1` underneath), and `replicas` to `~`. There is no default budget to
    block a drain; the values enable one.
- **Step 13a, the controller.** Application `kyverno` synced (`successfully synced (all tasks run)`):
  `kyverno-admission-controller` 2/2 on `medical-rag-node-2` and `medical-rag-node-3`, the other three
  controllers 1/1, PDB `MIN AVAILABLE 1`, `ALLOWED DISRUPTIONS 1`. The `ImageValidatingPolicy` CRD serves
  `v1`, `v1alpha1` and `v1beta1`, storage `v1beta1`. One startup-probe failure on an admission pod
  (`tls: internal error`), before its webhook certificate existed; 0 restarts.
- **Problem found: `kyverno` stayed `OutOfSync`, so `root` stayed `Progressing`.** The eleven
  `policies.kyverno.io` CRDs read `OutOfSync` after a successful sync. Not caused by the
  `kyverno-migrate-resources` Job (its log: `stored version is already up to date, nothing to do`), and
  `managedFields` show no writer to `spec` but `argocd-controller`. The rendered and live `spec` of
  `imagevalidatingpolicies.policies.kyverno.io` differ **only** in `conversion: {strategy: None}`, a default the
  API server adds; `kubectl diff --server-side --field-manager=argocd-controller` against the rendered CRD
  exited **0**. So the cluster matched Git and the client-side diff was wrong. Fix:
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` on the Application, as `platform-tls` already has.
  Left unfixed, the next rebuild would have stopped at wave -2 with nothing reported as an error.
- **Problem found: the fix could not arrive by Git.** After the `ServerSideDiff` commit (`f3e80e3`) was pushed,
  the live `kyverno` Application still had no `compare-options` annotation. `root`'s operation had started at
  01:42:37 UTC on the previous commit (`41da7f0`) and was still `Running`, message
  `waiting for healthy state of argoproj.io/Application/kyverno`. Argo CD does not start a new sync while one
  runs, so the commit that would make `kyverno` Synced could only be applied after `kyverno` was Synced: a
  deadlock, not a delay. Broken by annotating the live Application with the value Git already held
  (`kubectl annotate … compare-options=ServerSideDiff=true`): `kyverno` read `Synced Healthy` 10 s later,
  `root`'s operation ended `Succeeded`, and `make apps` showed 16 Applications, all `Synced` `Healthy`. It can
  happen only when an Application is fixed while `root` is waiting on it; a rebuild creates the Application
  with the annotation already on it. **The general lesson for the health gate**: a fix to an Application that
  the gate is waiting on has to be applied to the live object, or `root`'s operation terminated first.
- **Step 13b, first Audit run: every signed image failed.** Both `ImageValidatingPolicy` objects `READY true`,
  `kyverno-policies` `Synced Healthy`. After deleting a web pod in each namespace, all pods came back Ready
  (Audit blocks nothing) and the policy reports held **5 rows, all `fail`**: dev's web and `index-build` pods,
  prod's two web pods and `index-build`. So the globs match — the zero-row outcome did not happen — but the
  verdict was wrong. The admission controller's log gave the cause:
  `image verification failed error="failed to build cosign verification opts: getting Rekor public keys:  rekor URL must be provided"`,
  logged after `verifying cosign image signature … digest=sha256:f5b6789a…269e`. The signature fetch from ECR
  therefore worked, and verification never started; this is not kyverno/kyverno#17363. Kyverno 1.18.2
  requires `ctlog.url` even with `insecureIgnoreTlog: true`, and the policy had left it out. Fix: `url:
  https://rekor.sigstore.dev` on both policies, as in the Kyverno documentation and the issue's working policy.

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
- **Whether admission now needs the public Sigstore.** The error named "getting Rekor public keys". If Kyverno
  fetches them from `rekor.sigstore.dev` (or its TUF root) at admission, then with prod on `failurePolicy:
  Fail` an outage there, or a cut in NAT egress, blocks prod's pods. Not measured.
- Kyverno at wave -2 becomes a new single point of failure for every rebuild: if it never reports `Healthy`
  and `Synced`, nothing from wave -1 onward syncs. Record the rebuild time it adds.
