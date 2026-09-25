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

## Step 10 — Only build what should be built, and test it first

| Check | Result |
|---|---|
| Build #6 on `main`, whose commit touched only `deploy/` | `ERROR: Nothing to build: author=biabeogo147, only docs or deploy files changed`, `Finished: NOT_BUILT` |
| Build pod lifecycle, from the controller log | `provisioning successfully completed` 12:15:10 → `Created Pod` 12:15:12 → `Pod is running` 12:15:29 → `Terminating` 12:15:40 |
| Image pulls, from the namespace's events | `moby/buildkit:v0.33.0-rootless` 123 MB in 6.6 s; `jenkins/inbound-agent:3391.va_37fa_a_305d6d-1-jdk25` 225 MB in 9.4 s |
| The Kubernetes cloud the chart writes | `name: "kubernetes"`, `namespace: "jenkins-agents"`, `containerCapStr: "1"`, `jenkinsTunnel: "jenkins-agent.jenkins.svc.cluster.local:50000"`, `waitForPodSec: "600"` |

**The skip guard works**, which is the second half of step 10's check and is now owed no longer. **The cloud
exists despite `agent.enabled: false`** — the guide asserted this and it had never been read; `agent.enabled`
suppresses the default pod template, not the cloud.

**Build #11 closed the step.** The commit touched `Makefile` only, which is outside `deploy/`, `docs/` and
`*.md`, so the skip guard let it through without a contrived change to the `Jenkinsfile`.

| Check | Result |
|---|---|
| `[Pipeline] stage` lines | **three**, not the two the guide predicts: `Declarative: Checkout SCM`, `Skip guard`, `Test` |
| ruff | `All checks passed!` |
| pytest | `26 passed, 1 warning in 1.57s` |
| `Test` stage duration | 20:00:25 → 20:00:57, about 32 s, with no layer cache |
| Result | `Finished: SUCCESS` |
| Build pod's CPU requests, read from Prometheus after the pod was deleted | `buildkit` **0.3**, `jnlp` **0.1**, pod total **0.4** — identical across builds 7 to 12, because requests do not vary with what a build does |
| Step 9's pod, for comparison | `tools` **0.05**, `jnlp` **0.1**, total **0.15** |

The metric is in cores: 0.4 is 400m. Step 1.2 predicted this exactly — *"one build pod for at least 400m"* —
and the pod landed on `medical-rag-node-2`, which had 775m free. The `jnlp` container the plugin adds does
carry requests of its own, 100m, which step 10's Why left open.

**The `Test` stage prints an `ERROR` and is still correct.**

```
#6 importing cache manifest from 242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:buildcache
#6 ERROR: failed to configure registry cache importer: unexpected status from HEAD request to
   https://242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/v2/medical-rag/manifests/buildcache: 401 Unauthorized
```

`--import-cache type=registry,…` needs a registry login, and this stage deliberately has none — that is the
step's own security argument. So the flag cannot work where it is written, in this build or any other: the
`Log in to ECR` stage comes after `Test`. BuildKit treats a failed cache import as non-fatal and builds from
scratch, which is why the step passes. Two things follow: the cache line is dead as placed, and the guide's
expected output does not mention the `ERROR`, so a reader following it exactly would stop here.

**One thing the guide does not warn about.** Between `[Pipeline] node` and the pod being ready, Jenkins prints
`Still waiting to schedule task` and `Waiting for next available executor`. Here that gap was 19 seconds, spent
pulling 348 MB of images, and it was read as a failure. It is ordinary queue output; the plugin waits
`waitForPodSec: 600` before giving up.

## Step 11 — The tools image, and the app image

Run on `main` rather than the temporary branch the step asks for, so `BRANCH_NAME = main` and the build both
imported and **exported** the cache on its first run.

| Check | Result |
|---|---|
| Alpine base, pinned by index digest | `alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8` |
| Tools image | `medical-rag-ci:2ed703f3a494@sha256:106f85c5a76dcd1847e1c8e20ece5933f7b733cabbe4e9d93f64b2f431e6b38f` |
| `Log in to ECR` identity | `arn:aws:sts::242834061265:assumed-role/medical-rag-ci/botocore-session-1789910509` |
| App image, from the log | `medical-rag:9022e3828864@sha256:9e67e4d1a1ffdcc7953caa2d3d1932f07494385aab498a6e3e500eabddd29a2b` |
| The same image, from `aws ecr describe-images` | `sha256:9e67e4d1a1ffdcc7953caa2d3d1932f07494385aab498a6e3e500eabddd29a2b`, pushed `2026-09-20T13:22:18Z` — **identical** |
| `Test` stage | 20:21:15 → 20:21:47, about 32 s, `All checks passed!` and `26 passed` |
| `Build and push` stage | 20:21:50 → 20:22:34, about 44 s, with the cache empty |
| Cache on this run | import failed with `…/medical-rag:buildcache: not found`, then `writing cache image manifest sha256:34aa4d37977b44fa2bab80855a88550d2e2ba32dadce1b075c76eee5d7247472` — the first build is the one that creates it |
| Pod | three containers now: `buildkit` 300m, `tools` 50m, `jnlp` 100m — **450m**, up from 400m |

**What this proves.** The digest in the log and the digest in ECR are the same string, which is the check that
matters: step 14 signs a digest, and a tag could be overwritten between the push and the signature. The tools
image pulled without a node-role change beyond the one added for defect 13, and the CI role reached STS from
inside the `tools` container.

**The ECR token was printed into the build log in full.**

```
+ PASS='eyJwYXlsb2FkIjoi…'
+ AUTH='QVdTOmV5SndZWGxzYjJGa0lqb2l…'
```

Jenkins runs every `sh` step as `/bin/sh -xe`, so each command is echoed with its variables already expanded.
The authorization token is valid for 12 hours and grants push and pull across the registry. Nothing in the
guide mentions this; its only sentence about masking (`3-pipeline.md:914`) is about `withCredentials`, a
different mechanism used three steps later. Fixed in the `Jenkinsfile` with `set +x` at the top of that block;
the guide still carries the version that leaks.

**Build 16 confirmed the fix and measured the cache.** Same shape, `set +x` in place:

| Check | Build 14 (cache empty) | Build 16 (cache present) |
|---|---|---|
| `Log in to ECR` output | `+ PASS='eyJwYXlsb2FkIjoi…'`, `+ AUTH='QVdTOmV5…'`, then the ARN | `+ set +x` then the ARN, **nothing else** |
| Cache import | `…:buildcache: not found` | `inferred cache manifest type: application/vnd.oci.image.manifest.v1+json done` in 0.2 s |
| `Build and push` | 20:21:50 → 20:22:34, **44 s** | 20:35:54 → 20:36:13, **19 s** |
| `exporting to image` | 15.2 s | 0.2 s, every `runtime` layer `CACHED` |
| Image digest | `sha256:9e67e4d1a1ffdcc7953caa2d3d1932f07494385aab498a6e3e500eabddd29a2b` | **the same digest**, under the new tag `506766b8a86d` |

