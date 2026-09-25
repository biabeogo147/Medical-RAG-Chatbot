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
| 12 | etcd restore | **Measured** | **RTO 7 m 02 s** (t1 04:51:04Z → every Application Synced+Healthy, node Leases and pods settled 04:58:06Z); canary back with its original value; RPO of this run 6 m 01 s, ≤ 6 h by schedule |
| 13 | Kyverno | **Measured** (signature half; see Still to check) | Admission error: `admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-images-prod" denied the request: Policy verify-images-prod failed: the image is not signed with the medical-rag cosign key` |
| 14 | Upgrade | **Not measured**: 1.36.4 is the newest 1.36 patch (step 15) | Failed requests: *not measured*. **Note:** the design words #14 as a *minor* upgrade; this drill exercises the patch path only, so the best outcome here is *partially measured* |

| Question | Answer |
|---|---|
| How much cluster state can be lost? | RPO is set by the CronJob schedule: **6 hours** by design. Confirm against the first two snapshots' timestamps |
| How long does a restore take? | **7 m 02 s**, from deleting the namespace to every Application Synced and Healthy, operator typing included (step 10) |
| Does prod refuse an unsigned image? | **Yes.** An unsigned image was refused by Kyverno at admission, and signed replacement pods were admitted under the same policy minutes later (step 14) |
| Does a rolling upgrade drop requests? | **Not measured**: 1.36.4 is the newest 1.36 patch, so there was nothing to upgrade to (step 15) |

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

- **Step 3.** Plan summary: not recorded. Read back after the apply: the bucket
  `medical-rag-etcd-backups-242834061265` exists (creation time `2026-09-21 23:54:10` as `aws s3 ls` prints it,
  in the workstation's local time), and `aws ecr describe-repositories` reports `medical-rag-ci` as `IMMUTABLE`.
- **Step 4.** `time make infra`: **3 m 50 s**. `time make cluster`: **6 m 23 s**; `PLAY RECAP` line: not recorded.
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
  characters each; not recorded). WireGuard handshake: not recorded.

**Comparison available.** The GitOps phase measured a full rebuild at **14 m 11 s** on 2026-09-18 — but that
cluster had no Jenkins and no app in it. This rebuild carries 13 child Applications (14 with `root`) across eight waves, so a larger
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
- **Before step 9 (guide-measurements M0).** Namespace `restore-drill` with ConfigMap `canary`,
  `written-at=2026-09-22T04:14:20Z`, created before the first scheduled run at 06:00 UTC, so that snapshot holds
  data the restore can be checked against. Not in Git: Argo CD cannot recreate it.
- **Step 9 (M1): the first scheduled snapshot passed.** Run under a **temporary `*/15 * * * *` schedule**,
  committed at 04:38:40 UTC (live read of `.spec.schedule`), chosen to see the first run in minutes rather than
  wait for 06:00. The Job was still created by the CronJob controller: `manual=` empty.
  - Job `etcd-snapshot-29834205`: `start=2026-09-22T04:45:00Z`, `done=04:45:08Z` (**8 s**), `ok=1`. Taken after
    the canary (04:14:20Z).
  - `etcdutl snapshot status`: hash `65062525`, **revision 134191**, **total keys 2434**, 62 MB, version 3.6.0.
  - Upload: `s3://medical-rag-etcd-backups-242834061265/snapshots/20260922T044503Z-medical-rag-node-3.db`,
    **62,402,592 bytes**, taken on `medical-rag-node-3`. The node role's S3 grant from step 2 works.
  - The schedule was then reverted to `0 */6 * * *` in Git; the file is byte-identical to `d772a09` again.
    Live `.spec.schedule` read `0 */6 * * *` at **04:47:40 UTC**. The temporary schedule produced exactly
    **one** job and one S3 object.
