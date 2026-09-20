# Jenkins phase — 2026-09-20

Part 1: the measurements that decide how the pipeline is built, and the foundations it needs — the ECR clean-up
rule, the build pods' AWS role, and the name Jenkins will answer on. Part 2: the namespaces, credentials and
admission rules Jenkins runs inside. AWS account `<account-id>`, region `ap-southeast-1`.
Every command ran on the ops workstation. Checks not listed here returned the output the guide expects.

## Results of Part 1

| Question | Answer |
|---|---|
| How many fixable vulnerabilities does Trivy find in the image prod runs? | **None at CRITICAL or HIGH**: 5 and 55 findings, none with a patch. Five MEDIUM and one LOW do have one. The pipeline's gate, which looks only at fixable CRITICAL findings, passes today |
| How much CPU can the nodes still promise, with the platform and both app environments running? | **560m, 775m and 720m**, and roughly 5.2–5.9 GiB of memory. These are requests not yet promised, not idle capacity: there is no metrics-server |
| Does rootless BuildKit run on these nodes? | **Yes**, with `Unconfined` seccomp and AppArmor, although Ubuntu's user-namespace restriction is on |

## Step 1 — Measurements

### 1.1 Trivy on the image prod runs

Image `medical-rag:1eaa43bf3512@sha256:c10cd57e…6769`, Trivy 0.74.0, `--scanners vuln`:

| Severity | Total | Fixable |
|---|---|---|
| CRITICAL | 5 | **0** |
| HIGH | 55 | 0 |
| MEDIUM | 105 | 5 |
| LOW | 103 | 1 |

The five CRITICAL findings, none of which Debian has patched:

| CVE | Package | Installed | Status |
|---|---|---|---|
| CVE-2025-7458 | `libsqlite3-0` | 3.40.1-2+deb12u2 | affected |
| CVE-2026-13221 | `perl-base` | 5.36.0-7+deb12u3 | affected |
| CVE-2026-42496 | `perl-base` | 5.36.0-7+deb12u3 | fix_deferred |
| CVE-2026-8376 | `perl-base` | 5.36.0-7+deb12u3 | affected |
| CVE-2023-45853 | `zlib1g` | 1:1.2.13.dfsg-1 | will_not_fix |

The pipeline's gate, `--severity CRITICAL --ignore-unfixed --exit-code 1`, returned **`gate exit=0`**.

**What this changes.** The gate will not stop the first pipeline run: every CRITICAL finding is unfixed, and the
gate deliberately ignores those. The hardening step is therefore about *reducing the counts*, not about unblocking
the pipeline.

**Trivy and ECR do not agree**, as expected from two different databases: ECR's scanner reported 4 CRITICAL and
14 HIGH for this image ([app.md](app.md)), Trivy 5 and 55, and 8 MEDIUM against 105. The two CRITICAL lists share
exactly one CVE (`CVE-2026-13221` in `perl`). Neither is "right": they cover different package sets and rank
differently. From now on the "before" and "after" of criterion #9 both come from Trivy 0.74.0, and the numbers in
`app.md` stay as the ECR scan they were.

Trivy scanned the image by tag; step 2 then confirmed that this tag and prod's values point at the same digest.

### 1.2 Free room on the nodes

Taken with every Application `Synced` and `Healthy` and the three app pods running (one dev, two prod). The
command prints requests and limits, not the allocatable totals: CPU allocatable is 2000m per node, and memory
allocatable is **inferred** at about 7.8 GiB from the requests and their percentages. The "free" columns are
therefore approximate, and they mean "not yet promised to a pod".

| Node | CPU requests | CPU free | Memory requests | Memory limits | Memory free |
|---|---|---|---|---|---|
| `medical-rag-node-1` | 1440m (72%) | 560m | 2508Mi (32%) | 3224Mi (41%) | ≈5330Mi |
| `medical-rag-node-2` | 1225m (61%) | 775m | 2060Mi (26%) | 5056Mi (65%) | ≈5778Mi |
| `medical-rag-node-3` | 1280m (64%) | 720m | 1816Mi (23%) | 4276Mi (55%) | ≈6022Mi |