The identical digest across two commits is stronger than anything the step asks for: the only change between
them was the `Jenkinsfile`, which is not copied into the image, so the runtime content is byte-identical and
BuildKit reused it. The new tag is a second label on the same image, which the repository's
`IMMUTABLE_WITH_EXCLUSION` setting permits because the tag itself is new.

Both builds ran on `main` rather than the temporary branch, so both exported the cache. The step's claim that
a branch build imports but never exports is therefore **still unexercised**.

## Step 12 — The gate: no image with a fixable CRITICAL

Build 17, again on `main` rather than a temporary branch. The scan ran, the report was archived, and the gate
crashed on a flag that does not exist.

| Check | Result |
|---|---|
| Image scanned | by digest, `medical-rag@sha256:9e67e4d1a1ff…`, so the tag could not be moved underneath it |
| Debian findings | **Total 263** — UNKNOWN 1, LOW 102, MEDIUM 100, **HIGH 55**, **CRITICAL 5** |
| Python findings | Total 6 — LOW 1, MEDIUM 5, HIGH 0, CRITICAL 0, all in `pip` 25.0.1 |
| Against step 1 | **identical**: 5 CRITICAL and 55 HIGH, on the same image content |
| The five CRITICAL | `libsqlite3-0` CVE-2025-7458; `perl-base` CVE-2026-13221, CVE-2026-42496, CVE-2026-8376; `zlib1g` CVE-2023-45853. Every one has an empty `Fixed Version` and a status of `affected`, `will_not_fix` or `fix_deferred` |
| Gate | `FATAL Fatal error unknown flag: --ignore-unfixed`, build `FAILURE` |
| `archiveArtifacts` in `post { always }` | ran anyway — `Archiving artifacts`, `Recording fingerprints` |
| Scan duration | 20:41:37 → 20:42:00, about 23 s, of which 13 s was downloading the vulnerability database |

**What this proves even though the build failed.** The counts reproduce step 1 exactly, so the scan is reading
the image the pipeline built and nothing drifted. And the step's own design argument held under the only test
that could check it: the report was written before the gate, the gate failed, and the report was still archived.

**The gate command does not exist.** `--ignore-unfixed` is a flag of Trivy's *scan* commands. `trivy convert`
re-reads an existing report and offers only `--severity`, `--exit-code`, `--ignore-policy` and `--ignorefile` —
Trivy's own usage output, printed by the failure, lists them. With `--severity CRITICAL --exit-code 1` alone the
gate would fail every build on five findings nobody can act on, which is the outcome the step explicitly sets
out to avoid. Fixed by counting in the report instead, in the `tools` container because that is the one with
`jq`: CRITICAL findings whose `FixedVersion` is non-empty, which must be `0`. The count is echoed, so the gate
reports a number rather than passing silently.

**The corrected gate passed, on the branch.** Build 1 of `jenkins/step-12`, the first build in this phase to
run anywhere but `main`:

| Check | Result |
|---|---|
| Gate | `CRITICAL with a fix available: 0`, then `[ 0 -eq 0 ]` — `SUCCESS` |
| Counts | `Total: 263 … HIGH: 55, CRITICAL: 5` for the third build running, unchanged |
| `trivy-report.json` | archived again, this time from a passing build |
| Branch cache behaviour | `[ jenkins/step-12 = main ]` was false, the `buildctl` line carried `--import-cache` and **no** `--export-cache`, and no `exporting cache to registry` step ran |
| `Build and push` | 20:47:39 → 20:47:43, **4 s** — against 19 s on `main` with the export and 44 s with the cache cold |

**That settles the branch-cache claim.** `3-pipeline.md:419` says branch builds import the cache but never
export it, so a branch cannot poison what `main` builds from. Nothing had tested it: builds 11 to 17 all ran on
`main`, where the export always fires. This build is the first negative case, and the 15 seconds it saves are
the export that did not happen.

**The gate now reports a number.** The original returned only an exit code, so a gate that never ran and a gate
that found nothing were the same observation. The replacement echoes the count first.

**What the gate still has not done is fail.** All five CRITICAL findings are unfixed, so `0` is the only answer
it can give today, and passing proves it does not block wrongly — not that it blocks. A positive control is
cheap and remains untaken: run one build with the severity lowered to `MEDIUM`, where `pip` carries five
findings that *do* have fixed versions, and the gate should go red.

**A cache that is not a cache.** `TRIVY_CACHE_DIR` points at `/home/jenkins/agent/.trivy`, which is on
`workspace-volume` — an `emptyDir` created fresh for every build pod. The 114.8 MiB vulnerability database is
therefore downloaded on every single build. The variable does do its other job, giving a container that runs as
uid 1000 somewhere writable, since Trivy's default `/.cache/trivy` is not. Not fixed; recorded.

## Step 13 — Fewer findings in the base image

Both base images moved from Debian 12 (bookworm) to Debian 13 (trixie), each pinned by the digest of its
multi-platform index.

```
FROM ghcr.io/astral-sh/uv:python3.12-trixie-slim@sha256:9a59bb7206905ccaae4f7dab222fbac47c125a21e5fc16f43f427cd6c940ade3 AS builder
FROM python:3.12-slim-trixie@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9 AS runtime
```

**Criterion #9, before and after.** Both columns are the same command over the archived `trivy-report.json`
of two builds, so they compare directly. The counts include both `Results` arrays — the Debian packages and
the Python ones — which is why they are six higher than the Debian table printed in the console.

| Severity | Debian 12.15 | Debian 13 | Δ |
|---|---|---|---|
| **CRITICAL** | **5** | **0** | **−5** |
| HIGH | 55 | 44 | −11 |
| MEDIUM | 105 | 54 | −51 |
| LOW | 103 | 58 | −45 |
| UNKNOWN | 1 | 2 | +1 |
| **Total** | **269** | **158** | **−111, or −41%** |
| Fixable CRITICAL | 0 | 0 | — |

**All five CRITICAL findings are gone**: `libsqlite3-0` CVE-2025-7458, `perl-base` CVE-2026-13221,
CVE-2026-42496 and CVE-2026-8376, and `zlib1g` CVE-2023-45853. Trixie ships patched versions of all of them.

**And the gate could never have done this.** It reported `0` both before and after, correctly: every one of the
five had an empty `Fixed Version` *in Debian 12*, so `--ignore-unfixed` — in any spelling — was always going to
pass them. Moving the base is the only action that reaches findings of that shape. The gate's job is to stop
the day a fix exists and the image was built without it; the base bump is the job of noticing that the whole
distribution moved on. This step is the clearest evidence in the phase that the two are different controls.

**The step gives no way to fetch what it asks you to compare.** Its check reads *"on the workstation, against
the two archived reports"*, and `trivy-report.json` is a Jenkins build artifact on the controller's PVC, not a
file in the workstation's clone. Running the `jq` line as written answers
`jq: error: Could not open file trivy-report.json`. What works:

