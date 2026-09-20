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
| Chart's own default plugins | `helm show values jenkins/jenkins --version 5.9.63 \| yq '.controller.installPlugins'` returns exactly the four the values file pins |
| Plugin files on disk after the successful install | 284, including `pipeline-model-definition.jpi` and `workflow-aggregator.jpi` — downloaded, not loaded |
| Plugins this cluster had to raise | `pipeline-model-api:2.2277.v00573e73ddf1`, `workflow-job:1546.v62a_c59c112dd`, `pipeline-stage-step:322.vecffa_99f371c` — the three versions the startup log named. They belong to this resolution, not to the guide: a different set of project-plugin versions produces different numbers |
| Init container log | `java.net.URISyntaxException: Illegal character in path at index 64: https://updates.jenkins.io/download/plugins/pipeline-stage-view/<version>/pipeline-stage-view.hpi` |
| Plugin-load check **after** the three pins were raised | `grep -c "Jenkins is fully up and running"` = **1**, `grep -cE "Failed Loading plugin\|Failed to load:\|Failed to initialize plugin"` = **0** |
| `controller.overwritePlugins` / `overwritePluginsFromImage` in chart 5.9.63 | `false` / `true` |
| Volumes on `jenkins-0` | `jenkins-home` is the **PVC**; `plugins` and `plugin-dir` are **emptyDir**; also `jenkins-config` (configMap), `jenkins-secrets` (projected), `jenkins-cache`, `sc-config-volume`, `tmp-volume` |

### Plugin versions, and the core they need

| Plugin | Version pinned | `requiredCore` |
|---|---|---|
| `credentials-binding` | `728.v902a_273b_8947` | 2.479.3 |
| `job-dsl` | `3732.v9a_c49a_61a_313` | 2.479.3 |
| `pipeline-stage-view` | `2.41` | 2.479.1 |
| `timestamper` | `1.30` | 2.479.3 |

Controller image: **`docker.io/jenkins/jenkins:2.568.3-jdk21`**. The highest requirement among these four is
2.479.3 and the core is 2.568.3, so all four fit with room to spare. The `/stable/` fallback was not needed
*for the core* — it turned out to be needed for a different reason, below.
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

**What this proves.** The controller is past its init container, so the placeholder fix took, and the plugins
**downloaded** — three of them were then refused at startup, which the next block covers, so this log is not
evidence that the plugin set is sound. What it does prove: JCasC applied the `jobs` configScript and
`job-dsl` created `medical-rag` with the right remote; and the controller resolved and reached `github.com` on
443, so step 6's NetworkPolicy egress and DNS work from the `jenkins` namespace. The branch source carries no
`credentialsId` (`deploy/argocd/values/jenkins.yaml`) and the log shows no credential, so the repository is
readable without one.

**Why that build had no stages — answered later.** At the time this was unexplained: `main` held a real
`Jenkinsfile` with an agent and a stage, yet the log went straight from `Start of Pipeline` to `End of
Pipeline`. A second build, from the step-10 `Jenkinsfile` at `59be774`, produced the same shape — plus five
`Did you forget the `def` keyword? WorkflowScript seems to be setting a field named ACCOUNT / REGION / REGISTRY
/ IMAGE / BUILDKIT` lines, which are the direct evidence that the script ran its constants and stopped. The
controller log then gave the cause (elided; the full block also carries a `java.io.IOException: Failed to load:`
line under each `SEVERE`):

```
SEVERE  Failed Loading plugin Pipeline: Declarative Extension Points API v2.2277.v00573e73ddf1
  - Update required: Pipeline: Stage Step (pipeline-stage-step 312.v8cd10304c27a_) to be updated to 322.vecffa_99f371c or higher
  - Update required: Pipeline: Job (workflow-job 1505.vea_4b_20a_4a_495) to be updated to 1546.v62a_c59c112dd or higher
  - Update required: Pipeline: Model API (pipeline-model-api 2.2218.v56d0cda_37c72) to be updated to 2.2277.v00573e73ddf1 or higher
SEVERE  Failed Loading plugin Pipeline: Declarative v2.2218.v56d0cda_37c72 (pipeline-model-definition)
SEVERE  Failed Loading plugin Pipeline v608.v67378e9d3db_1 (workflow-aggregator)
```