CPU limits are set on almost nothing: only node 1 carries 500m of them.

The numbers agree with the app phase: 1440 + 1225 + 1280 = 3945m, which is the 3795m recorded in
[app.md](app.md) plus the three app pods' 50m each.

**What this changes.** A pod runs on one node, so the budget is one node's gap, not their sum. The Jenkins
controller asks for about 250m and one build pod for at least 400m: each fits the smallest gap, 560m, and the two
together fit only on different nodes. Part 2 sizes them inside these gaps.

### 1.3 The AppArmor setting of the nodes

`kernel.apparmor_restrict_unprivileged_userns` is **`1` on all three nodes**: Ubuntu's restriction on user
namespaces is on.

### 1.4 A rootless BuildKit build

The Job from the guide (BuildKit v0.33.0 rootless, `Unconfined` seccomp and AppArmor,
`--oci-worker-no-process-sandbox`, requests 300m and 1Gi) **succeeded**:

- `condition met`, `succeeded=1 failed=`;
- it was scheduled on `medical-rag-node-1`, the node with the least free CPU. The pod was 18 s old when it was
  listed, so scheduling, both image pulls and the build together took at most that; the build step itself logged
  `DONE 0.1s`;
- the log shows `#5 [2/2] RUN echo built-by-rootless-buildkit` then `#5 DONE 0.1s`.

**What this changes.** Two decisions:
- **Step 5 is not needed.** Ubuntu's restriction is on, yet this build worked with `Unconfined` profiles and
  `--oci-worker-no-process-sandbox`, which is the flag that lets BuildKit skip the extra process sandbox a
  container cannot create. So no AppArmor profile has to be installed on the nodes for builds of this shape.
- **The build pods' namespace must be at Pod Security level `privileged`,** because `baseline` refuses
  `Unconfined`. Step 7's ValidatingAdmissionPolicy is therefore required, not optional. Running at `baseline` would
  mean installing named profiles on the nodes, which this result says is not necessary for the build to work.

A pod requesting 300m and 1Gi was scheduled on the busiest node, so a build pod of that size fits while everything
else runs. The build pod of Part 3 declares more: 300m for `buildkit`, 50m for `tools` and 50m for `trivy`, plus
whatever the Kubernetes plugin's own `jnlp` container asks for, which is not decided here. Step 10 reads the total
from the running pod; it has to stay under the smallest gap, 560m.

The `buildkit-probe` namespace was deleted afterwards.

## Step 2 — ECR keeps the images prod may run

| Check | Result |
|---|---|
| Images in the repository | 1 |
| Lifecycle policy after the change | `[{"rulePriority":1,"tags":["release-*"],"keep":10},{"rulePriority":2,"tags":["*"],"keep":30}]` |
| Re-tagging prod's image | `put-image` returned `sha256:c10cd57e…6769` |
| The image now | Digest `sha256:c10cd57e…6769`, tags `release-1eaa43bf3512,1eaa43bf3512` |
| Prod's values | `1eaa43bf3512@sha256:c10cd57e…6769`: the same digest |

With one image in the repository, no rule can expire anything yet. The protection itself is proven in step 19,
with a lifecycle preview once the pipeline has pushed enough images.

## Step 3 — The build pods' AWS role

`medical-rag-ci` was created with its policy. The plan line and the trust policy matched the guide's expected
output and were not kept; the simulator results below were.

IAM's policy simulator, on the role itself:

| Action | Resource | Decision |
|---|---|---|
| `ecr:PutImage` | the `medical-rag` repository | allowed |
| `kms:Sign` | `alias/medical-rag-cosign` | allowed |
| `s3:GetObject` | `corpus/any.pdf` | allowed |
| `s3:PutObject` | `corpus/any.pdf` | implicitDeny |
| `s3:GetObject` | `faiss/any` | implicitDeny |
| `secretsmanager:GetSecretValue` | `medical-rag/github` | implicitDeny |

