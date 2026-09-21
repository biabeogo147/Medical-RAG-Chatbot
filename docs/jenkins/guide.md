# Jenkins guide

A step-by-step guide that hands the image build and the dev and prod updates to Jenkins, running inside the
cluster and installed by Argo CD. Every commit on `main` is tested, built, scanned and signed, then deployed
to dev by a bot commit, and proposed for prod as a pull request. Argo CD stays the only thing that changes
the cluster. The architecture and the decisions behind it are in [`README.md`](README.md) next to this file.
Every file is commented, so the code you copy explains itself. Follow the steps in order: each one ends with
a check, and the next step assumes it passed.

**Before step 1:** read *The big picture* and sections 1, 2, 6, 7 and 8 of [Concepts](guide/0-concepts.md),
about 20 minutes. That page explains, in plain terms, every idea this guide uses: CI and CD, the Jenkins
controller and its agents, Jenkinsfiles, Multibranch jobs, configuration as code, BuildKit, rootless
containers and AppArmor, Pod Security, the pipeline's AWS role, CVEs and Trivy, SBOMs, cosign and KMS, the bot
that writes to Git, and how the pipeline is measured. Its table says which sections to read before which
step.

## How this guide works

**Start here when** the [app guide](../app/guide.md) is finished: dev and prod run from the chart, and every
Application is `Synced` and `Healthy`.

**Where commands run.** No ops tool is installed on your laptop.

| Where | What you do there |
|---|---|
| **Laptop:** editor + Git Bash, browser | Write the files shown in each step, commit, push to GitHub. With WireGuard on, open the Jenkins UI |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager | `git pull`, `make`, `terraform`, `kubectl`, `docker`, `aws`, `cosign`, checks |

The workstation already has what this guide uses: terraform, ansible, kubectl, helm, yq, jq, docker with
buildx, the AWS CLI, cosign and gh. Trivy is not installed; it runs as a pinned container with `docker run`.
No step installs a tool.

**Every step has the same shape:** problem now → why it matters → this step → after it (what works, what proves
it, what is still missing) → files → checks → record.

The rules from the earlier guides still hold, plus rules 5 and 6, which this phase added after an unfilled
placeholder reached the cluster:

1. **Check before it takes effect.** For Terraform, a plan with an exact count: if the count differs, type
   `no`. For anything Argo CD applies, a check on a temporary branch first (below).
2. **One step, one push.** Before each push, `git status --short` lists exactly the files in the step's table.
3. **Stop at a warning box.** A box that starts with **Shared state** or **Irreversible** runs a read first and
   says what it must print. Anything else: stop.
4. **Nothing is assumed silently.** Step 1 measures what the later steps depend on. Parts 2–4 are written from
   its results.
5. **A file you filled in is checked for leftovers.** Steps 8, 9 and 11 hand you a file with `<version>`,
   `<aws-cli version>`, `<tag>` or `<digest>` to replace. (Step 13 asks you to *append* a digest, so it hands
   over no slot.) Nothing downstream validates them — they are valid YAML, valid Groovy and a
   valid Dockerfile line — so the failure surfaces much later, as a crash loop or a 404. Before each push:
   `grep -nE '<[A-Za-z][A-Za-z0-9_ -]*>' <the files in the step's table>` must print nothing you cannot
   account for. **The space in that character class is load-bearing:** step 9 hands over `<aws-cli version>`,
   and the obvious pattern without it matches nothing and reports success. It also matches prose — step 11's
   Terraform carries `"release-<tag>"` and `_acme-challenge.<domain>` inside comments — so read each hit and
   decide: a slot, or a sentence describing a shape. Presence is not content either: a value that is well-formed
   but wrong passes this, so each of those steps also proves its value resolves.