`pipeline { … }` is a step that `pipeline-model-definition` provides, and that plugin was refused. What happens
next is **not established.** The obvious reading — the call quietly does nothing — does not survive scrutiny:
calling a step that does not exist in a CPS script reaches `DSL.invokeMethod`, which throws
`No such DSL method 'pipeline' found among steps […]`, and the build ends **FAILURE**, not `SUCCESS`. The five
`WorkflowScript seems to be setting a field named …` lines do not settle it either; workflow-cps emits those at
compile time, so they show the script compiled, not that it ran. A truncated console paste is still a live
candidate. Two cheap reads settle it: grep the same console for `No such DSL method`, and re-read it unelided.
The first build, at `b05409f`, was never checked against the controller's plugin state at all.

**What the log establishes.** The skew is between plugins, not between a plugin and the core: one member of the
Declarative suite, `pipeline-model-extensions`, sits at 2.2277 while `pipeline-model-api` and
`pipeline-model-definition` sit at 2.2218 and `workflow-job` and `pipeline-stage-step` at versions older still.
Nothing pins those last four — they are transitive dependencies of `workflow-aggregator:608`, and
`installLatestPlugins: false` in this project's values makes `jenkins-plugin-cli` install every dependency at
its **minimum** required version. A requester needing a newer `pipeline-model-extensions` raises that one node
and leaves its siblings where they were.

**A competing explanation, not excluded.** The first install crash-looped six times before it succeeded, and
each attempt may have written plugin files to `/var/jenkins_home`, which is a PersistentVolumeClaim that
outlives the pod. The stock controller image copies a reference plugin into that volume only when the file is
**absent**, and `controller.overwritePlugins` is not set in this project's values. A partial older set left
behind then produces exactly this mixture with no resolver misbehaviour at all. Dependency resolution is the
leading hypothesis; this one has not been ruled out, and `kubectl -n jenkins logs jenkins-0 -c init` separates
them.

**What is not established.** *Which* plugin asked for 2.2277 was never measured: the controller log names the
conflict, not the requester. It is likely one of the four this project added, and likely because they came from
the weekly channel, but neither is recorded — the update centre's own dependency table would settle it, and the
init container's log records the resolution. Both are owed (Still to check). Note also that
`workflow-aggregator:608` is where the whole suite comes from, so the chart's own tree is not excluded.

**What this changes.** The `requiredCore` check added earlier is structurally blind to this: it compares each
plugin with the core and never with another plugin. So is every download-time check, because nothing failed to
download. Fixed: step 8 now asserts that the plugins **loaded** — anchored on `Jenkins is fully up and running`,
since the grep passes whenever the evidence is merely absent — the guide reads the four project plugins from the
**stable** channel and says plainly that the channel settles plugin-against-core and not plugin-against-plugin,
step 10 requires two `[Pipeline] stage` lines rather than `Finished: SUCCESS`, and the troubleshooting row fixes the
skew with the versions the log names instead of re-reading a channel. Also measured: the four "chart defaults"
in the values file match `helm show values jenkins/jenkins --version 5.9.63` exactly, so the deviation is not in
those four lines — which does not by itself clear the chart's dependency tree.

**What this changes.** The four `<version>` placeholders were never replaced, and nothing in the step could have
caught it: the values file is valid YAML with them in place and `helm template` renders. The server dry run
never got that far — it failed first on the namespace — but it would not have caught them either. The guide now
greps for leftovers before the push, over every file in the step's table, and `guide.md` carries it as a
standing rule because steps 11 and 13 hand over files the same way (`<tag>`, `<digest>`). A presence test is not
enough on its own, so step 8 now also asks the update centre for each pinned version and expects `200` or `302`,
treating `404` as the failure.