So a build can push an image, ask for a signature and read the corpus checksum, and nothing else. The node role
still holds ECR push and KMS sign as well; step 18 removes them.

## Step 4 — The name for Jenkins

`jenkins` added to `internal_ui_hosts`. Every output matched the guide's expected output and was not kept: the
plan's single addition, the two `getent` lines resolving to the same addresses as `argocd.recruitai.io.vn`, and the
`404` through the VPN with the wildcard certificate.

## Step 5

Not needed: the BuildKit test of 1.4 succeeded on these nodes.

## What Part 1's measurements decided

| Decision | Because |
|---|---|
| The build pods' namespace is `privileged`, with a ValidatingAdmissionPolicy | BuildKit needs `Unconfined` seccomp and AppArmor, which `baseline` refuses (1.4) |
| No Ansible change to the nodes | The build worked with Ubuntu's restriction on (1.3, 1.4) |
| Build pod requests at least 400m CPU, controller around 250m | Each pod must fit the smallest gap, 560m, because a pod runs on one node (1.2). The build pod's exact total includes the plugin's `jnlp` container and is read in Part 3, step 10 |
| The hardening step aims at fewer findings, not at unblocking the gate | No CRITICAL finding has a fix today (1.1) |

## Step 6 — Namespaces, credentials and network rules

| Check | Result |
|---|---|
| ExternalSecrets in `jenkins` | `jenkins-admin` `SecretSynced True`; `jenkins-github` **`SecretSyncedError False`** on the first try |
| Secrets | `jenkins-admin jenkins-admin-password,jenkins-admin-user`; `jenkins-github` **not found** |
| Namespace enforce levels | `jenkins baseline`, `jenkins-agents privileged` |
| IMDS from a throwaway pod, both namespaces | `wget: download timed out`, `exit=1` in `jenkins` and in `jenkins-agents` |

The IMDS pod raised `Warning: would violate PodSecurity "restricted:latest"` in `jenkins` only — the loop runs
`jenkins` first, and the warning precedes its `pod/imds-test created`. Read the other way round, those two
outputs *are* the measurement of the `warn` labels, which the check's own jsonpath does not print (it reads
`enforce` only): `jenkins` warns at `restricted`, and `jenkins-agents` does not, which matches
`namespaces.yaml`. A plain busybox pod violates `restricted` on exactly the four fields named and satisfies
`baseline`, so silence in `jenkins-agents` is the expected result, not a missing check.

**What this changes.** `medical-rag/github` had no value: Terraform creates it empty, and the app phase never
used it. The value was then stored with `put-secret-value`; **the re-sync has not been recorded yet** (Still to
check). Step 6 now checks the secret has a version and a `token` key *before* the ExternalSecret is written,
Nothing in Part 1 had looked at the secret's **contents**: step 3 simulated a different principal, the CI role,
and returned `implicitDeny` for this very ARN — by design, because the ExternalSecret reads it through the node
role. That result says nothing either way about whether there is a value to read.

## Step 7 — Narrow what the build namespace accepts

| Check | Result |
|---|---|
| `hostPath` pod, first attempt | **Accepted** — `Warning: would violate PodSecurity "baseline:latest": hostPath volumes (volume "host")`, then `pod/policy-test created (server dry run)`. A warning from the namespace's `warn` label, not a refusal |
| `hostPath` pod, same manifest re-run later | Refused: `ValidatingAdmissionPolicy 'jenkins-agents-restrictions' with binding 'jenkins-agents-restrictions' denied request: hostPath volumes are not allowed in jenkins-agents` |
| Policy and binding | Present, 7 validations, `validationActions: ["Deny"]`, selector matches `kubernetes.io/metadata.name: jenkins-agents` |
| `jenkins-platform` | `Synced` `Healthy` at `cf5f8aa`, the commit that added the policy |
| A build-pod-shaped pod, accepted | `pod/policy-test created (server dry run)` with `Warning: would violate PodSecurity "baseline:latest": forbidden AppArmor profile …, seccompProfile …` |