6. **A block you never pasted is invisible to rule 5.** That grep finds what you left unfilled, not what
   you left out, and the second is worse: the file still parses, the push still goes, and the failure
   arrives much later. Here it was step 11's `aws-token` volume, missed while its `volumeMount` was not;
   the API server would have refused the pod with `volumeMounts[0].name: Not found`, one scan and one
   build after the mistake. So on the **workstation**, in step 2 of the loop below, after
   `git checkout --detach origin/jenkins/step-N` and before moving `main`:
   ```bash
   python3 docs/jenkins/check-blocks.py <the step's guide file> <step number> <the files in its table>
   ```
   After step 15, for example:
   ```bash
   python3 docs/jenkins/check-blocks.py docs/jenkins/guide/3-pipeline.md 15 Dockerfile Jenkinsfile .dockerignore
   ```
   Expected: `step 15: all 3 blocks present (0 skipped)`. It runs on the workstation because that is where
   Python is; the laptop has only Git and an editor. Run it **for that step, at that time** — later steps
   edit earlier steps' blocks on purpose, so the same check afterwards reports as missing what is merely
   newer. Blocks carrying a `<placeholder>` are skipped and named, because rule 5 covers those; a step whose
   changes are given in prose reports `NO BLOCKS to check` rather than a pass.
7. **Expected output is specific:** a count, a string, an ARN.
8. **Full resource names in kubectl:** `applications.argoproj.io`, not `app`.

**Versions:** Kubernetes 1.36.4, Argo CD v3.5.3, Jenkins Helm chart 5.9.63, BuildKit v0.33.0, Trivy 0.74.0,
cosign v3.1.3, gh 2.100.0. Region `ap-southeast-1`.

## Roadmap