### The second pass, and what the init container's log settled

Raising the three pins the startup log named was enough: the next controller reported `1` and `0`. The init
container's own log then answered two of the three questions this section had left open.

**The resolver does not take the minimum.** It takes the **highest among the minimums its dependents demand**.
Five different parents asked for `workflow-job` at 1385, 1400, 1436, 1472 and 1505, and the installed version
had been 1505 — the largest of them, not the smallest. `pipeline-model-extensions:2.2277` needs **1546**, which
no dependent asks for, so no resolution of this dependency graph could ever reach it. That is the whole cause,
and it means a hand-written pin was the only possible remedy. The guide's earlier wording, "dependencies are
installed at their minimum required version", is true of each edge and misleading about the result.

**The pins take effect, and `overwritePlugins` does not matter here.** With the three lines added, every
affected edge logged
`Skipping dependency workflow-job:<older> … because there is a higher version defined on the top level -
workflow-job:1546.v62a_c59c112dd`, then `Will install new plugin`, `Downloaded … from
https://sg.mirror.servanamanaged.com/…/<the pinned version>/…` and `Checksum valid`. So the worry that
`overwritePlugins: false` would leave a stale `.jpi` in place did not materialise: the plugin directories
`plugins` and `plugin-dir` are **emptyDir**, not the PVC, so they are rebuilt on every pod start. The one read
that would close this beyond doubt — the controller container's own `volumeMounts`, to confirm `plugin-dir` is
mounted over `/var/jenkins_home/plugins` — was not taken.

**Still not measured:** which plugin requires `pipeline-model-extensions` >= 2.2277. The init log records the
resolution, not the requester.

Two lines in that log look like failures and are not: `Couldn't find checksum for <plugin> at version: <v>`
followed by `Setting checksum for: <plugin>`. The update centre's manifest carries checksums for each plugin's
*latest* version only, so a pin that is not latest is fetched separately; `Checksum valid for:` at the end is
the proof it was verified. A third, `<plugin> depends on:` with an empty list, is **not understood**: read
literally it says the transitive dependencies of an explicitly pinned version are not expanded, which would be
a latent hazard. It was harmless here, because the load check returned `0`.

## Step 9 — The build pod's identity

Run out of order. The step was skipped during Part 2, and was come back to after step 10's first real build
hung; `main` kept step 10's `Jenkinsfile` and step 9 ran on the branch `jenkins/step-9`, so `main` was never
moved backwards.

| Check | Result |
|---|---|
| `aws --version` on the workstation, for the image tag | `2.36.46` |
| `aws sts get-caller-identity` inside the build pod | `arn:aws:sts::242834061265:assumed-role/medical-rag-ci/botocore-session-1789907489`, account `242834061265` |
| `curl -sS -m 3 http://169.254.169.254/latest/meta-data/` | `curl: (28) Connection timed out after 3002 milliseconds`, then `IMDS unreachable, exit=28` |

**What this proves,** and nothing before it did: a build pod reaches AWS as `medical-rag-ci` and not as the node
role, so step 3's trust policy, the projected `sts.amazonaws.com` token and the `AWS_*` variables work together;
and the egress rule that excepts `169.254.169.254/32` holds, so a build cannot borrow the node's identity even
by accident. Every step from 11 onwards assumed both.

**The first attempt failed**, on a defect in the guide:

```
+ aws sts get-caller-identity
aws: [ERROR]: [Errno 13] Permission denied: '/.aws'
```