The warning on the accepted pod names `baseline`, which is `jenkins-agents`' **warn** label; the namespace
enforces `privileged`, so `Unconfined` is admitted. That is the relaxation this namespace exists to allow, and
the policy of step 7 is what takes back everything else.

**What this changes.** Nothing was edited between the two attempts: the reads above were taken *between* them
and showed the policy, its seven validations, the binding's `Deny` and a matching selector already in place, with
the Application `Synced` at the commit that added them. The only variable was elapsed time. The explanation that the first
attempt ran before the API server had compiled the policy is therefore **inferred, not measured**:
`observedGeneration` was never read. It is the most likely reading of the two attempts, and the gate now exists
so that the next run measures it instead of inferring it. The guide's checks could not distinguish "loaded" from "listed", and an
accepted pod is exactly what a pass looks like. Step 7 now waits until `status.observedGeneration` equals
`metadata.generation` before any dry run, and tests one pod per expression shape instead of only the volume
shape. That exercises all three shapes and three of the seven rules; `hostPID`, `hostIPC`, `capabilities.add`
and `hostPort` still get no pod of their own, which is a deliberate trade rather than full coverage.

## Step 8 — Jenkins itself

| Check | Result |
|---|---|
| What the chart renders | **16 objects, two namespaces**: 14 in `jenkins`, plus `Role` and `RoleBinding` `jenkins-schedule-agents` in `jenkins-agents`. Nothing cluster-scoped |
| `helm template … \| kubectl apply -n jenkins` | Failed: *the namespace from the provided object "jenkins-agents" does not match the namespace "jenkins"* |
| Plugin versions read from `/current/` | `job-dsl:3732.v9a_c49a_61a_313`, `credentials-binding:728.v902a_273b_8947`, `pipeline-stage-view:2.41`, `timestamper:1.30` |
| First install | `jenkins-0` `Init:CrashLoopBackOff`, init container `init` exit 1 after 6 restarts |
| Init container log | `java.net.URISyntaxException: Illegal character in path at index 64: https://updates.jenkins.io/download/plugins/pipeline-stage-view/<version>/pipeline-stage-view.hpi` |

### Plugin versions, and the core they need

| Plugin | Version pinned | `requiredCore` |
|---|---|---|
| `credentials-binding` | `728.v902a_273b_8947` | 2.479.3 |
| `job-dsl` | `3732.v9a_c49a_61a_313` | 2.479.3 |
| `pipeline-stage-view` | `2.41` | 2.479.1 |
| `timestamper` | `1.30` | 2.479.3 |

Controller image: **`docker.io/jenkins/jenkins:2.568.3-jdk21`**. The highest requirement among these four is
2.479.3 and the core is 2.568.3, so all four fit with room to spare, and the `/stable/` fallback was not needed.
Two limits on that conclusion: the four plugins the chart pins by default were not checked; and these
`requiredCore` values are the ones the update centre publishes for each plugin's *latest* version, which here
happens to be the version pinned, so the comparison is exact rather than an upper bound.

All **eight** pinned versions exist in the update centre: each
`https://updates.jenkins.io/download/plugins/<name>/<version>/<name>.hpi` answered `302`, a redirect to a
mirror. The request was `curl -I` without `-L`, so this shows the path is not a `404`; the `.hpi` files
themselves were not fetched.

### The Multibranch job reaches GitHub

```
Seen branch in repository origin/main
Seen 1 remote branch
Obtained Jenkinsfile from b05409f7636d4dd5e287114205cb149fba528d9f
[Pipeline] Start of Pipeline
[Pipeline] End of Pipeline
Finished: SUCCESS
```