```bash
kubectl -n jenkins exec jenkins-0 -c jenkins --   sh -c 'ls -1t /var/jenkins_home/jobs/medical-rag/branches/*/builds/*/archive/trivy-report.json'
kubectl -n jenkins exec jenkins-0 -c jenkins -- cat "$PATH_FROM_ABOVE" > /tmp/after.json
```

`jq` then runs on the workstation, because the controller image does not have it.

**`--format` was ignored.** The step reads the digests with
`docker buildx imagetools inspect <tag> --format '{{.Manifest.Digest}}'`; on this workstation's buildx the flag
had no effect and the full manifest listing was printed instead. The `Digest:` line at the top of that output
is the index digest, which is the value the step wants, so the step still works — but its expected output,
"two `sha256:…` lines", is not what appears.

## Step 14 — Sign what was built

**The branch build behaved as designed.** `Stage "SBOM and signature" skipped due to when conditional`, then
`Finished: SUCCESS`. This answers a question the guide's own asymmetry raised: step 12's `archiveArtifacts`
carries `allowEmptyArchive: true` and step 14's does not, so a `post { always }` that ran on a skipped stage
would have failed the build with `No artifacts found`. It does not run. Declarative skips the `post` section of
a stage its `when` rejects, and the missing flag is harmless.

**cosign matches between workstation and pipeline:** `v3.1.3` in both, the same version `ci/Dockerfile` pins,
so a flag verified on the workstation is a flag the build will have.

| Flag | `sign` | `attest` | `verify` |
|---|---|---|---|
| `--key`, including `awskms://[ENDPOINT]/[ID/ALIAS/ARN]` | yes | yes | yes |
| `--predicate` | — | yes | — |
| `--type`, with `spdxjson` among the allowed values | — | yes | — |
| `--insecure-ignore-tlog` | — | — | yes |
| `--tlog-upload` | in an **example line only**, not in the flag list | **not shown at all** | — |

**The stage failed on `main`, on that flag.** Build output:

```
+ cosign sign --yes '--tlog-upload=false' --key awskms:///alias/medical-rag-cosign …/medical-rag@sha256:f5b6789a…
Flag --tlog-upload has been deprecated, prefer using a --signing-config file with no transparency log services
Error: --tlog-upload=false is not supported with --signing-config or --use-signing-config.
```

It failed cleanly: `sign` refused before doing anything and `sh -e` stopped the stage, so `attest` never ran and
no half-made signature was left behind.

**What cosign v3 actually offers.** Measured from `--help` on the same v3.1.3 the pipeline uses:

| | `sign` | `attest` |
|---|---|---|
| `--tlog-upload` | present but **deprecated**, and rejected in practice | **absent** |
| `--rekor-url`, `--offline` | — | **absent** |
| `--signing-config` | present | present |
| `--use-signing-config` | present, **defaults to `true`** | present, **defaults to `true`** |

That default is the conflict: nothing passed `--signing-config`, but v3 enables one anyway. Per-service URL flags
are gone; v3 moved all of it into a signing config for signing and a trusted root for verifying. So there is no
flag that turns the transparency log off — the guide's approach cannot be repaired by renaming a flag.

**The remedy, and it is cheap.** `cosign signing-config create --out FILE` builds a config from scratch, and every
service flag is optional. With none given it writes:

```json
{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}
```

No Rekor service, no Fulcio, no TSA — which is precisely the intent, since signing uses a KMS key and needs none
of them. Passing that file to both `sign` and `attest` replaces the removed flags. It is generated inside the
stage rather than baked into the tools image: it always matches the cosign that reads it, and creating it needs
no network, so it adds no dependency.

**Proved before it went near `main`,** with the real key and the real image:

```
cosign sign --yes --signing-config /tmp/sc.json --key awskms:///alias/medical-rag-cosign …@sha256:f5b6789a…
Pushing signature to: 242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag
```

**This signature was made from the workstation by the operator, not by the pipeline.** It counts as evidence that
the command shape works and that the key is reachable; it is not evidence that the stage works. The pipeline's
own signature is still owed.

**A side effect worth recording:** the push succeeded against a repository set to `IMMUTABLE_WITH_EXCLUSION`, so
the `sha256-*` exclusion filter in `infra/terraform/shared/registry.tf` does what it was written for. Nothing had
tested that until now.

**The pipeline then did it.** The stage on `main`, end to end:

```
+ trivy image --format spdx-json --output sbom.spdx.json …@sha256:f5b6789a…
INFO  "--format spdx-json" disables security scanning…
INFO  Detected OS  family="debian" version="13.7"
+ cosign signing-config create --out signing-config.json
+ cosign sign --yes --signing-config signing-config.json --key awskms:///alias/medical-rag-cosign …
Signing artifact...
Pushing signature to: 242834061265.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag
+ cosign attest --yes --signing-config signing-config.json --type spdxjson --predicate sbom.spdx.json --key … …
Using payload from: sbom.spdx.json
Signing artifact...
```

`attest` was the part nothing had exercised — `sign` had been proved by hand, `attest` had not. It works with the
same signing config.

**`debian 13.7`, from the image the pipeline built.** That closes step 13's remaining question: the trixie
digests took effect in the built image, not only in the `FROM` lines. `--format spdx-json` turns vulnerability
scanning off, which is why this run reports no counts; the `Scan` stage is where those come from.

**The verification pair, which is the actual evidence:**

| Command | Result |
|---|---|
| `cosign verify --key … --insecure-ignore-tlog …@sha256:f5b6789a…` | `The cosign claims were validated`, `The signatures were verified against the specified public key` |
| `cosign verify --key … --insecure-ignore-tlog …:1eaa43bf3512` | `Error: no signatures found` |

The second is what makes the first mean something. A lone passing `verify` cannot tell "this signature is valid"
from "cosign accepts anything"; the app-phase image, never signed, is the negative control.

`--insecure-ignore-tlog` still exists in v3 and works, unlike `--tlog-upload`. It prints a warning, and the
output still lists `Existence of the claims in the transparency log was verified offline` — wording that reads
oddly next to a warning saying tlog verification was skipped.

**Three payload entries, and they are not all the pipeline's:**

| Type | Origin |
|---|---|
| `https://sigstore.dev/cosign/sign/v1` | the operator's signature, made from the workstation while testing the remedy |
| `https://sigstore.dev/cosign/sign/v1` | the pipeline's signature |
| `https://spdx.dev/Document` | the pipeline's SBOM attestation |

Both signatures use the same KMS key on the same digest, so `verify` accepts either, and the two cannot be told
apart from the payload. Anyone reading this later should know that **a second, hand-made signature exists on
`sha256:f5b6789a…`** and that only the later two entries are the pipeline's work.

## Step 15 — Notice when the corpus changes