The pod forces `runAsUser: 1000`; the `aws-cli` image's default user is root with `HOME=/root`, and uid 1000 has
no `/etc/passwd` entry, so `HOME` falls back to `/` and the CLI cannot create `/.aws`. The app guide's own IRSA
proof pods set `HOME=/tmp` for exactly this reason and say so in prose — *"plus `HOME`, so the CLI has a
writable cache"* — while the Jenkins guide copied four of the five variables and its comment asserts "the same
four variables the app's pods use". Fixed in the `Jenkinsfile`; the guide's step 9 still carries the
four-variable block.

## Step 10 — Partial

| Check | Result |
|---|---|
| Build #6 on `main`, whose commit touched only `deploy/` | `ERROR: Nothing to build: author=biabeogo147, only docs or deploy files changed`, `Finished: NOT_BUILT` |
| Build pod lifecycle, from the controller log | `provisioning successfully completed` 12:15:10 → `Created Pod` 12:15:12 → `Pod is running` 12:15:29 → `Terminating` 12:15:40 |
| Image pulls, from the namespace's events | `moby/buildkit:v0.33.0-rootless` 123 MB in 6.6 s; `jenkins/inbound-agent:3391.va_37fa_a_305d6d-1-jdk25` 225 MB in 9.4 s |
| The Kubernetes cloud the chart writes | `name: "kubernetes"`, `namespace: "jenkins-agents"`, `containerCapStr: "1"`, `jenkinsTunnel: "jenkins-agent.jenkins.svc.cluster.local:50000"`, `waitForPodSec: "600"` |

**The skip guard works**, which is the second half of step 10's check and is now owed no longer. **The cloud
exists despite `agent.enabled: false`** — the guide asserted this and it had never been read; `agent.enabled`
suppresses the default pod template, not the cloud.

**Still owed:** a build that passes the skip guard and runs both stages — two `[Pipeline] stage` lines, BuildKit's
`DONE` lines and `26 passed` — and the three `promq` readings of what the build pod asked for.

**One thing the guide does not warn about.** Between `[Pipeline] node` and the pod being ready, Jenkins prints
`Still waiting to schedule task` and `Waiting for next available executor`. Here that gap was 19 seconds, spent
pulling 348 MB of images, and it was read as a failure. It is ordinary queue output; the plugin waits
`waitForPodSec: 600` before giving up.

## Problems found and fixed

**Part 2.** Five. Four are purely defects in the guide; the first also had a real cause in the account — the
AWS secret was genuinely empty — and the guide's defect was having no check for it. In two shapes. **Three were
checks that passed while the thing they guarded was broken:** the empty secret, the uncompiled policy, the
unfilled placeholder. **Two failed loudly but pointed away from the cause:** `jq: Invalid numeric literal` for a
307 redirect, and a namespace mismatch for a values change made three steps earlier. A sixth of the first shape
appears in Part 3 below, and it is the rule that was written to fix the third.

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

**Part 3 so far.** Four, all defects in the guide, none in the cluster.

6. **Rule 5's grep cannot see half the placeholders it was written for.** `grep -n '<[A-Za-z][A-Za-z0-9_-]*>'`
   has no space in its character class, so `<aws-cli version>` — the next placeholder the guide hands over
   after the four `<version>` strings that caused defect 3 — passes it silently. The rule was added *because*
   of defect 3 and could not catch the very next instance. It was found by reading the file, not by the check.
   The character class needs a space: `'<[A-Za-z][A-Za-z0-9_ -]*>'`. **This is the fourth check in this phase
   that passed while the thing it guarded was broken**, and the only one that was introduced as the fix for an
   earlier member of the same family.
7. **Step 9's pod has no writable `HOME`.** The block carries four `AWS_*` variables and a comment claiming
   they are "the same four variables the app's pods use"; the app's pods carry five, and the fifth, `HOME=/tmp`,
   is the one that makes the CLI work under `runAsUser: 1000`. The build failed with `[Errno 13] Permission
   denied: '/.aws'`. This one failed loudly and named its own cause, so it cost one build, not a diagnosis.