**What this proves,** and it is the strongest evidence in this section that step 8 worked: the controller is past
its init container, so the plugin fix took; the plugins installed; JCasC applied the `jobs` configScript and
`job-dsl` created `medical-rag` with the right remote; and the controller resolved and reached `github.com` on
443, so step 6's NetworkPolicy egress and DNS work from the `jenkins` namespace. The branch source carries no
`credentialsId` (`deploy/argocd/values/jenkins.yaml`) and the log shows no credential, so the repository is
readable without one.

**What is not established.** `main` at `b05409f` holds step 9's identity-test `Jenkinsfile`, not an empty one,
and that file still carries the unfilled placeholder `public.ecr.aws/aws-cli/aws-cli:<aws-cli version>`. A
pipeline with an `agent { kubernetes … }` block and a `stage('Who am I')` cannot produce `Start of Pipeline` →
`End of Pipeline` with no stage lines, and an unresolvable image should have failed pod creation rather than
succeeded. Either the pasted console was truncated or something else ran. Why that build reported `SUCCESS` is
**not known** (Still to check).

**What this changes.** The four `<version>` placeholders were never replaced, and nothing in the step could have
caught it: the values file is valid YAML with them in place and `helm template` renders. The server dry run
never got that far — it failed first on the namespace — but it would not have caught them either. The guide now
greps for leftovers before the push, over every file in the step's table, and `guide.md` carries it as a
standing rule because steps 11 and 13 hand over files the same way (`<tag>`, `<digest>`). A presence test is not
enough on its own, so step 8 now also asks the update centre for each pinned version and expects `200` or `302`,
treating `404` as the failure.

## Problems found and fixed

**Part 2.** Five. Four are purely defects in the guide; the first also had a real cause in the account — the
AWS secret was genuinely empty — and the guide's defect was having no check for it. In two shapes. **Three were
checks that passed while the thing they guarded was broken:** the empty secret, the uncompiled policy, the
unfilled placeholder. **Two failed loudly but pointed away from the cause:** `jq: Invalid numeric literal` for a
307 redirect, and a namespace mismatch for a values change made three steps earlier.

1. **`medical-rag/github` was empty.** The guide assumed the value was already there — `0-concepts.md` said "You
   put it there once" and the runbook carried the command, but no step in this phase checked it, and Part 1's
   permission simulation looked at a different principal and returned `implicitDeny` for this ARN, so it could
   not have told you either way. Fixed: a pre-check at the top of step 6, a troubleshooting
   row with the literal `SecretSyncedError`, and the token's required permissions written into concepts §14,
   which previously said what to store and not what it needed to be allowed to do.
2. **Step 7's check could not fail.** The dangerous pod was admitted on the first attempt and refused on a
   re-run with nothing changed in between; the explanation — that the API server had not yet compiled the
   ValidatingAdmissionPolicy — is inferred, because `observedGeneration` was never read. Either way the guide
   had no gate that could tell "listed" from "enforcing". The step's
   second test — the *accepted* pod — is worse: on its own it cannot tell "the policy allows this" from "there is
   no policy". Fixed: a compile gate on `observedGeneration`, three refusals covering the three expression
   shapes, and the accept moved last with a sentence saying why its order matters.
3. **Nothing caught an unfilled placeholder.** `deploy/argocd/values/jenkins.yaml` went to `main` with four
   literal `<version>` strings. The init container's plugin installer then built
   `…/pipeline-stage-view/<version>/pipeline-stage-view.hpi` — the log quotes a `java.net.URISyntaxException`
   and names no tool — and crash-looped. The step's
   pre-flight could not catch it — a placeholder is valid YAML — which is presence without content. Fixed: a
   `grep -c '<version>'` gate that must print `0`, a standing rule in `guide.md` covering every step that hands
   over a file to fill in, and two troubleshooting rows.