- **Step 10 (M2): the restore drill passed.** Snapshot `20260922T044503Z-medical-rag-node-3.db`, copied to all
  three nodes (checksum `ded1f327…`, 62,402,592 bytes on each).
  - Pre-check: on every node the manifest's `--name` and `--initial-advertise-peer-urls` equalled the values the
    restore would use (`medical-rag-node-{1,2,3}`, `https://10.10.{1.252,2.245,3.197}:2380`).
  - **t1 = 04:51:04Z**, `kubectl delete namespace restore-drill` right after reading the canary.
  - Phase 1: all four static pods stopped on all three nodes within about 30 s. The `crictl.yaml does not
    exist` lines are warnings; the endpoint was given explicitly.
  - Phase 3 at 04:54:06Z: all three nodes restored with the **same cluster-id `9ed3a0fb6a89e03e`** and the same
    three members, revision bumped from 134191 to **1000134191** and marked compacted.
  - The loop first answered at 04:56:35Z (17 Applications, 2 not yet reconciled after t1); all reconciled at
    04:57:51Z; node Leases renewed and no pod outside Running/Completed at **t2 = 04:58:06Z**.
  - After: three nodes `Ready`; **`canary` back with `written-at=2026-09-22T04:14:20Z`**; `make apps` a minute
    later showed all 17 Synced Healthy; the CronJob read `0 */6 * * *` again — the snapshot held the temporary
    `*/15`, and Argo CD put Git's value back.