**Caught before the build ran: the stage calls a step this controller does not have.** The guide's stage reads
the two values files with `readYaml`, which comes from the `pipeline-utility-steps` plugin.
`deploy/argocd/values/jenkins.yaml` installs fourteen plugins and that is not one of them, and nothing in
`workflow-aggregator`'s tree pulls it in. The stage would have failed with `No such DSL method 'readYaml' found
among steps`, in the same shape as the three command-level defects already recorded — except this one was found
by reading the plugin list instead of by a red build.

Two ways out, and the choice is not symmetric:

| | Add `pipeline-utility-steps` | Read the field with `yq` |
|---|---|---|
| Cost | another plugin, another install round, another chance of a suite split | none; `ci/Dockerfile` already installs `yq` |
| Risk | plugin resolution on this controller has already failed twice | `yq -r` is proved to work here |
| Works if the plugin turns out to be present after all | yes | **yes** |

`yq` was taken, because it is the only one of the two that is correct whichever the plugin list actually holds.
The guide's comment at the time — *"readYaml runs on the controller, so no container needs yq for this
comparison"* — is the reasoning that produced the defect: it optimises away a tool that is already there in
favour of one that is not installed. Both the stage and that comment have since been replaced in the guide.

**Prerequisites checked, all present:** `data/` holds one 12 MB PDF; `deploy/envs/{dev,prod}/values.yaml` both
carry `index.version: "cc759ae1a093"`, the value the step's expected output names; `python -m app.index version`
prints one line; and `corpus_dir()` falls back to `DATA_PATH` when `CORPUS_STORE` is unset, so the build stage
needs no network and no credentials.

**Case 1, nothing changed:**

```
index version: built=cc759ae1a093 dev=cc759ae1a093 prod=cc759ae1a093
```

All three equal, so `INDEX_CHANGED_DEV` and `INDEX_CHANGED_PROD` are both `no` and the checksum comparison
against S3 never runs. The `yq` substitution reads the same values `readYaml` would have.

**The build-context cost is negligible, which was worth measuring rather than assuming.** Removing `data/` from
`.dockerignore` puts the 12 MB PDF into the context of every `buildctl` call, three per build:

```
#7 [internal] load build context
#7 transferring context: 12.24MB 0.1s done
```

**0.1 s.** The context travels between two containers in the same pod, so 12 MB costs nothing measurable
against a build that takes tens of seconds. The concern recorded before the run was misplaced.

**Case 2, a chunk setting changed** (`CHUNK_SIZE` default 500 → 501, nothing else):

```
index version: built=255b7be51bed dev=cc759ae1a093 prod=cc759ae1a093
corpus local=Gy4ax6EuP5qXu9mXly8nyxN4beJW3oNielHmnQkgiXM= s3=Gy4ax6EuP5qXu9mXly8nyxN4beJW3oNielHmnQkgiXM=
```

The version moved on a setting alone, the PDF untouched, so the checksum block ran and both sides matched. The
stage passed. That is the distinction the step exists to draw: a new index version does not imply a new corpus.

**Case 3, a corpus that S3 does not have — and the build went red, which is the point:**

```
index version: built=510fa9c0f86e dev=cc759ae1a093 prod=cc759ae1a093
corpus local=Gy4ax6EuP5qXu9mXly8nyxN4beJW3oNielHmnQkgiXM= s3=missing
The corpus in S3 is not the PDF in Git. Upload it first (app guide step 13), then rerun.
+ exit 1   →   Finished: FAILURE
```

**This is the only positive control in Part 3.** Step 12's gate has never returned anything but `0`; this one
was shown refusing something. A gate that has never refused has only been shown not to refuse wrongly.

**Done by renaming the PDF, not by editing a byte as the step says.** `compute_version` hashes `pdf.name`
before the bytes (`src/app/index.py:33`), so a rename moves the version just as an edit would, and `LOCAL` came
back **unchanged** at `Gy4ax…giXM=`, which is the proof that only the name moved. Two reasons to prefer it: a
one-byte edit of a 12 MB binary writes a second 12 MB blob into Git history for ever, and a rename also
exercises the missing-object path rather than the mismatched-checksum path.

**One claim in the step is still unmeasured, and trying to measure it found a worse defect.** The Why says a
missing object answers `403`, not `404`, because the role cannot list the bucket. The stage cannot show that:
`aws s3api head-object … 2>/dev/null || echo missing` discards the error and the log jumps straight to
`+ echo missing`. Running it by hand on the workstation answered `An error occurred (404)`, which settles
nothing — the workstation is not the CI role and evidently does have `ListBucket`. Only a build pod can answer
it.

**The defect: `2>/dev/null` reports every failure as a wrong corpus.** An expired token, a mistyped bucket
name, a network fault and a genuinely absent object all become `REMOTE=missing`, and all four print *"The
corpus in S3 is not the PDF in Git. Upload it first"*. Someone would re-upload 12 MB of PDF to fix a
credential. That is the same shape as the false passes catalogued in this file, inverted: a confident
diagnosis of a cause the check never established.

Fixed in the `Jenkinsfile`: the command's output is captured with `2>&1`, success and failure are told apart by
exit status, and a failure prints `head-object did not answer: <the error>` before falling back to `missing`.
The next time case 3 runs it will also say whether the answer was 403 or 404, which closes the open claim as a
side effect rather than as a separate test. **Fixed in the guide since**, along with a second defect the
first version introduced: capturing with `2>&1` merges stderr into the value on the *success* path too, so a
warning on a call that exited 0 would have failed the comparison and printed the same wrong diagnosis. Now
stderr goes to its own file.

**Stage times, from the branch build** (whole run about 1 min 32 s): checkout 3 s, `Skip guard` 1 s, `Test`
30 s, `Log in to ECR` 2 s, `Build and push` 13 s, `Scan` 22 s, `SBOM and signature` **0 ms** — the `when`
skip costs nothing — and `Index version` 9 s, of which the `buildctl` export was 5 s and each `yq` about
0.64 s.

## Step 16 — The bot updates dev

**A second queue message that looks like a failure.** Build 31 printed

```
Still waiting to schedule task
All nodes of label 'medical-rag_main_31-9cwcm' are offline
```

and at that moment `kubectl -n jenkins-agents get pods` showed
`medical-rag-main-31-9cwcm-vt281-42fhw   4/4   Running`, scheduled 54 s earlier with all four containers
started, and the controller log carried `Created Pod`. So the build was fine. Jenkins creates the node object
first and the agent connects once `jnlp` is up; in between, the queue describes the node as offline. It belongs
with `Still waiting to schedule task` — alarming wording for an ordinary wait. The guide covers that one, in
step 10 and in a troubleshooting row. **`All nodes of label '…' are offline` it does not**, in either place,
and that is the gap.

**Where the CPU actually went, measured from the three nodes:**

| Node | Requests | Free | Notes |
|---|---|---|---|
| `medical-rag-node-1` | 1690m of 2000m (84%) | **310m** | 250m more than step 1.2 measured: this is where the Jenkins controller runs |
| `medical-rag-node-2` | 1725m (86%) | 275m | includes the 500m build pod; **775m** when idle |
| `medical-rag-node-3` | 1280m (64%) | **720m** | unchanged since step 1.2 |

**Step 1.2's prediction held exactly.** It said the controller would take about 250m and a build pod at least
400m, that each fits the smallest gap of 560m, and that the two together fit only on different nodes. The
controller landed on node 1 and left it 310m — too little for the build pod, which now asks 500m after step 12
added Trivy. Build pods therefore have two nodes to choose from, not three, and that was decided by a
measurement taken before Jenkins existed.

**The margin is narrowing.** The build pod went from 400m at step 10 to 500m at step 12. One more container of
the same size would leave only node 3 able to host it.

**The bot wrote to `main` and the loop closed.**

| | |
|---|---|
| The bot's commit | `6fb3638  dev: a0c71e643a75`, authored `jenkins-bot`, `2026-09-20T15:50:33Z` |
| What it wrote | `tag: "a0c71e643a75@sha256:f5b6789a475d76f3e25550d00e748be3d6245d0aac2e1e6d817cefbf23e2269e"` — the Debian 13 image from steps 13 and 14 |
| `index.version` | untouched at `cc759ae1a093`, because `INDEX_CHANGED_DEV` was `no` |
| The next build | `Nothing to build: author=jenkins-bot, only docs or deploy files changed`, `NOT_BUILT` |

That last row is the anti-loop mechanism working, and it is the only way to see it work: the guard has to
recognise a commit the pipeline itself made. Until now nothing had made one.

**Before this, dev had been running the same image since 02:19 that morning** — `1eaa43bf3512@sha256:c10cd57e…`,
the one the app phase put there by hand, while the pipeline pushed a new image on every commit. That gap is
exactly what the step exists to close, and it was visible for a day.

**`yq -i` rewrites the file, which the step's Why understates.** It says *"it edits the value and leaves every
comment in place"*. The comments do survive; the document does not:

| | Before | After |
|---|---|---|
| Blank lines grouping the sections | 3 | 0 |
| Comment alignment | padded into columns | collapsed to one space |
| Line endings | 12 CRLF | 2 CRLF and **7 LF** |

So the first bot commit rewrites the whole file, and the file is left with mixed line endings — the two leading
comment lines kept their CRLF, everything `yq` regenerated came back LF. Functionally nothing is wrong and
later bot commits are a one-line diff, but the next person editing this from Windows gets a noisy diff, and the
blank-line grouping the author used is gone for good. A `.gitattributes` line such as `*.yaml text eol=lf`
would stop the churn; not done, because it changes the whole repository and belongs to a decision of its own.

**Criterion #8, commit to running: 19 minutes 8 seconds.**

| Moment | Time | Leg |
|---|---|---|
| The commit, `a0c71e6` | `2026-09-20T15:36:13Z` | — |
| The bot's commit, `6fb3638` | `15:50:33Z` | **14 m 20 s** in the pipeline |
| The dev pod `Ready` | `15:55:21Z` | **4 m 48 s** through Argo CD and the rollout |
| Image it runs | `medical-rag:a0c71e643a75@sha256:f5b6789a…` | the digest the build produced |

**Two caveats, both of which make this number soft.**

The second leg was not hands-off: `argocd.argoproj.io/refresh=normal` was annotated by hand while waiting, and
that is very likely what triggered the sync. Argo CD's own poll would have taken up to its interval. So 4 m 48 s
is a *nudged* number, not the one a release gets when nobody is watching.

And the pipeline leg, 14 m 20 s, is far above the 1 m 32 s a branch build took at step 15. Three stages run only
on `main`, and `containerCap: 1` means a build can queue behind another; how much of the 14 minutes was waiting
rather than working was not separated. The build's *Stage View* would split it and was not captured.

**The step's own check command reports the wrong time, and that is how the number came out too low.** The
first reading gave `creationTimestamp` and `Ready` as the same second, `15:55:10Z`, which cannot be right: the
app has an init container that fetches the index. Reading the conditions individually:

```
PodScheduled=True                15:55:10Z
PodReadyToStartContainers=True   15:55:11Z
Initialized=True                 15:55:13Z
ContainersReady=True             15:55:21Z
Ready=True                       15:55:21Z
```

Eleven seconds from scheduled to ready, not zero. The guide's command filters
`select(.type=="Ready") | .lastTransitionTime` **without also requiring `.status=="True"`**. A pod that is not
ready yet still has a `Ready` condition — with `status: False` — and its `lastTransitionTime` is when it became
False, which is about when the pod was created. So the command answers with a plausible timestamp for a pod
that has not started, and criterion #8 comes out 11 seconds short. It needs
`select(.type=="Ready" and .status=="True")`, and a reader should not accept a `Ready` time that equals
`creationTimestamp`.

The previous pod from `02:19:01Z` was still listed at the time of the read, so the rollout was still in
progress — another reason the first reading was taken too early.

## Step 17 — Prod by pull request

The `Jenkinsfile` carries all ten stages in the order the guide's *finished pipeline* lists, with
`Tag the image prod runs` first — ahead of the skip guard, because the commit that merges a prod pull request
changes only `deploy/` and the guard would otherwise end the build before the tag was written.

| Check | Result |
|---|---|
| The pull request | `#2  prod: b79a4531d5cb`, from `bot/prod-b79a4531d5cb` |
| Its body | `Image: …/medical-rag:b79a4531d5cb@sha256:f5b6789a…`, `Index version: cc759ae1a093`, `Trivy: HIGH 44, LOW 58, MEDIUM 54, UNKNOWN 2`, `Dev has been running this image since build 35.` |
| Its diff | one file, `deploy/envs/prod/values.yaml` |
| Merged | `bcd556a  prod: b79a4531d5cb (#2)` — the `(#2)` suffix is GitHub's squash-merge form, so the repository setting took |
| `Tag the image prod runs` | ran, and `release-b79a4531d5cb` now exists |
| The tagged image | `sha256:f5b6789a475d76f3e25550d00e748be3d6245d0aac2e1e6d817cefbf23e2269e` |
| The build after the merge | `NOT_BUILT` |
| Prod's pods | all three on `b79a4531d5cb@sha256:f5b6789a…` |