4. **The pre-flight forced one namespace.** Since the Kubernetes cloud moved to `agent.namespace`, the chart
   renders a Role and RoleBinding into `jenkins-agents`, and `kubectl apply -n jenkins` refuses them. The fix
   that moved the cloud did not reach the command that checks it. Fixed: render to a file, apply without `-n`,
   and assert the set of namespaces the chart renders into rather than assuming one.
5. **Step 8's plugin-version command used `curl -s`.** Measured with
   `curl -sS -o /tmp/uc.json -w 'http=%{http_code} size=%{size_download} redirect=%{redirect_url}'`:
   `http=307 size=318 redirect=https://mirrors.updates.jenkins.io/current/update-center.actual.json`. So `curl`
   returned a 318-byte HTML redirect page and `jq` failed with
   `parse error: Invalid numeric literal at line 1, column 10` — index 10 of `<!DOCTYPE HTML PUBLIC …`, a
   message that says nothing about redirects.
   Fixed: `curl -fsSL`, a line count that must be four, and a troubleshooting row with the literal error.

**Part 1.** None: every check of Part 1 behaved as the guide expected, except the two shell mistakes in the guide
itself (an unset variable in the Ansible command, and one in step 2's gate), which were fixed in the guide.

## Still to check

- **Why the `main` build reported `SUCCESS` with no stage lines.** `main` at `b05409f` holds step 9's
  identity-test `Jenkinsfile`, which has a `kubernetes` agent and one stage, and whose image tag is still the
  unfilled `public.ecr.aws/aws-cli/aws-cli:<aws-cli version>`. That file should not produce an empty pipeline,
  and an unresolvable image should fail pod creation. Step 9's own `Record` — both build results — is still
  owed, and this has to be resolved before it.
- **Step 7's gate outputs:** `metadata.generation`, `status.observedGeneration` and `status.typeChecking`. The
  gate did not exist when the step was run, so none were taken.
- **Step 8's remaining `Record` items:** the wait's duration, a `jenkins-0 2/2 Running` line, and that
  `https://jenkins.recruitai.io.vn` opened **only** with WireGuard and the admin password logged in. Nothing in
  this file yet records that Jenkins is running after the fix, only that its job scanned GitHub.
- **A successful pre-flight dry run.** The only one recorded failed on the namespace; the corrected form
  (render to a file, apply without `-n`, every line ending in `(server dry run)`) has not been run.
- **DNS from the two namespaces.** Step 6's "Proven by" claims DNS still works while IMDS is blocked, but the
  IMDS test uses a literal address and proves nothing about DNS.

- `jenkins-github` `Ready=True` and the Secret carrying the key `token` (step 6). The Jenkins build above used
  no credential, so it says nothing about whether JCasC resolved the placeholder — if it did not, the credential
  is the literal string `${jenkins-github-token}` and step 16 will fail.
- The `hostNetwork` and `privileged` refusals (step 7). Only the `hostPath` refusal and the accept were run, so
  **six** of the policy's seven rules are still unexercised.
- The rest of step 8's post-sync checks: admin password length, the PVC on `gp3`, the StorageClass reclaim
  policy, and two Roles plus two RoleBindings in `jenkins-agents`.
- Whether `main` carries a ruleset. The anonymous clone shows the repository is readable without a credential,
  but nothing yet shows a direct push to `main` is allowed, which step 16 depends on.

- The stage durations and the commit-to-Ready time of criterion #8 (step 16).
- Trivy counts of the hardened image, as the "after" of criterion #9 (step 13).
- `cosign verify` on an image the pipeline signed, and the failure on the unsigned one (step 14).
- The node role's `AccessDenied` on push and sign, and the green build after it (step 18).
- The rebuild timings, and the release that runs after the rebuild (step 19).
- The lifecycle preview once more than 30 images exist, and the repository's size and untagged count (step 19).
- The build pod's real CPU and memory, from Prometheus (Part 3).