- **Step 11.** **RTO = 7 m 02 s.** **RPO of this run = 6 m 01 s** (t1 − the key's 04:45:03Z); by schedule, ≤ 6 h.
  What did not come back: anything written after 04:45:03Z, which in this window was the schedule revert, put
  back by Argo CD from Git. One oddity: the snapshot captured its own Job mid-run, so after the restore
  `etcd-snapshot-29834205` shows `DURATION 10m` (04:45 until the restored controller closed it) where the real
  run took 8 s.

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
- **Step 13b, second Audit run: pass.** With `ctlog.url` set, a new web pod in each namespace, reports read
  60 s later: `medical-rag-775945bd44-msf6d` (dev), `medical-rag-8654f9c58f-kkzqs` and
  `medical-rag-8654f9c58f-799qn` (prod), each `pass | success`, and no `image verification failed` line in the
  admission controller's log since the pods were deleted. The log does repeat
  `Could not save cache … open /.ecr/.config.json.tmp…: no such file or directory` at `info`: the ECR
  credential helper cannot write its cache, and verification works regardless. The completed `index-build` pods keep their first-run
  `fail` rows until the next background scan. The log at this level shows no HTTP call to Sigstore, which
  does not show there is none; the question stays under "Still to check".
- **Step 14, the good path first.** `cosign verify --key awskms:///alias/medical-rag-cosign --insecure-ignore-tlog`
  on prod's digest `sha256:f5b6789a…269e`: `The signatures were verified against the specified public key`.
  The test image, `medical-rag:1eaa43bf3512` (`sha256:c10cd57e…6769`, pushed 2026-09-19T11:12:25Z), still in
  ECR, and `cosign verify` on it fails: unsigned.
- **Step 14, the refusal.** `verify-images-prod` moved to `validationActions: [Deny]` (dev stays `Audit`). A
  pod in `medical-rag-prod` with that image and a spec that meets Pod Security `restricted`, so that PSA could
  not be the one refusing it:
  `Error from server: error when creating "STDIN": admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-images-prod" denied the request: Policy verify-images-prod failed: the image is not signed with the medical-rag cosign key`.
  The webhook name carries `svc-fail`: the refusal came from Kyverno, through the fail-closed webhook.
  Afterwards `kubectl get pod unsigned-test` returned `NotFound`.
- **Step 14, a signed image still deploys.** Both prod web pods deleted; the ReplicaSet recorded
  `SuccessfulCreate` for `medical-rag-8654f9c58f-wc9qd` and `-7mmkr` 11 s and 22 s after the `Killing` events,
  no `FailedCreate`, and the Deployment read `2/2`. Those two pods were admitted under `Deny`.
- **Problem found: "delete a prod pod" deleted both, twice.** The guide's step 13 command and the one used
  in step 14 delete by label, which selects **every** web pod, and `kubectl delete pod` does not consult a
  PodDisruptionBudget — only an eviction does. Events show both prod pods `Killing` at the same second
  (02:14:52 and again in step 14), with the first replacement created 11 s later. The guide's claim that this is
  safe because of the budget is wrong. Whether prod actually refused requests in those seconds was not
  measured. One pod at a time, by name, is the fix for the guide.

**The distinction this phase has to hold.** A policy that allows everything and a policy that matches nothing
look identical from the outside: no denials either way. The Audit step exists to tell them apart before
`Deny` is switched on.

---

## Part 3 — The upgrade

| Step | What to record |
|---|---|
| 15 | `apt-cache madison kubeadm` output. If `1.36.4-1.1` is the highest, there is nothing to upgrade — record that and mark #14 not measured |
| 16 | The chart version and its `kubeVersion`, and the pass/fail against the target |
| 17 | The `--syntax-check` result and the `--list-hosts` play membership |
| 18 | `time` for the playbook, each node's version afterwards, and the failed-request count |

**Measured.**

- **Step 15.** All three nodes `v1.36.4` (`kubectl get nodes -o wide`, 2026-09-22). `apt-cache madison kubeadm`
  on node 1 lists `1.36.4-1.1`, `1.36.3-1.1`, `1.36.2-2.1`, `1.36.1-1.1`, `1.36.0-1.1`. **The highest is the
  one installed: there is no patch to move to**, so criterion #14 is **not measured** on this cluster.
- **Step 16.** Rancher chart `2.15.1`, `kubeVersion: < 1.37.0-0`. The gate would pass for any 1.36 patch; it
  had no target to judge.
- **Step 17.** `infra/ansible/upgrade.yml` plus `tasks/upgrade-kubelet.yml`. `--syntax-check` passed.
  `--list-hosts --list-tasks`: four plays — a check play the guide does not have (target inside the pinned
  minor, all three nodes Ready, the Application count), `kubeadm upgrade apply` on node 1, node 1's kubelet,
  then `medical-rag-node-2` and `-3` with `serial: 1`. The first three list `medical-rag-node-1` alone. Not
  run: with nothing newer than 1.36.4 it would drain all three nodes to arrive where they are.

**If the count is not zero**, line each failure's timestamp up against the drains. Two replicas with
`minAvailable: 1` spread across nodes should give zero; a non-zero count means the spread or the budget is not
doing what it claims, and that is a more valuable finding than a clean run.

---

## Measured for the CV

Procedure: [`guide-measurements.md`](guide-measurements.md). M0 to M2 are recorded in Part 1 above; this section
holds the two that are not part of the drills guide.

| # | What | Result |
|---|---|---|
| M3 | Wall clock, `make infra` started → every Application Synced+Healthy; Application count; CertificateRequests | `infra/scripts/timed-rebuild.sh`, unattended, **VERDICT PASS**. t0 05:11:28Z → 05:33:15Z: **T = 21 m 47 s** (Terraform 3 m 46 s, `Plan: 86 to add, 0 to change, 0 to destroy`; SSM 7 s, no reboot; `make cluster` 6 m 17 s, one run, `failed=0` on all three; tunnel + bootstrap 57 s; Argo CD waves 10 m 40 s). **17 Applications**, all Synced and Healthy with no sync operation running, and still so a minute later. **0 CertificateRequests**; `oidc-check` two `same` lines; three nodes Ready on v1.36.4. No human prompt inside T (the plan was checked by the script); polling adds up to about 35 s. Not comparable with the 14 m 11 s of 2026-09-18, which had 9 Applications and a health-only wait |
| M4 | Positive-control build: build number, red stage, fixable count and severities | Branch `jenkins/step-gate-control`, gate changed to count fixable findings of any severity. The last `main` build's report (build 13) held **6 fixable: 5 MEDIUM, 1 LOW**. The branch build's gate printed `Fixable, any severity: 6` and ran `[ 6 -eq 0 ]` (11:24:37 local, 04:24:37 UTC). **Build 2: `Finished: FAILURE`**, red at the Scan gate — the failing `[ 6 -eq 0 ]` is that gate's last command. The log's stage-marker lines were not captured (the grep for `[Pipeline] {` matched nothing, likely because of the timestamp prefix). **First try failed to test anything**: the Jenkinsfile edit was never made, `git commit` found nothing, the push sent `main`'s own docs commit, and the Skip guard ended it `NOT_BUILT` (`only docs or deploy files changed`). The guide now checks `git diff --stat` first |

---

## What these results decided

- **Kyverno chart 3.8.2, not 3.9.x** (kyverno/kyverno#17363), and **`ImageValidatingPolicy`, not
  `verifyImages`**, because the signatures exist only as cosign v3 OCI referrers (step 13).
- **`ctlog.url` is set even though the transparency log is ignored**: Kyverno 1.18.2 refuses to verify without
  it (step 13b, `fb9c1f0`).
- **prod `Deny`, dev `Audit`** (step 14, `6bc941e`).
- **`compare-options: ServerSideDiff=true` on `kyverno`**, from its first commit in the guide (step 13a,
  `f3e80e3`).
- **Rebuild waits require `Synced`, then `Healthy`**, never health alone (Part 0 step 5).
- **The CV's rebuild figure comes from `infra/scripts/timed-rebuild.sh`** (M3): unattended, one wall-clock T,
  no sum of command times.
- **The snapshot schedule is back to `0 */6 * * *`** once one scheduler-made run had passed (step 9,
  `517a143`).
- **Pods are deleted one at a time, by name**, in the guide (step 14).

## Problems found and fixed

- **The `root` health wait passed falsely** (Part 0 step 5): `root` reads `Healthy` while its sync is still
  running. Fixed in the guide by waiting for `Synced` first.
- **`kyverno` stayed `OutOfSync`** because the API server adds `conversion: {strategy: None}` to the CRDs.
  Fixed with `ServerSideDiff=true` (`f3e80e3`).
- **The fix could not arrive by Git**: `root`'s running operation waited on the very Application the commit
  fixed. Broken by annotating the live Application with Git's value (step 13a).
- **`rekor URL must be provided`**: every signed image failed in Audit. Fixed with `ctlog.url` (`fb9c1f0`).
- **"Delete a prod pod" deleted both, twice**: a label selector deletes every match, and `kubectl delete pod`
  ignores the PodDisruptionBudget. The guide now deletes one pod by name.
- **The guide was wrong about the Kyverno chart's PDB default** (`enabled: false`); the values enable one.
- **M4's first try tested nothing**: the Jenkinsfile edit was never made. The guide now checks
  `git diff --stat` before committing (`bcb79d9`).

## Still to check

- The etcd snapshot CronJob uses the **node's instance role** through IMDS rather than a role of its own. It
  therefore carries whatever else that role holds — eight Secrets Manager secrets and the ACME TXT record. A
  dedicated IRSA role through the existing issuer would be tighter; not done.
- Restoring to a point *before* the test namespace existed or *after* it. Answered in step 10: the snapshot
  (04:45:03Z) was taken after the canary (04:14:20Z), and the canary came back.
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
- **A job created by the 6-hourly schedule itself.** The first proven run was under the temporary `*/15`
  string. No job from `0 */6 * * *` itself has been observed. M3's teardown removed the job history, so this
  needs a cluster that stays up past a 00/06/12/18 UTC boundary.
- Kyverno at wave -2 becomes a new single point of failure for every rebuild: if it never reports `Healthy`
  and `Synced`, nothing from wave -1 onward syncs. M3 passed with Kyverno at wave -2; its share of the
  10 m 40 s of waves was not separated.