8. **Step 10 does not say that waiting is normal.** `Still waiting to schedule task` and `Waiting for next
   available executor` are printed while the pod is being created, and step 10's Check lists neither in its
   expected output nor in any failure branch; `troubleshooting.md` has no row for it. A 19-second image pull was
   read as a hung build, and the diagnosis that followed — that the Kubernetes cloud might not exist — was
   wrong, and was only disproved by four extra reads.
9. **Step 10 does not state that it depends on step 9.** Step 9 is what proves a build pod can start at all and
   carries the CI role; step 10's `Jenkinsfile` deliberately drops the `cloud 'kubernetes'` and
   `namespace 'jenkins-agents'` lines *because* step 9 has already proved them. Skipping step 9 therefore turns
   a loud error into a silent queue, and step 10 has no "Before you start" line saying so, unlike the Parts.

**Part 1.** None: every check of Part 1 behaved as the guide expected, except the two shell mistakes in the guide
itself (an unset variable in the Ansible command, and one in step 2's gate), which were fixed in the guide.

## Still to check

- **A build that runs both of step 10's stages:** two `[Pipeline] stage` lines, BuildKit's `DONE` lines and
  `26 passed`. Step 9's single stage ran, and step 10's skip guard ran, so the Declarative suite is working;
  what has never happened in this phase is a build that reaches the `Test` stage.
- **The three `promq` readings** of what the build pod asked for (step 10), and which of the step's three
  no-output cases applies if they come back empty.
- **Which plugin requires `pipeline-model-extensions` >= 2.2277.** The init container's log records the
  resolution but never names the requester, so this is still open; the update centre's dependency table is the
  remaining read. It no longer blocks anything — the remedy is measured to work either way.
- **What a build does when `pipeline { … }` is unavailable.** A missing CPS step normally throws
  `No such DSL method` and fails the build, so `Finished: SUCCESS` with no stages is still unexplained. The
  console was re-read unelided and contains no such string: `Start of Pipeline`, five `def` warnings, `End of
  Pipeline`. The mechanism remains unknown, and is now unreproducible on this controller.
- **Whether `<plugin> depends on:` with an empty list means transitive dependencies of a pinned version go
  unresolved.** If it does, every hand-written pin is a latent hazard. It was harmless in this install.
- **Whether `plugin-dir` is mounted over `/var/jenkins_home/plugins`** in the controller container. The pins
  demonstrably took effect, so nothing waits on this; it would turn "the plugin directory is an emptyDir" from
  a strong inference into a measurement. One read: the controller container's `volumeMounts`.
- **Whether step 11's `tools` container sets `HOME`.** It runs `aws` under the same uid as step 9's pod, which
  failed without it. Read before reaching step 11, not during.
- **Step 7's gate outputs:** `metadata.generation`, `status.observedGeneration` and `status.typeChecking`. The
  gate did not exist when the step was run, so none were taken.
- **Step 8's remaining `Record` items:** the wait's duration, a `jenkins-0 2/2 Running` line, and that
  `https://jenkins.recruitai.io.vn` opened **only** with WireGuard and the admin password logged in. The two
  plugin-load numbers are now recorded; these three are not.
- **A successful pre-flight dry run.** The only one recorded failed on the namespace; the corrected form
  (render to a file, apply without `-n`, every line ending in `(server dry run)`) has not been run.
- **DNS from the two namespaces.** Step 6's "Proven by" claims DNS still works while IMDS is blocked, but the
  IMDS test uses a literal address and proves nothing about DNS.

- `jenkins-github` `Ready=True` and the Secret carrying the key `token` (step 6). No build so far has used a
  credential — step 9's checked an AWS role, not GitHub — so nothing says whether JCasC resolved the
  placeholder. If it did not, the credential is the literal string `${jenkins-github-token}` and step 16 will
  fail. Note that the repository is public, so cloning proves nothing about the token either.
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