| Part | Step | Before this step | Result | How it helps | Still missing after | Check before | Done when |
|---|---|---|---|---|---|---|---|
| [1](guide/1-measure-and-foundations.md) | [1](guide/1-measure-and-foundations.md#step-1--measure-before-building-anything) | The "before" CVE numbers come from another scanner; nobody knows the nodes' free room, or whether rootless BuildKit runs on Ubuntu 24.04 | Trivy report of prod's image, free room per node while the app runs, AppArmor setting, a rootless BuildKit test build | Parts 2 and 3 are written from measurements, not guesses | Nothing protects the image prod runs from ECR's clean-up | – | Counts recorded; the test build's result recorded; the test namespace deleted |
| [1](guide/1-measure-and-foundations.md) | [2](guide/1-measure-and-foundations.md#step-2--keep-the-images-prod-may-run) | ECR keeps the last 20 images, so enough builds would delete the image prod runs | A first lifecycle rule keeps 10 `release-*` images; prod's image tagged `release-…` | Prod's image, and rollbacks, survive any number of builds | No AWS identity for the build pods | plan: 0 to add, 1 to change; `release-` tag absent | Two rules in that order; both tags on one digest |
| [1](guide/1-measure-and-foundations.md) | [3](guide/1-measure-and-foundations.md#step-3--an-aws-role-for-the-build-pods) | Build pods would use the node role, which can read eight secrets and write several buckets | Role `medical-rag-ci`: ECR push, KMS sign, corpus checksum, only for `jenkins-agents:jenkins-agent` | A compromised build can push and sign, and nothing more | Jenkins has no name reachable through the VPN | plan: 2 to add | Trust names only `jenkins-agents:jenkins-agent`; simulator: 3 allowed, 3 denied |
| [1](guide/1-measure-and-foundations.md) | [4](guide/1-measure-and-foundations.md#step-4--a-name-for-jenkins) | Jenkins has no name under the domain | `jenkins.recruitai.io.vn` → internal load balancer | Jenkins will open only through the VPN, with the wildcard certificate | The nodes may still refuse rootless BuildKit | plan: 1 to add | Same addresses as `argocd.`; `404` through the VPN |
| [1](guide/1-measure-and-foundations.md) | [5](guide/1-measure-and-foundations.md#step-5--let-rootless-buildkit-run-on-the-nodes-only-if-step-14-failed) | *Only if step 1.4's test build failed:* Ubuntu refuses BuildKit its user namespace | An AppArmor profile for BuildKit on every node | Rootless builds run, while every other program keeps Ubuntu's rule | No namespaces, no Jenkins | written from step 1's error | The test build succeeds on every node; second `make cluster`: `changed=0` |
| [2](guide/2-jenkins.md) | [6](guide/2-jenkins.md#step-6--namespaces-credentials-and-network-rules) | Jenkins has nowhere to run and no credentials | Application `jenkins-platform` (wave 3): namespaces `jenkins` (baseline) and `jenkins-agents` (privileged), the build pods' ServiceAccount and RBAC, the admin password generated in the cluster, the GitHub token through External Secrets, IMDS blocked | Credentials exist without being in Git; no Jenkins pod can reach the node role | If `jenkins-agents` must be `privileged`, it accepts any pod | temporary branch: dry run | Secrets exist; a test pod in each namespace gets no answer from IMDS |
| [2](guide/2-jenkins.md) | [7](guide/2-jenkins.md#step-7--narrow-what-the-build-namespace-accepts) | `jenkins-agents` is `privileged`, so it accepts host paths and privileged containers | A ValidatingAdmissionPolicy and its binding for that namespace | Only what BuildKit needs is allowed | No Jenkins | temporary branch: dry run | A pod with a hostPath is refused; the build pod's shape is accepted |
| [2](guide/2-jenkins.md) | [8](guide/2-jenkins.md#step-8--jenkins-itself) | No CI | Application `jenkins` at wave 4: pinned chart and plugins, JCasC (including the Multibranch job), one build pod at a time, home volume, Ingress through the VPN | Jenkins runs, configured entirely from Git | Nothing proves a build pod gets the CI role | temporary branch: `helm template` and dry run | UI opens through the VPN; `root` `Healthy`; the home volume is `gp3` with reclaim `Delete`, and the Application carries the volumes label |
| [2](guide/2-jenkins.md) | [9](guide/2-jenkins.md#step-9--prove-the-build-pods-identity) | Nothing proves the build pods get the right identity | An identity-test `Jenkinsfile`, built on a temporary branch | The build pod's AWS identity is `medical-rag-ci`, and IMDS is closed | Nothing is built, and nothing decides which commits need a build | branch build only | `get-caller-identity` shows `medical-rag-ci`; IMDS times out |
| [3](guide/3-pipeline.md) | [10](guide/3-pipeline.md#step-10--only-build-what-should-be-built-and-test-it-first) | Every commit would start a build, the bot's own commits included | Skip guard, and the tests in a build with no registry login | Only real code changes are built, and they are tested first | The pipeline still produces no image | branch build | A docs-only commit ends `NOT_BUILT`; the test stage passes |
| [3](guide/3-pipeline.md) | [11](guide/3-pipeline.md#step-11--the-tools-image-and-the-app-image) | Images are built by hand | The CI tools image, then BuildKit build and push with the cache in ECR | Every commit becomes an image; cold and warm build times known | Nothing scans it | shared plan: 2 to add; cluster plan: 1 to change | Image `<commit>` in ECR; the cache reused on the second build |
| [3](guide/3-pipeline.md) | [12](guide/3-pipeline.md#step-12--the-gate-no-image-with-a-fixable-critical) | Images are not scanned | Trivy gate and report | A fixable CRITICAL stops the build before anything is signed or promoted | The unfixed findings are still there | branch build | The first run's result recorded as the "before" |
| [3](guide/3-pipeline.md) | [13](guide/3-pipeline.md#step-13--fewer-findings-in-the-base-image) | 5 CRITICAL and 55 HIGH findings, none with a fix | Base image on Debian 13, pinned by digest | Fewer findings, and the next base change is deliberate; criterion #9's "after" | Images are not signed | branch build; test stage | Green run; Trivy counts before and after |
| [3](guide/3-pipeline.md) | [14](guide/3-pipeline.md#step-14--sign-what-was-built) | Nothing proves who built an image | SBOM from Trivy, signature and attestation with the KMS key | Every image on `main` is signed; its package list is kept | Nothing checks the index version, and dev is still updated by hand | branch build, without signing: signing is first proven on `main` | `cosign verify` passes on the workstation |
| [3](guide/3-pipeline.md) | [15](guide/3-pipeline.md#step-15--notice-when-the-corpus-changes) | A corpus change would go unnoticed | Index version check with the S3 checksum | A new corpus version is deployed only if its PDF is already in S3 | Dev is updated by hand | branch build | Same version: nothing changes; a mismatch stops before any Git write |
| [3](guide/3-pipeline.md) | [16](guide/3-pipeline.md#step-16--the-bot-updates-dev) | Dev is updated by hand | The bot commits the new tag to dev's values | Commit to dev without a command; criterion #8 measured | Prod is updated by hand | branch build, without pushing: the push is first proven on `main` | A commit on `main` reaches a Ready dev pod; minutes recorded |
| [3](guide/3-pipeline.md) | [17](guide/3-pipeline.md#step-17--prod-by-pull-request) | Prod is promoted by hand | A pull request for prod; the image that reaches prod tagged `release-…`; ruleset on `main` | Prod changes by a reviewed merge; criterion #10 | The node role can still push and sign | branch build, without the pull request | The bot's pull request is merged; prod runs the image, which carries `release-…` |
| [4](guide/4-close-out.md) | [18](guide/4-close-out.md#step-18--take-push-and-sign-away-from-the-node-role) | Any pod on the node role can push and sign | ECR push and KMS sign removed from the node role | Only the build pods can sign | No proof the phase survives a rebuild | plan: 1 to change | A pod on the node role gets `AccessDenied`; the pipeline still signs |
| [4](guide/4-close-out.md) | [19](guide/4-close-out.md#step-19--a-rebuild-the-clean-up-and-the-evidence) | Nothing shows Jenkins survives a rebuild | Rebuild; lifecycle preview with enough images; `k8s.yaml` removed; evidence and answers completed | The whole phase would be reproducible and its limits measured — **step 19 was not run** | What is out of scope ([README](README.md#10-known-limits-and-what-is-out-of-scope)) | – | Rebuilt cluster runs a green pipeline; the preview keeps every `release-*` image; no volume left after `make down` |

**Parts:** [0. Concepts](guide/0-concepts.md) · [1. Measure, then lay the foundations](guide/1-measure-and-foundations.md) ·
[2. Jenkins itself](guide/2-jenkins.md) · [3. The pipeline](guide/3-pipeline.md) · [4. Close out](guide/4-close-out.md) ·
[Troubleshooting](guide/troubleshooting.md)

Parts 2, 3 and 4 were written after step 1 had measured the nodes (2026-09-20): the build pods' Pod Security level,
their resource requests and the hardening step's goal all come from those numbers
([evidence](../evidence/jenkins.md)).

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
   tmux new -As jenkins                   # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot
   git pull
   ```
3. **Workstation:** run the step's checks, in the order the step gives them.

### Checking a change before it reaches main

From Part 2 on, a push to `main` is a deploy: Argo CD applies it within minutes. As in the app guide, a
change is first pushed to a temporary branch and checked on the workstation; only then does `main` move to
the same commit. The branches are named `jenkins/step-N`:

1. **Laptop:** `git push origin HEAD:jenkins/step-N`.
2. **Workstation:** `git fetch origin`, then `git checkout --detach origin/jenkins/step-N`, then
   `python3 docs/jenkins/check-blocks.py <guide file> <step> <the files in the step's table>` (rule 6), then
   the step's check before the push.
3. **Laptop,** only if every check passed: `git push origin HEAD:main`, then
   `git push origin --delete jenkins/step-N`.
4. **Workstation:** `git checkout main`, then `git pull`, then `git log -1 --oneline`, which must show the
   step's commit.

From step 9 on, Jenkins also builds these branches: the test, build and scan stages run on them, and only
`main` signs and promotes. Argo CD never reads them.

**tmux windows.** Window 0 for everything. Window 1 for `make tunnel`, open whenever a step uses kubectl.

**Record as you go.** Each step ends with **Record**. Copy those outputs into `docs/evidence/jenkins.md`
**on the laptop**, while they are on the screen, and commit that file on its own before the next step
(message `Evidence: jenkins step N`). Never edit it on the workstation: its working tree must stay equal to
Git.

---

Start with [Concepts](guide/0-concepts.md), then [Part 1: Measure, then lay the foundations](guide/1-measure-and-foundations.md).