**The digest prod runs is the one the whole chain agreed on.** `f5b6789a…` is the Debian 13 image step 13
measured at **0 CRITICAL**, the image step 14 signed and `cosign verify` accepted, and the image whose scan
summary the pull request carried for review. Until this step, prod had been running `c10cd57e…`, placed by hand
during the app phase.

**The skip guard stopped that build for the other reason.** Its message was
`Nothing to build: author=Le Nguyen Phuoc Thanh, only docs or deploy files changed` — **not** `jenkins-bot`. A
squash merge is authored by whoever pressed the button, so the author test never fires on a merge; what caught
it was `onlyDocs`. Both conditions lead to `NOT_BUILT`, and the step's Why says as much, but a reader skimming
it may conclude the bot's name is what protects against the loop. On a prod merge it is not.

**One image, ten tags.**

```
sha256:f5b6789a…  →  a5a04d8c2e71, 0f3586e8c8fb, b79a4531d5cb, da86f9a711c6, 03a094343291,
                     release-b79a4531d5cb, a0c71e643a75, 8efe125bbf62, 02d44eff3b6e, ee9ae14b4efe
```

Every commit since the base moved to Debian 13 that **reached** `Build and push` touched only files outside
the runtime image — the `Jenkinsfile` itself, `ci/`, `infra/` — so BuildKit reproduced the same content each
time and each build added a tag to it. Commits under `docs/` or `deploy/` produced no tag at all: the skip
guard ends those as `NOT_BUILT` before the build stage, which is the same mechanism that stops the bot's own
commits looping. Nothing is wrong — it is the reproducibility first seen at step 11, at scale — but two things
follow that the guide does not mention. The tag says which commit *built* an image, not which commit *changed*
it. And step 2's lifecycle rules count images, not tags, so ten tags on one image consume one of the thirty
places, not ten.

## Step 18 — Take push and sign away from the node role

Applied. `infra/terraform/cluster/iam.tf` lost four ECR write actions and the whole `CosignSign`
statement; the node role keeps only reads. The simulator answers below are what show it landed: they read
the policy attached in the account, not the file.

**The step's own block would have undone step 11.** It gives the replacement statement as

```hcl
    resources = [data.aws_ecr_repository.app.arn]
```

— the app repository alone. But step 11 added `data.aws_ecr_repository.ci.arn` to that same statement so the
kubelet could pull the tools image, and without it the `tools` container goes back to `ImagePullBackOff`. Step
18 was written before step 11 had a node-role change at all, which it did not until this run. Both ARNs kept.

**Removing `CosignSign` orphans a data source the step does not mention.**
`data "aws_kms_alias" "cosign"` in `infra/terraform/cluster/main.tf` existed only to give that statement its key
ARN. Terraform does not fail on an unused data source, it just reads it on every plan for nothing. Removed.
Data sources are not counted in the plan summary, so the step's expected `0 to add, 1 to change, 0 to destroy`
still holds.

**What the change is, exactly:**

| | Before | After |
|---|---|---|
| ECR statement | `EcrPullPush` — 5 read actions plus `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` | `EcrPull` — the 5 reads |
| ECR resources | app repo + ci repo | **unchanged**: app repo + ci repo |
| KMS | `kms:Sign`, `kms:GetPublicKey`, `kms:DescribeKey` on the cosign key | statement gone |
| `ecr:GetAuthorizationToken` | `*` | **unchanged** — the kubelet needs it to pull at all |

**What the simulator answered.** Against the node role's ARN — the step's four actions, and one more it does
not ask for:

| Action | Resource | Answer |
|---|---|---|
| `ecr:PutImage` | `medical-rag` | `implicitDeny` |
| `ecr:BatchGetImage` | `medical-rag` | `allowed` |
| `ecr:GetDownloadUrlForLayer` | `medical-rag` | `allowed` |
| `kms:Sign` | the cosign key | `implicitDeny` |
| `ecr:BatchGetImage` | `medical-rag-ci` | `allowed` |

The fifth row needed a third call, with `--resource-arns` set to the `medical-rag-ci` ARN; the step's
`$REPO_ARN` only resolves `medical-rag`. It is the row that matters: it is what shows the deviation above —
keeping both ARNs — was the right call. All three pull actions the kubelet needs sit in that one statement, so
one of them answering `allowed` on that repository settles the other two. Had the step been followed
literally, the row would read `implicitDeny` and the `tools` container would stop being pullable on the next
pod.

**The in-cluster check as written cannot run.** `kubectl run … --image=public.ecr.aws/aws-cli/aws-cli:$AWSCLI
-- sh -c "…"` answers

```
aws: [ERROR]: An error occurred (ParamValidation): argument command: Found invalid choice 'sh'
```

The image has `ENTRYPOINT ["aws"]`, so everything after `--` is appended as *arguments to* `aws` rather than
run as a command. The failure reads like a typo in the shell line and says nothing about permissions, which is
the worst shape for a check whose entire job is to distinguish "denied" from "broken". `--command` before `--`
is what overrides the entrypoint. The app guide's version of the same check (step 9,
`docs/app/guide/1-pod-identity.md:1334`) passes `-- s3api list-objects-v2 …`, which really are arguments to
`aws`, so it needs no override and gave no warning that this one would.

**The skip guard cannot see a merge commit's files.** The push that carried the code change for this step was
a `git pull` merge, so `main`'s head was a merge commit. The guard's own command answers nothing on one:

```
$ git show --pretty= --name-only HEAD | wc -c
0
```

An empty list is what the guard calls unknown, and unknown counts as a build, so the build ran. The direction
is the safe one and it was chosen on purpose. What it means in practice is that a docs-only merge always
builds: the guard can only ever skip a single-parent commit. Step 17's squash merge is single-parent, so prod
is unaffected.

**What the pod answered, with `--command`.** Both halves as the step expects:

```
arn:aws:sts::242834061265:assumed-role/medical-rag-nodes/i-080eaea8ca9c2aa11
aws: [ERROR]: An error occurred (AccessDeniedException) when calling the Sign operation: User:
arn:aws:sts::242834061265:assumed-role/medical-rag-nodes/i-080eaea8ca9c2aa11 is not authorized to perform:
kms:Sign on resource: arn:aws:kms:ap-southeast-1:242834061265:key/058d89ae-… because no identity-based
policy allows the kms:Sign action
```

The first line is what makes the second line mean something: the pod really did assume the node role, through
IMDS, from a namespace that does not block it. `no identity-based policy allows the kms:Sign action` is the
shape of an `implicitDeny` seen from the caller's side — the statement was removed, not denied.

**And the pipeline still works.** The build on `main` after the change finished `SUCCESS`, so `Build and push`
called `ecr:PutImage` and `SBOM and signature` called `kms:Sign` — both of which the node role had just lost.
That is the measurement this step exists for: the build pod uses the CI role, not the node role, and it uses it
in every container that needs AWS, not only where step 9 looked.

Worth being exact about what this does *not* prove. The node role was already out of this pod's reach before
step 18, because step 6's NetworkPolicy excludes `169.254.169.254/32` from egress in both Jenkins namespaces.
A green build shows the exchange still works; it could not have gone red from step 18 alone. What step 18
changes is every *other* pod in the cluster, which is what the `default`-namespace check above measures.

## Step 19 — Not run

The clean-up half was done: `k8s.yaml` is deleted and its `.dockerignore` line with it (`b672154`). The
teardown and rebuild half was **not run**, by decision on 2026-09-21 — the phase was closed on the cluster it
grew into.

**What that leaves unproven.** Everything this phase claims about reproducibility. The GitOps phase measured a
rebuild at 14 m 11 s on 2026-09-18, but that cluster had no Jenkins in it. Nothing here shows that
`jenkins-platform` at wave 3 and `jenkins` at wave 4 come back from Git, that the admin password regenerates
cleanly, that the OIDC issuer survives so the build pods' tokens still resolve, or that a commit reaches dev on
a cluster built an hour earlier. The phase README and guide must not claim otherwise.

**Answered later, in the drills phase (2026-09-22).** The cluster was rebuilt twice with both Jenkins
Applications in it, and every Application came back Synced and Healthy: 14 in Part 0, 17 in M3
([`drills.md`](drills.md)). Both admin passwords could be read after the Part 0 rebuild (step 7; that they were new
ones is inferred, since they are generated in the cluster), and `oidc-check` printed two `same` lines both times. The
pipeline ran on each rebuilt cluster: the bot's dev commits `1255b50` (00:35:24Z, after the Part 0 rebuild) and
`624a8e2` (05:37:56Z, 4 m 41 s after M3 ended). A dev pod reaching Ready on a rebuilt cluster was not
recorded.

**Three smaller things it also leaves open:**

- The lifecycle preview still has nothing to prove: fewer than 30 tagged images exist, so the second rule
  expires nothing either way (step 2's note above says the same).
- The repository's total size and untagged count — the input for deciding whether the BuildKit cache needs a
  repository of its own — were never measured.
- Defect 14's owed mitigation stands. Build 14's console still holds the ECR token it printed. The token itself
  expired twelve hours after that build, so the exposure is closed by time rather than by action; the record is
  what remains, and it lives on the Jenkins PVC, which only a teardown deletes.

## Problems found and fixed

**Part 2.** Five. Four are purely defects in the guide; the first also had a real cause in the account — the
AWS secret was genuinely empty — and the guide's defect was having no check for it. In two shapes. **Three were
checks that passed while the thing they guarded was broken:** the empty secret, the uncompiled policy, the
unfilled placeholder. **Two failed loudly but pointed away from the cause:** `jq: Invalid numeric literal` for a
307 redirect, and a namespace mismatch for a values change made three steps earlier. Item 6 below, in Part 3,
is a fourth of the first shape — and it is the rule that was written to fix the third.

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

**Part 3.** Eighteen, all defects in the guide, none in the cluster. One is a disclosed credential. Five are
commands that cannot do what the step says — items 15, 16, 17, 18 and 23: one flag the tool removed after the
guide was written, one flag that subcommand never had, one flag that was silently ignored, one file that is
not where the step looks for it, and one entrypoint the step did not account for. Two are checks that passed
while the thing they guarded was broken, items 6 and 20 — the fourth and fifth of that shape in the phase,
after Part 2's three; item 20 was found only because its answer was implausible. One defect — the split
Declarative suite — cost four builds and two wrong diagnoses before it was measured.

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
9. **The Declarative suite split a second time, below the plugin-load check.** After the three plugins the
   startup log named were pinned, the check returned `1` and `0` and the next real build failed with
   `java.lang.NullPointerException: Cannot invoke method call() on null object`. Reading each plugin's
   `META-INF/MANIFEST.MF` showed why: `pipeline-model-api` and `pipeline-model-extensions` were at
   `2.2277.v00573e73ddf1` while `pipeline-model-definition` and `pipeline-stage-tags-metadata` were still at
   `2.2218.v56d0cda_37c72`. Those four are released together from one repository and share a version string; a
   mixed set loads without complaint and then calls across the gap at run time. **The plugin-load check is
   structurally blind to this** — it reads declared minimums, and every declared minimum was satisfied. Fixed by
   pinning all four; the check that would have caught it is a version-equality read across the suite, which the
   guide does not have. *Which* build the NPE stack trace belongs to was never captured — the controller log was
   rotated away by the pod restart — so the link from the split to that exact exception is **inferred from the
   symptom's shape and from the fix working**, not proven.
10. **Step 10 expects the wrong number of stage lines.** The Check says "**two** `[Pipeline] stage` lines, one
   per stage". A Declarative build emits three: `Declarative: Checkout SCM` is a stage the plugin adds before
   the ones in the file. Counting by the guide would read a correct build as broken.
11. **Step 10's `Test` stage cannot use the cache it asks for.** `--import-cache type=registry,ref=…:buildcache`
   needs a registry login, and the step's whole argument is that no credential exists yet; `Log in to ECR` is
   step 11 and comes after. Every build prints
   `ERROR: failed to configure registry cache importer: … 401 Unauthorized`, BuildKit ignores it, and the guide
   does not say the line is expected.
12. **Step 11's `| File | Change |` table omits the Terraform the step hands over.** The table lists only
   `ci/Dockerfile`, `Makefile` and `Jenkinsfile`, while the step body also gives an `aws_ecr_repository "ci"`
   block for `infra/terraform/shared/registry.tf` and expects `make shared` to report **2 to add**. Rule 2 says
   `git status --short` must list exactly the files in the table, so following the table leaves the repository
   uncreated and `make ci-image` fails with `name unknown`.
   **Correction, 2026-09-20:** this entry first claimed no HCL for the repository appeared anywhere in the
   guide. That was wrong — the block is in step 11, below the `Why` section, and the search that missed it
   looked for the literal `medical-rag-ci` while the block writes `${local.name}-ci`. Acting on the wrong
   premise put a second, conflicting copy of the same resources into the step; it has been removed and the
   original kept, including its `IMMUTABLE` choice and the paragraph above it that explains why one commit is
   one image. `infra/terraform/shared/registry.tf` was changed to match that original.
13. **The node role cannot pull the tools image.** `infra/terraform/cluster/iam.tf` scopes every ECR read to
   `data.aws_ecr_repository.app.arn`. The kubelet pulls `image: ${CI_TOOLS}` with the node role, so even once
   the repository exists the `tools` container would sit in `ImagePullBackOff`. This is in a different stack
   from defect 12, so step 11 needs a second `terraform apply` that the guide does not mention at all.
   Fixed here by adding `aws_ecr_repository.ci` and its lifecycle policy to the shared stack, and a
   `data "aws_ecr_repository" "ci"` plus its ARN in the node policy's `EcrPullPush` statement.
14. **Step 11 prints the ECR token into the build log.** Jenkins runs every `sh` step as `/bin/sh -xe`, so
   each line is echoed with its variables already expanded. The `Log in to ECR` block assigns the password to
   `PASS` and its base64 form to `AUTH`, and build 14's console carries both in full. The token is valid for
   twelve hours and allows push and pull across the whole registry; anyone who can read a build log can use it.
   The guide never mentions shell tracing — its one sentence about masking is about `withCredentials`, a
   different mechanism introduced five steps later. Fixed in the `Jenkinsfile` with `set +x`, which suppresses
   the trace without hiding stdout, so the caller identity still prints. **Mitigation owed:** build 14's log
   still holds the token until it rotates out or the build is deleted.
15. **Step 12's gate uses a flag `trivy convert` does not have.**
   `trivy convert --severity CRITICAL --ignore-unfixed --exit-code 1` exits `FATAL … unknown flag:
   --ignore-unfixed`, so the stage can never pass, in any cluster, on any image. `--ignore-unfixed` belongs to
   the scan commands. This one is unusual for this phase: it fails loudly, names its own cause, and would have
   been caught by running the command once anywhere. Fixed with a `jq` count over the archived report.
16. **Step 13 cannot fetch the reports it tells you to compare.** The check runs `jq` against
   `trivy-report.json` "on the workstation", but that file is a Jenkins build artifact living on the
   controller's PVC. As written the command answers `Could not open file`. The step needs the two
   `kubectl exec` lines that read the artifact out of `/var/jenkins_home/jobs/…/archive/`.
17. **Step 13's digest command prints something else.** `docker buildx imagetools inspect <tag> --format
   '{{.Manifest.Digest}}'` ignored the flag on this workstation and printed the whole manifest listing. The
   value is still there, on the `Digest:` line, but the step's stated expected output — "two `sha256:…` lines"
   — does not match what a reader sees.
18. **Step 14 signs with flags cosign v3 has removed.** `cosign sign --tlog-upload=false` is deprecated and
   refuses to run beside v3's default signing config; `cosign attest` has no `--tlog-upload` at all, and no
   `--rekor-url` or `--offline` either. The stage fails on `main`, where the signature is real. The step's own
   pre-flight check would not have caught it: it greps `sign --help` and `verify --help` and never `attest`,
   and the flag it greps for does appear in `sign`'s help — inside an example line kept from v2. Fixed with a
   service-free signing config created in the stage.
19. **Step 10 does not state that it depends on step 9.** Step 9 is what proves a build pod can start at all and
   carries the CI role; step 10's `Jenkinsfile` deliberately drops the `cloud 'kubernetes'` and
   `namespace 'jenkins-agents'` lines *because* step 9 has already proved them. Skipping step 9 therefore turns
   a loud error into a silent queue, and step 10 has no "Before you start" line saying so, unlike the Parts.

20. **Step 16's readiness check accepts a pod that is not ready.** It filtered the `Ready` condition by type
   and not by status, so a pod still starting answered with the time its `Ready` condition went *False* —
   about when the pod was created. Criterion #8 came out eleven seconds short, and the only reason it was
   caught is that `creationTimestamp` and `Ready` were the same second, which is not credible for a pod with
   an init container. **The fifth check in this phase that passed while the thing it guarded was broken.**
   Fixed with `.status=="True"`, which introduced a second problem the fix had to cover: the filter then
   yields nothing for a pod that is not ready, `@tsv` prints two columns instead of three, and the image
   slides into the Ready column. A `// "not-ready-yet"` fallback keeps the shape.
21. **Step 16's wait on Argo CD does not wait.** `kubectl wait … {.status.sync.status}=Synced` is satisfied by
   the *previous* commit's sync and returns at once, so the reader measures the pod on its way out. And
   `Synced` is not "the new pod serves" in any case. Replaced with `kubectl rollout status`.
22. **Step 18 would have undone step 11.** Its replacement ECR statement lists the app repository alone, but
   step 11 had added the tools repository to that same statement so the kubelet could pull the `tools`
   image. Following step 18 literally puts that container back into `ImagePullBackOff`, three steps away from
   the change that caused it. Step 18 predates step 11 having any node-role change at all.
23. **Step 18's pod check runs `aws sh -c …`.** The `aws-cli` image has `ENTRYPOINT ["aws"]`, so without
   `--command` kubectl passes the shell line to `aws` as arguments and the pod answers `Found invalid choice
   'sh'`. A check written to tell a denial apart from a breakage fails in the one way that looks like a
   breakage. The app guide's equivalent passes arguments `aws` really takes, so it never exposed this.

**Part 1.** None: every check of Part 1 behaved as the guide expected, except the two shell mistakes in the guide
itself (an unset variable in the Ansible command, and one in step 2's gate), which were fixed in the guide.

## Still to check

- **Nothing checks that a block the guide hands over actually landed.** Rule 5 greps a file you filled in for
  leftover placeholders; it cannot see a block you never pasted. In step 11 the `aws-token` volume was missed
  while its `volumeMount` was not, which the API server would have rejected at pod creation with
  `spec.containers[1].volumeMounts[0].name: Not found`, after a push and a scan. **Closed since:** rule 6 in
  `guide.md`, with `docs/jenkins/check-blocks.py`, run on the workstation as step 2 of the push loop.
- **A positive control for step 12's gate.** It has never returned anything but `0`. Lowering the severity to
  `MEDIUM` for one build would exercise the failure path against `pip`'s five fixable findings. **Answered in
  the drills phase:** branch build 2 ended `Finished: FAILURE` at the Scan gate on 6 fixable findings
  ([`drills.md`](drills.md), M4).
- **Whether `--import-cache` should be in the `Test` stage at all,** given that no login exists there. Either
  it moves after `Log in to ECR`, or it goes, or the step says the `401` is expected. Measured cost today: none,
  beyond a full rebuild every time and an `ERROR` line that reads like a failure.
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
  fail. Note that the repository is public, so cloning proves nothing about the token either. **Answered:** the
  bot pushed `6fb3638` in step 16 and opened pull request #2 in step 17, both with that credential.
- The `hostNetwork` and `privileged` refusals (step 7). Only the `hostPath` refusal and the accept were run, so
  **six** of the policy's seven rules are still unexercised.
- The rest of step 8's post-sync checks: admin password length, the PVC on `gp3`, the StorageClass reclaim
  policy, and two Roles plus two RoleBindings in `jenkins-agents`.
- Whether `main` carries a ruleset. The anonymous clone shows the repository is readable without a credential,
  but nothing yet shows a direct push to `main` is allowed, which step 16 depends on. **Answered:** the bot's
  `6fb3638` was pushed straight to `main` (step 16).

- The stage durations and the commit-to-Ready time of criterion #8 (step 16). **Answered:** commit to dev pod
  Ready in 19 m 08 s (step 16); the per-stage durations were not all recorded.
- Trivy counts of the hardened image, as the "after" of criterion #9 (step 13). **Answered** in step 13:
  CRITICAL 5 → 0, total 269 → 158.
- `cosign verify` on an image the pipeline signed, and the failure on the unsigned one (step 14).
  **Answered** in step 14.
- The node role's `AccessDenied` on push and sign, and the green build after it (step 18). **Answered** in
  step 18.
- **The whole of step 19** (not run, see above): the rebuild timings, a release on the rebuilt cluster, the
  lifecycle preview once more than 30 images exist, and the repository's size and untagged count. **The rebuild
  timings were answered in the drills phase** (see the note under step 19). A release on the rebuilt cluster is
  still open: the pipeline reached the bot's dev commit (`624a8e2`), but nobody followed it to a Ready pod. The
  lifecycle preview and the repository size are still open too.
- The build pod's real CPU and memory, from Prometheus (Part 3).
