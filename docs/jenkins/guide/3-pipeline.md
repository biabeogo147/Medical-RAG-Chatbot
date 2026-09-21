# Jenkins guide — Part 3: The pipeline (steps 10–17)

[← Part 2](2-jenkins.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 2 is done: Jenkins runs, and step 9 proved that a build pod gets the role
`medical-rag-ci` and cannot reach the node's metadata service. Read section
[10](0-concepts.md#10-pipeline-as-code-the-jenkinsfile) of Concepts, which is the syntax every step below uses,
then sections [15](0-concepts.md#15-base-images-and-hardening) to
[21](0-concepts.md#21-measuring-the-pipeline).

**Done when:** a commit on `main` becomes a tested, scanned and signed image, dev runs it without anyone typing a
command, and prod is proposed as a pull request.

**How this part is written.** Each step adds stages to the `Jenkinsfile` and proves them on a temporary branch
first. Signing, the dev push and the prod pull request only run on `main`, so those three are proven on `main`
itself, once, right after the branch check of everything else. Each step says so where it applies.

**One thing changes from the design.** cosign and `gh` publish images with no shell, and the Jenkins Kubernetes
plugin runs every step through a shell inside a container. Rather than download those tools on every build, step
11 builds one small *tools image* that holds them, pushes it to ECR, and pins it by digest. Trivy can write the
SBOM in the same SPDX format as Syft, so Syft is not needed at all.

---

## Step 10 — Only build what should be built, and test it first

**Before you start: step 9 must have passed.** It is what proves a build pod can start at all and that it
carries the CI role, and the `Jenkinsfile` below drops the `cloud 'kubernetes'` and `namespace 'jenkins-agents'`
lines *because* step 9 already named them explicitly and they worked. Skip step 9 and a missing or misnamed
cloud stops being an error message and becomes a build that queues forever with nothing to read.

**Problem now.** Jenkins builds every commit it sees on `main` and on the temporary branches. When the pipeline
starts writing to Git, its own commits would start new builds, forever
([concepts §18](0-concepts.md#18-writing-back-to-git)). And nothing runs the tests before an image is built.

**Why it matters.** A loop wastes the quota and the nodes, and a docs commit should not spend three minutes of
CPU. Tests must run before anything is pushed, so that no image exists for code that does not pass.

**This step.** Two stages:
- **Skip guard:** end the build as `NOT_BUILT` when the author is `jenkins-bot`, or when every changed file is
  under `deploy/`, under `docs/`, or ends in `.md`.
- **Test:** build the Dockerfile's `test` target in BuildKit. No registry login exists at this point in the
  pipeline, so the repository's own code runs without any credential
  ([concepts §5](0-concepts.md#5-the-pipelines-aws-identity)).

**After this step.**
- Works: only real code changes are built, and they are tested first.
- Proven by: a docs-only commit ends `NOT_BUILT`; a code commit runs ruff and pytest and reports `26 passed`.
- Still missing: no image is produced yet → step 11.

| File | Change |
|---|---|
| `Jenkinsfile` | Replaced: the pod definition plus the first two stages |

**Laptop.** Replace the whole `Jenkinsfile` with:
```groovy
// The pipeline for this repository (Jenkins guide, Part 3). Every tool version is pinned here, so a change
// of tool is a commit like any other.
//
// Stages that write anything outside the build pod run only on main: signing, the dev bump and the prod pull
// request. Branch builds test, build and scan, and stop there.
//
// The pod's identity was proved separately in step 9: a build pod reaches AWS as medical-rag-ci and the
// metadata service does not answer it. See docs/evidence/jenkins.md.

// Values that appear in more than one place. No `def`: that would make them local to one method, and the
// closures below (the pod definition, every sh line) would not see them.
ACCOUNT   = '242834061265'
REGION    = 'ap-southeast-1'
REGISTRY  = "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE     = "${REGISTRY}/medical-rag"
BUILDKIT  = 'moby/buildkit:v0.33.0-rootless'

pipeline {
  agent {
    kubernetes {
      defaultContainer 'buildkit'
      yaml """
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  automountServiceAccountToken: false
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
  containers:
    - name: buildkit
      image: ${BUILDKIT}
      command: ["sleep"]
      args: ["3600"]
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
      securityContext:
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
      resources:
        requests:
          cpu: 300m
          memory: 1Gi
        limits:
          memory: 3Gi
      volumeMounts:
        - name: buildkitd
          mountPath: /home/user/.local/share/buildkit
  volumes:
    - name: buildkitd
      # BuildKit's local cache. Bounded, so a runaway build cannot fill the node's disk.
      emptyDir:
        sizeLimit: 8Gi
"""
    }
  }

  options {
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  stages {
    stage('Skip guard') {
      steps {
        script {
          // The author of the newest commit, and the files it changed.
          def author = sh(returnStdout: true, script: 'git log -1 --format=%an').trim()
          def files  = sh(returnStdout: true, script: 'git show --pretty= --name-only HEAD').trim()
          def onlyDocs = files && files.split('\\n').every { f ->
            f.startsWith('deploy/') || f.startsWith('docs/') || f.endsWith('.md')
          }
          // An empty list means "unknown", and unknown counts as a build: skipping on doubt hides changes.
          if (author == 'jenkins-bot' || onlyDocs) {
            currentBuild.result = 'NOT_BUILT'
            error("Nothing to build: author=${author}, only docs or deploy files changed")
          }
        }
      }
    }

    stage('Test') {
      steps {
        // The Dockerfile's test target runs ruff and pytest. No registry login exists yet, so the
        // repository's own code runs with no credential of any kind.
        sh """
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt target=test \
            --import-cache type=registry,ref=${IMAGE}:buildcache
        """
      }
    }
  }
}
```

**Why:**

- **`NOT_BUILT`, not success.** A skipped build is visible as skipped in the job's history, so a loop or a wrong
  guard shows up immediately.
- **`error()` after setting the result.** Declarative pipelines have no "stop here"; raising an error after setting
  the result ends the build with that result.
- **The guard reads Git, not Jenkins' change sets.** A branch's first build has no change set at all, and that
  must count as "build".
- **The tests run in BuildKit.** The same `--target test` you run locally and in `make image`: one definition of
  what "tests pass" means.
- **`disableConcurrentBuilds()` and the cloud's cap.** The first stops two builds of the same branch, the second
  (step 8) stops two branches at once.
- **A fourth container you did not write.** The plugin adds one named `jnlp`, the agent program that talks to the
  controller ([concepts §12](0-concepts.md#12-build-pods)). Whether it carries requests of its own depends on the
  plugin's defaults, so the check below reads the pod's real total instead of trusting the arithmetic.

**Check** on a temporary branch (`git push origin HEAD:jenkins/step-10`). In the UI, the branch builds:

1. The console log contains **three** `[Pipeline] stage` lines: `Declarative: Checkout SCM`, which the plugin
   adds before anything in the file, then `Skip guard` and `Test`. Counting two and stopping reads a correct
   build as broken. **`Finished: SUCCESS` on its own proves nothing:** when the Declarative plugin
   was refused at startup, builds here ran the constants and went straight from `[Pipeline] Start of Pipeline`
   to `[Pipeline] End of Pipeline`, reporting success with no stage at all. *Why* that shape and not a failure
   is **not established** — a missing step normally throws `No such DSL method` and fails the build, and no
   such line was ever found in those consoles. Either way the observation is the signal. If that is what you
   see, the pipeline is fine and Jenkins is not: go to
   [step 8's plugin-load check](2-jenkins.md#step-8--jenkins-itself). Note what this does *not* prove: the
   `stage` step comes from `pipeline-stage-step`, which loads independently, so stage lines mean "a stage ran",
   not "the Declarative plugin is healthy" — that is what the plugin-load check is for.
2. The `Skip guard` stage passes, because this commit changes `Jenkinsfile`.
3. The `Test` stage ends with BuildKit's `DONE` lines, and the log contains `26 passed`.

**Two things in that log look wrong and are not.**

Between `[Pipeline] node` and the pod being ready, Jenkins prints `Still waiting to schedule task` and `Waiting
for next available executor`, once every few seconds. That is the queue, not a fault: the pod is being created
and its images pulled, which took 19 seconds and 348 MB the first time here. The plugin waits ten minutes
(`waitForPodSec`) before giving up. Read `kubectl -n jenkins-agents get events` if you want to watch it happen.

And the `Test` stage prints an error while passing:

```
#6 importing cache manifest from …/medical-rag:buildcache
#6 ERROR: failed to configure registry cache importer: … 401 Unauthorized
```

`--import-cache` needs a registry login, and this stage deliberately has none — that is the step's own security
argument, and `Log in to ECR` does not exist until step 11. So the flag cannot work where it is written, in this
build or any later one. BuildKit treats a failed cache import as non-fatal and builds from scratch. Leave it:
step 11 puts the same flag in a stage that *is* logged in, and the two stages share the wording.

Then read what the pod actually asked for. Do **not** try to catch it with `kubectl get pods`: `podRetention:
Never` deletes it the moment the build ends, and an empty table looks exactly like "no pod was ever created".
Read it from Prometheus instead, where kube-state-metrics keeps the series after the pod is gone — the same
`promq` helper the app guide used, since this cluster has no metrics-server
([app guide step 16](../../app/guide/3-dev.md)):
```bash
promq() {
  local q
  q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" \
    | jq -r '.data.result[] | "\(.metric.pod) \(.metric.container // "-") \(.value[1])"'
}
promq 'max_over_time(kube_pod_container_resource_requests{namespace="jenkins-agents",resource="cpu"}[3h])'
promq 'sum by (pod) (max_over_time(kube_pod_container_resource_requests{namespace="jenkins-agents",resource="cpu"}[3h]))'
kubectl -n jenkins-agents get events --sort-by=.lastTimestamp | tail -20
```
Expected: one line per container, including a `jnlp` you did not write, then one line with the pod's total and
`-` in place of a container name. The metric is in **cores**, not millicores: `0.4` means 400m. That total is
what the build pod costs a node, and it must fit the free CPU of whichever node scheduled it — step 1.2 measured
560m, 775m and 720m **before** Jenkins existed, and the controller has since taken 250m of one of them. Steps 11
and 12 add a container each, so the total grows.

**If the first two commands print nothing, that is not a pass.** The events separate three cases, and only the
last is a step 8 problem:
- `Scheduled` / `Created` / `Started` for a `medical-rag-…` pod, and the build was short: the pod may simply
  have lived less than one scrape interval, so no sample exists. Run a longer build and repeat.
- The same events, and the build was not short: the series is missing, so check kube-state-metrics was scraping
  *at that time* — `promq 'count_over_time(up{job="kube-state-metrics"}[3h])'`, not `up`, which only speaks for
  now.
- No such events at all: the cloud never created a pod, which belongs to step 8.

Record which of the three.

Then push a docs-only commit to the same branch, for example a line added to `docs/evidence/jenkins.md`:
Expected: the build ends `NOT_BUILT`, with `Nothing to build: author=…` in the log, and no `Test` stage.

**Move `main`** to the branch's first commit, the one that added the `Jenkinsfile`, not the docs commit:
```bash
git push origin <the Jenkinsfile commit>:main
git push origin --delete jenkins/step-10
```

**Record** both build results and the test line.

---

## Step 11 — The tools image, and the app image

**Problem now.** Nothing pushes an image. Two things are missing: a container that holds the tools the later
stages need (cosign, git, the AWS CLI, `gh`, `yq`, `jq`), and the stage that builds and pushes the app image.

**Why it matters.** The official images for cosign and `gh` have no shell, and Jenkins runs every step through a
shell. Downloading those tools on every build would add time and a network dependency to each run. One small image,
built once from a Dockerfile in this repository and pinned by digest, keeps every version in Git.

**This step.**
- `ci/Dockerfile`: the tools image, from Alpine, with pinned versions and checksums.
- `make ci-image`: build and push it from the workstation, once. Later versions go through the pipeline like any
  other change.
- Two pipeline stages: log in to ECR in the tools container, then build the `runtime` image in BuildKit and push
  it with the cache in ECR.

**After this step.**
- Works: every branch and `main` build produces an image in ECR.
- Proven by: the image appears with the commit as its tag; the second build reuses the cache and is much faster.
- Still missing: nothing scans the image → step 12.

| File | Change |
|---|---|
| `infra/terraform/shared/registry.tf` | New: the ECR repository for the tools image, and its lifecycle rule |
| `infra/terraform/cluster/main.tf` | New: a data source for that repository |
| `infra/terraform/cluster/iam.tf` | The node policy's ECR statement names it too |
| `ci/Dockerfile` | New: the tools image |
| `Makefile` | New target `ci-image` |
| `Jenkinsfile` | Two stages, and the tools container in the pod |

**Laptop.** Create `ci/Dockerfile`:
```dockerfile
# The tools the pipeline needs, in a container with a shell. cosign and gh publish images without one, and the
# Jenkins Kubernetes plugin runs every step through a shell, so they are collected here instead.
# Everything is pinned and checked against a published checksum, like the ops workstation's own setup.
# Pinned by digest, for the same reason as the app's base image (step 13). On the workstation,
# `docker buildx imagetools inspect alpine:3.22` prints it on the `Digest:` line, above `Manifests:`.
# Take that one: it is the digest of the whole multi-platform index. The indented `Name: …@sha256:…`
# lines below it are single architectures and attestation manifests, and pinning one of those pins
# the image to one platform or to something that is not the image at all.
FROM alpine:3.22@sha256:<digest>

ARG COSIGN_VERSION=v3.1.3
ARG GH_VERSION=2.100.0

# aws-cli, git, yq and jq come from Alpine's own repositories, so apk pins them to this Alpine release.
RUN apk add --no-cache aws-cli git yq jq curl openssl ca-certificates

# cosign and gh are released as binaries with checksum files.
RUN curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
 && curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt" \
 && grep " cosign-linux-amd64$" cosign_checksums.txt | sha256sum -c - \
 && install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
 && grep " gh_${GH_VERSION}_linux_amd64.tar.gz$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && install -m 0755 "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf cosign-linux-amd64 cosign_checksums.txt gh_* \
 && cosign version && gh --version && aws --version && yq --version && git --version

# A real user, so that HOME exists and anything that writes a cache (git, gh, aws) has somewhere to put it.
RUN adduser -D -u 1000 ci
USER ci
ENV HOME=/home/ci
```

In the `Makefile`, after the `image` target, add:
```make
# The pipeline's tools image, built on the workstation. It changes only when a tool version changes, so it is
# not built by the pipeline itself; that would need the tools it is building.
CI_IMAGE_TAG = $(shell git rev-parse --short=12 HEAD)

.PHONY: ci-image

ci-image:
	@test -z "$$(git status --porcelain)" || { echo "Uncommitted changes: commit and push first"; exit 1; }
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(REGISTRY)
	docker buildx build --progress=plain --provenance=false --sbom=false \
	  --tag $(REGISTRY)/$(PROJECT)-ci:$(CI_IMAGE_TAG) --push ci
	aws ecr describe-images --region $(REGION) --repository-name $(PROJECT)-ci \
	  --image-ids imageTag=$(CI_IMAGE_TAG) --query 'imageDetails[0].[imageTags[0],imageDigest]' --output text
```

**Laptop.** In the `Jenkinsfile`, add the tools image to the values at the top:
```groovy
CI_TOOLS  = "${REGISTRY}/medical-rag-ci:<tag>@<digest>"   // printed by `make ci-image`
```
and add this container to the pod, after `buildkit`:
```yaml
    - name: tools
      image: ${CI_TOOLS}
      command: ["sleep"]
      args: ["3600"]
      env:
        - name: AWS_ROLE_ARN
          value: arn:aws:iam::${ACCOUNT}:role/medical-rag-ci
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/aws/token
        - name: AWS_REGION
          value: ${REGION}
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
        # Both containers read the login from the same place in the workspace.
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
      resources:
        requests:
          cpu: 50m
          memory: 192Mi
        limits:
          memory: 512Mi
      volumeMounts:
        - name: aws-token
          mountPath: /var/run/secrets/aws
          readOnly: true
```
and this volume, next to `buildkitd`:
```yaml
    - name: aws-token
      projected:
        sources:
          - serviceAccountToken:
              audience: sts.amazonaws.com
              expirationSeconds: 3600
              path: token
```
`buildkit` also needs the login, so add to its `env`:
```yaml
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
```

Then add two stages after `Test`:
```groovy
    stage('Log in to ECR') {
      steps {
        container('tools') {
          // The token in the pod is exchanged for the CI role here; the login lands in the shared workspace,
          // so BuildKit can push with it. The tests above ran before this existed.
          sh """
            # Jenkins runs every sh step as `/bin/sh -xe`, which echoes each command with its variables
            # already expanded. Without this line the ECR password and the base64 auth string are both
            # printed into the build log in full, where they stay valid for 12 hours. stdout is not
            # affected, so the caller identity below still prints.
            set +x
            aws sts get-caller-identity --query Arn --output text
            mkdir -p "\${DOCKER_CONFIG}"
            PASS=\$(aws ecr get-login-password --region "\${AWS_REGION}")
            # openssl, not base64: busybox's base64 wraps long lines, which would break the JSON.
            AUTH=\$(printf 'AWS:%s' "\${PASS}" | openssl base64 -A)
            printf '{"auths":{"%s":{"auth":"%s"}}}' "${REGISTRY}" "\${AUTH}" > "\${DOCKER_CONFIG}/config.json"
          """
        }
      }
    }

    stage('Build and push') {
      steps {
        script {
          env.GIT_TAG = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
        }
        // The cache lives in the registry, under the mutable tag buildcache. Branch builds only read it:
        // only main writes it, so a branch cannot poison what main builds from (README §3).
        sh """
          CACHE_EXPORT=""
          if [ "\${BRANCH_NAME}" = "main" ]; then
            CACHE_EXPORT="--export-cache type=registry,ref=${IMAGE}:buildcache,mode=max"
          fi
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt target=runtime \
            --import-cache type=registry,ref=${IMAGE}:buildcache \
            \${CACHE_EXPORT} \
            --output type=image,name=${IMAGE}:\${GIT_TAG},push=true \
            --metadata-file build-metadata.json
        """
        script {
          env.IMAGE_DIGEST = sh(returnStdout: true,
            script: 'grep -o \'"containerimage.digest": *"[^"]*"\' build-metadata.json | cut -d\\" -f4').trim()
          echo "Image ${IMAGE}:${env.GIT_TAG}@${env.IMAGE_DIGEST}"
        }
      }
    }
```

**Why:**

- **The tools image is built on the workstation, not by the pipeline.** A pipeline that needs its own tools image to
  build its own tools image cannot start. It changes rarely: a tool version bump is one commit and one `make`.
- **A separate ECR repository (`medical-rag-ci`).** The app repository's lifecycle rules count images; the tools
  image is not an app release and should not take one of those places.
- **The login is written by the tools container and read by BuildKit.** Only the tools container has the AWS token,
  and the two share the workspace through `DOCKER_CONFIG`. Tests run before this stage, so the code under test
  never sees the login.
- **`sh """` with `\${...}` for shell variables.** Groovy fills in `${REGISTRY}` before the shell runs; anything the
  shell must expand itself is escaped. A single-quoted `sh '''` block would leave `${REGISTRY}` empty, because the
  shell has no such variable.
- **The digest comes from BuildKit's metadata, not from a tag.** That is the digest step 14 signs: a tag could be
  overwritten between push and signature.
- **One tag per build, and not one image per tag.** A commit that reaches this stage but changes nothing that
  enters the runtime image — the `Jenkinsfile` itself, `ci/`, `infra/` — is rebuilt to the same content, and
  the push adds another tag to an image that already exists. Ten tags on one digest is normal and is the
  reproducibility working. (A `docs/` or `deploy/` commit never gets this far: the skip guard ends it as
  `NOT_BUILT` and no tag is added.) Two things follow: the tag records which commit *built* an image, not
  which commit *changed* it, and step 2's lifecycle rules count images rather than tags, so ten tags occupy
  one of the thirty places, not ten.
- **Branches import the cache but never export it.** A malicious branch cannot change what a later `main` build
  starts from.
- **The same commit cannot be pushed twice.** ECR tags are immutable, so rebuilding a commit whose image already
  exists fails at the push. That is deliberate: one commit is one image. Rebuild a *new* commit instead, or delete
  the tag first if you really mean to replace it.

**Laptop.** The tools image needs a repository of its own, created by Terraform like every other AWS resource, so
that a rebuild does not depend on a command someone ran once. In `infra/terraform/shared/registry.tf`, after the
`aws_ecr_repository "app"` block, add:
```hcl
# The pipeline's own tools image (Jenkins guide step 11). Separate from the app's repository, so the app's
# lifecycle rules count app images only.
resource "aws_ecr_repository" "ci" {
  name                 = "${local.name}-ci"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "ci" {
  repository = aws_ecr_repository.ci.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 tools images"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["*"]
        countType      = "imageCountMoreThan"
        countNumber    = 5
      }
      action = { type = "expire" }
    }]
  })
}
```

**Laptop.** The kubelet pulls the tools image with the *node* role, whose ECR statement names the app
repository only, so without this the `tools` container sits in `ImagePullBackOff` however correct the rest
is. In `infra/terraform/cluster/main.tf`, next to the existing `data "aws_ecr_repository" "app"`:
```hcl
# The pipeline's tools image. The kubelet pulls it with the node role, so the node policy must name it
# (Jenkins guide step 11). Created by the shared stack.
data "aws_ecr_repository" "ci" {
  name = "${var.project}-ci"
}
```
and in `infra/terraform/cluster/iam.tf`, in the `EcrPullPush` statement, replace the `resources` line with:
```hcl
    resources = [data.aws_ecr_repository.app.arn, data.aws_ecr_repository.ci.arn]
```

**Check before the push.** Commit `ci/Dockerfile`, the Makefile target and the Terraform block, and push to `main`
(nothing here is applied by Argo CD, so no temporary branch is needed). On the workstation:
Two stacks change here, and they must go in this order: the cluster stack reads the repository the shared
stack creates, so a `data` source for it fails if the repository does not exist yet.
```bash
git pull

make shared-plan          # read the plan before applying it (guide.md rule 1)
make shared               # expect 2 to add, 0 to change, 0 to destroy, then yes

make plan                 # the cluster stack
make infra                # expect 0 to add, 1 to change, 0 to destroy, then yes
```
`make infra`, **not** `make cluster` — `make cluster` runs the Ansible playbook that builds Kubernetes. The one
change is an inline IAM policy; if the plan wants to replace a node or touch a launch template, stop.

Then build and push the image:
```bash
make ci-image
```
Expected: the build, then a line with the tag and digest. Put both into `CI_TOOLS` in the `Jenkinsfile`, in the
form `…/medical-rag-ci:<tag>@<digest>`.

Then check that every image the pod pins exists:
```bash
for I in moby/buildkit:v0.33.0-rootless aquasec/trivy:0.74.0; do docker manifest inspect "$I" >/dev/null && echo "ok $I"; done
```
Expected: `ok` for both.

**Check**, on a temporary branch: the build reaches `Build and push`, and the log ends with
`Image …/medical-rag:<commit>@sha256:…`. Then:
```bash
aws ecr describe-images --repository-name medical-rag --image-ids imageTag=<commit> \
  --query 'imageDetails[0].[imageDigest, imagePushedAt]' --output text
```
Expected: the same digest as the log.

Push one more commit to the branch and compare the `Build and push` stage's duration in the UI: the second build
reuses the cache and is much shorter.

**Record** the two durations, the digest, and the tools image's tag and digest.

**The file so far.** After steps 10 and 11 the `Jenkinsfile` has this shape; every later step adds to it:

```
constants: ACCOUNT, REGION, REGISTRY, IMAGE, BUILDKIT, CI_TOOLS
pipeline
  agent  → pod: buildkit, tools            (+ trivy in step 12)
  options → disableConcurrentBuilds, timestamps, buildDiscarder
  stages
    Skip guard                             (step 10)
    Test                                   (step 10)
    Log in to ECR                          (step 11)
    Build and push                         (step 11)
```

Keep this list in view: each step below says which stage it adds and where.

---

## Step 12 — The gate: no image with a fixable CRITICAL

**Problem now.** The pipeline pushes an image nobody has scanned.

**Why it matters.** Step 1 measured today's image with Trivy: 5 CRITICAL findings, none with a fix
([evidence](../../evidence/jenkins.md)). The gate is not there to stop today's image; it is there so that the day a
patched package exists and the image is still built on the old one, the build stops before that image can be signed
or promoted.

**This step.** One stage that scans the image once into a report, prints the table, then applies the gate to
that report: **CRITICAL findings that carry a fixed version, counted, and the count must be `0`.** Trivy's own
`convert` cannot express that — `--ignore-unfixed` belongs to its scan commands — so the count is a `jq` line
over the report. The report is archived with the build either way.

**After this step.**
- Works: an image with a fixable CRITICAL never reaches the later stages.
- Proven by: the gate passes today, and the archived report shows the same counts as step 1.
- Still missing: those unfixed findings are still there, and the image is unsigned → steps 13 and 14.

| File | Change |
|---|---|
| `Jenkinsfile` | The `trivy` container, and two stages |

**Laptop.** Add the container to the pod, after `tools`:
```yaml
    - name: trivy
      image: aquasec/trivy:0.74.0
      command: ["sleep"]
      args: ["3600"]
      env:
        # Trivy reads the registry login the tools container wrote.
        - name: DOCKER_CONFIG
          value: /home/jenkins/agent/.docker
        - name: TRIVY_CACHE_DIR
          value: /home/jenkins/agent/.trivy
      resources:
        requests:
          cpu: 50m
          memory: 384Mi
        limits:
          memory: 1Gi
```

Add these stages after `Build and push`:
```groovy
    stage('Scan') {
      steps {
        container('trivy') {
          // Scan once, into a report. The gate then reads that report, so the record exists even when the
          // gate fails; scanning first and failing second is the only order that keeps both.
          sh "trivy image --scanners vuln --format json --output trivy-report.json ${IMAGE}@${env.IMAGE_DIGEST}"
          sh "trivy convert --format table trivy-report.json"
        }
        // The gate, in the tools container because it is the one with jq. `trivy convert` has no
        // --ignore-unfixed: that flag belongs to the scan commands, and convert only offers --severity
        // and --exit-code, which together would fail every build on findings nobody can act on. So the
        // gate counts them here instead: CRITICAL findings that carry a fixed version. Unfixed ones are
        // ignored on purpose — a gate that can never pass is a gate people switch off (concepts §2).
        container('tools') {
          sh """
            N=\$(jq '[.Results[]?.Vulnerabilities[]?
                        | select(.Severity == "CRITICAL")
                        | select(.FixedVersion != null and .FixedVersion != "")] | length' trivy-report.json)
            echo "CRITICAL with a fix available: \$N"
            [ "\$N" -eq 0 ]
          """
        }
      }
      post {
        always { archiveArtifacts artifacts: 'trivy-report.json', fingerprint: true, allowEmptyArchive: true }
      }
    }
```

**Why:**

- **The gate scans by digest.** The tag could be moved between the push and the scan; the digest cannot.
- **The gate has never been seen to fail.** Every CRITICAL in this image is unfixed, so `0` is the only answer
  it can give today, and passing shows it does not block wrongly — not that it blocks. To exercise the failure
  path once, run a throwaway build with `CRITICAL` replaced by `MEDIUM`: `pip` carries five findings that do
  have fixed versions, and the gate should go red. Put it back afterwards.
- **One scan, then the gate.** Everything after `trivy image` re-reads the report on disk, so the image is
  pulled and scanned once. Because the report is written before the gate runs, it is archived even when the
  gate fails — which is not hypothetical: the first run of this step failed at the gate and the report survived.
- **Unfixed findings ignored by the gate only.** The report counts everything, so criterion #9 can show both
  numbers; only the gate filters on `FixedVersion`.
- **`TRIVY_CACHE_DIR` gives Trivy somewhere to write; it is not a cache between builds.** It points into the
  workspace, which is an `emptyDir` made fresh for each build pod, so the vulnerability database — 114.8 MiB
  when this was measured — is downloaded on every build: 13 seconds of a 23-second `Scan` stage. The variable
  still earns its place: the container runs as uid 1000 and Trivy's default `/.cache/trivy` is not writable.
  Putting it on a volume that outlives the pod would save the download, and is not done here because nothing
  else in this phase keeps state between builds.
- **`archiveArtifacts` in `post { always }`.** The report survives a failed build.

**Check**, on a temporary branch: the `Scan` stage passes, the console shows the table **and the line
`CRITICAL with a fix available: 0`**, and the build page lists `trivy-report.json` as an artifact. Look for that
line, not just a green stage: a gate that found nothing and a gate that never ran both leave a green stage, and
only the number tells them apart. Download it (or read it on the workstation with the build's URL) and compare the
counts with step 1: the same image content gives the same numbers.

**Record** the counts, and that the gate passed.

---

## Step 13 — Fewer findings in the base image

**Problem now.** The image carries 5 CRITICAL and 55 HIGH findings. None has a fix in Debian 12, so the gate passes,
but the numbers are the "before" of criterion #9 and nothing has moved them.

**Why it matters.** Most of those findings come from the base image, not from the application
([concepts §15](0-concepts.md#15-base-images-and-hardening)). A newer Debian fixes some of them outright, and
pinning the base by digest means the next change is deliberate.

**This step.** Move the builder and runtime stages to Debian 13 ("trixie"), pin both by digest, and measure again
with the same Trivy version.

**After this step.**
- Works: the image is built on a newer base, pinned exactly.
- Proven by: the tests still pass, the app still answers, and Trivy's counts are recorded as the "after" of
  criterion #9.
- Still missing: nothing proves who built the image → step 14.

| File | Change |
|---|---|
| `Dockerfile` | Both `FROM` lines, pinned by digest |

**Workstation.** Read the digests of the two images you are moving to:
```bash
docker buildx imagetools inspect ghcr.io/astral-sh/uv:python3.12-trixie-slim --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect python:3.12-slim-trixie --format '{{.Manifest.Digest}}'
```
Expected: the digest of the whole multi-platform index for each image. That is what a `FROM` line must name;
a digest from *inside* the manifest list would pin one architecture, or an attestation manifest, and the
listing contains several of each.

`--format` is ignored by some buildx versions, which print the full listing instead. That is fine — the value
is the `Digest:` line at the top of each block, above `Manifests:`. Do not take one of the indented
`Name: …@sha256:…` lines underneath.

If either tag does not exist, stop: record what the command said, and keep the current base until a tag that
does exist is chosen.

**Laptop.** Then in `Dockerfile`, change the two `FROM` lines to those images with `@sha256:…` appended, keeping the stage names
and everything else. Nothing else in the file changes.

**Why:**

- **Debian 13, not distroless.** The app's start script needs `/bin/sh`, and the current distroless Python image is
  3.11; FAISS and numpy wheels are built for 3.12.
- **Pinned by digest.** A rebuild produces the same base, and moving to a newer one is a commit with a visible diff.
- **`perl-base` stays.** It is essential in Debian and cannot be removed; whether its findings move is exactly what
  this step measures.

**Check**, on a temporary branch: the build passes the tests, the gate and the scan. Then compare its report
with step 12's.

`trivy-report.json` is a Jenkins **build artifact**, not a file in the workstation's clone, so fetch it first —
it lives on the controller's volume. On the workstation:
```bash
kubectl -n jenkins exec jenkins-0 -c jenkins --   sh -c 'ls -1t /var/jenkins_home/jobs/medical-rag/branches/*/builds/*/archive/trivy-report.json'
```
Newest first. Take the line for this branch and the line for step 12's, then:
```bash
AFTER=...   # the step 13 path
BEFORE=...  # the step 12 path
kubectl -n jenkins exec jenkins-0 -c jenkins -- cat "$AFTER"  > /tmp/after.json
kubectl -n jenkins exec jenkins-0 -c jenkins -- cat "$BEFORE" > /tmp/before.json

for f in /tmp/before.json /tmp/after.json; do
  echo "== $f"
  jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity) | .[] | "\(.[0].Severity) \(length)"' "$f"
done
```
`jq` runs on the workstation; the controller image does not have it.

Expected: the same command as step 1, so the numbers compare directly. These counts cover both `Results`
arrays, the Debian packages and the Python ones, so they run higher than the Debian table the console prints —
by six on the Debian 12 image measured here, all of them in `pip`. Any change, up or down, is the result.
Trivy's database changes daily, so a difference of one or two in the totals is normal; a difference you cannot
explain is not.

Then prove the image still works before it goes anywhere near prod: move `main`, let dev take the new image through
step 16 later, or, until then, run the image once by hand as in app guide step 11.

**Record** the two `FROM` lines with their digests, and the counts before and after.

---

## Step 14 — Sign what was built

**Problem now.** An image in ECR says which code it claims to come from, but nothing proves who built it.

**Why it matters.** Kyverno, later, can refuse an image with no valid signature. Even before that, a signature made
with a key that never leaves KMS is the difference between "the digest in Git" and "the digest this pipeline
produced" ([concepts §17](0-concepts.md#17-signing-images-with-cosign)).

**This step.** One stage, only on `main`: write the SBOM with Trivy, sign the digest with the KMS key, and attach
the SBOM as a signed attestation. Trivy writes SPDX JSON, so no extra tool is needed.

**After this step.**
- Works: every image built on `main` is signed, with its package list attached.
- Proven by: `cosign verify` on the workstation accepts the image; an unsigned older image is rejected.
- Still missing: nothing updates dev → steps 15 and 16.

| File | Change |
|---|---|
| `Jenkinsfile` | Two stages, `when { branch 'main' }` |

**Laptop.** Add after `Scan`:
```groovy
    stage('SBOM and signature') {
      when { branch 'main' }
      steps {
        container('trivy') {
          sh "trivy image --format spdx-json --output sbom.spdx.json ${IMAGE}@${env.IMAGE_DIGEST}"
        }
        container('tools') {
          // The key never leaves KMS; the pipeline may only ask it to sign (Jenkins guide step 3).
          // The public Rekor log is not used: these images are private, so their digests, repository
          // name and account id have no business in a public log, and verification here uses the key.
          //
          // cosign v3 removed the flags that used to say so. `--tlog-upload=false` is deprecated on
          // `sign` and refuses to run alongside the signing config v3 enables by default; on `attest` the
          // flag is gone entirely, and so are --rekor-url and --offline. What replaces them is a signing
          // config listing the services to use. Created with no services at all, it names no transparency
          // log, which is exactly the intent. It is generated here rather than baked into the tools image
          // so that it always matches the cosign that reads it, and building it needs no network.
          sh """
            cosign signing-config create --out signing-config.json
            cosign sign --yes --signing-config signing-config.json \
              --key awskms:///alias/medical-rag-cosign ${IMAGE}@${env.IMAGE_DIGEST}
            cosign attest --yes --signing-config signing-config.json \
              --type spdxjson --predicate sbom.spdx.json \
              --key awskms:///alias/medical-rag-cosign ${IMAGE}@${env.IMAGE_DIGEST}
          """
        }
      }
      post {
        always { archiveArtifacts artifacts: 'sbom.spdx.json', fingerprint: true }
      }
    }
```

**Why:**

- **`main` only.** A branch build must not be able to produce a signature that looks like a release.
- **Sign the digest from the build.** Not `:${GIT_TAG}`: what is signed is exactly what was pushed.
- **A signing config with no services, instead of `--tlog-upload=false`.** The images are private; a public
  transparency log entry would publish their digests, repository name and account id for no gain here.
  cosign v3 removed the flags that used to say so, and takes a signing config instead; one created with no
  services names no Rekor, no Fulcio and no timestamp authority, none of which key-based signing needs.
- **Trivy for the SBOM.** One less container, and the SBOM comes from the same scan of the same digest.

**Check before the push.** cosign's flags differ between versions, and this step has already been broken once
by that. Read them on the workstation, where the same cosign the tools image pins is installed — confirm that
first:
```bash
cosign version | grep GitVersion        # must match ARG COSIGN_VERSION in ci/Dockerfile
for c in sign attest verify; do
  echo "== $c"
  cosign $c --help 2>&1 | grep -oE '^[[:space:]]+(-[A-Za-z], )?--[a-z0-9-]+' | grep -oE '\-\-[a-z0-9-]+' | sort -u
done
```
The second `grep -o` is there because cobra prints a flag that has a short alias as `-y, --yes`, so a pattern
anchored on `--` alone would not see it — the same blind spot this step is being fixed for.

Expected: `sign` and `attest` both list `--signing-config` and `--key`; `attest` also lists `--predicate` and
`--type`; `verify` lists `--key` and `--insecure-ignore-tlog`.

Read the **flag list**, not the examples. cosign's help keeps usage examples from older versions, so
`--tlog-upload` still appears in an example under `sign` while being deprecated there and absent from `attest`
altogether — which is exactly how this step came to ship a command that cannot run. And check every command the
stage uses: greping only `sign` and `verify` misses `attest`, where the difference was.

If a flag is missing or named differently, use what this cosign prints and record the change.

Then prove the shape works before a real build does it — `main` is where the signature is real, and a build
that fails there is a failed release. Two commands, the second against the key and an image already in ECR:
```bash
cosign signing-config create --out /tmp/sc.json && cat /tmp/sc.json

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
IMG=$ACCOUNT.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag@<a digest already pushed>
cosign sign --yes --signing-config /tmp/sc.json --key awskms:///alias/medical-rag-cosign "$IMG"
```
Expected: JSON with no Rekor service in it, then `Pushing signature to: …`. An `AccessDenied` from KMS means
your own identity lacks `kms:Sign` — the syntax still passed, which is what this is testing. A signature made
this way is yours, not the pipeline's; say so when you record it, because `cosign verify` cannot tell them
apart afterwards.

**Check**, after `main` has built once:
```bash
KEY=awskms:///alias/medical-rag-cosign
DIGEST=$(aws ecr describe-images --repository-name medical-rag --image-ids imageTag=<commit> \
  --query 'imageDetails[0].imageDigest' --output text)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
IMAGE=$ACCOUNT.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag
cosign verify --key "$KEY" --insecure-ignore-tlog "$IMAGE@$DIGEST"
cosign verify --key "$KEY" --insecure-ignore-tlog "$IMAGE:1eaa43bf3512"
```
Expected: the first prints `Verification for … The cosign claims were validated`; the second fails, because the
image from the app phase was never signed. That contrast is the evidence for criterion #9.

**Record** both outputs.

---

## Step 15 — Notice when the corpus changes

**Problem now.** The pipeline updates the image, but the index version in the values files is still written by hand.
If the corpus or the chunk settings change, dev would run new code against the old index version.

**Why it matters.** The version is computed from the corpus and the settings
([app concepts §15](../../app/guide/0-concepts.md#15-the-index-version)). The in-cluster Job builds from the corpus
in S3, so a new version may only be deployed when the PDF in S3 is the one Git holds.

**This step.** A stage that computes the version with the same code that built the image, compares it with dev's
values, and, when it differs, compares the PDF in Git with the corpus in S3 by SHA-256. It writes nothing; it
decides whether step 16 may write the new version, or must stop.

**After this step.**
- Works: the pipeline knows the index version of the code it just built, and refuses to propose a version whose
  corpus is not in S3.
- Proven by: with nothing changed, the version equals dev's and the stage says `changed=no`; with a changed chunk
  setting, the version differs, the checksums still match, and the new version is carried forward; with a changed
  PDF that has not been uploaded, the stage stops with the message naming the corpus step.
- Still missing: nothing writes to Git yet → step 16.

| File | Change |
|---|---|
| `.dockerignore` | `data/` no longer excluded |
| `Dockerfile` | Two stages: `indexversion` and `indexversion-out` |
| `Jenkinsfile` | The `Index version` stage, and `AWS_ACCOUNT` in the tools container |

**Laptop.** In `.dockerignore`, remove the `data/` line, and add a comment:
```
# data/ stays in the build context: the pipeline computes the index version from it (Jenkins guide step 15).
# No stage copies it into the runtime image; `docker history` on the image shows no PDF layer.
```

Add this stage after `SBOM and signature`:
```groovy
    stage('Index version') {
      steps {
        // The version comes from the image's own code and the corpus in Git, exported to a local file.
        sh '''
          buildctl-daemonless.sh build \
            --frontend dockerfile.v0 \
            --local context=. \
            --local dockerfile=. \
            --opt target=indexversion-out \
            --output type=local,dest=version-out
        '''
        container('tools') {
          // `readYaml` would be shorter, but it comes from pipeline-utility-steps and this controller
          // installs only the plugins listed in deploy/argocd/values/jenkins.yaml. The tools image already
          // carries yq, so nothing new has to be installed to read two fields.
          script {
            env.INDEX_VERSION = readFile('version-out/version.txt').trim()
            env.DEV_VERSION   = sh(returnStdout: true,
              script: "yq -r '.index.version' deploy/envs/dev/values.yaml").trim()
            env.PROD_VERSION  = sh(returnStdout: true,
              script: "yq -r '.index.version' deploy/envs/prod/values.yaml").trim()
            env.INDEX_CHANGED_DEV  = (env.INDEX_VERSION == env.DEV_VERSION) ? 'no' : 'yes'
            env.INDEX_CHANGED_PROD = (env.INDEX_VERSION == env.PROD_VERSION) ? 'no' : 'yes'
            echo "index version: built=${env.INDEX_VERSION} dev=${env.DEV_VERSION} prod=${env.PROD_VERSION}"
          }
        }
        script {
          if (env.INDEX_CHANGED_DEV == 'yes' || env.INDEX_CHANGED_PROD == 'yes') {
            container('tools') {
              // The Job in the cluster reads the corpus from S3, so the new version may only be deployed if
              // S3 already holds exactly the PDF in Git. The CI role may read corpus/ and nothing else.
              sh '''
                set -e
                PDF=$(ls data/*.pdf | head -1)
                LOCAL=$(openssl dgst -sha256 -binary "$PDF" | base64)
                # Keep the error, but out of the value. Discarding stderr makes an expired token, a
                # wrong bucket name and a genuinely absent object indistinguishable, and all three
                # would then be reported as "the corpus is wrong" - sending someone to re-upload
                # 12 MB to fix a credential. Merging stderr into the value is no better: a warning on
                # a successful call would end up in REMOTE and fail the comparison the same way.
                ERRFILE=$(mktemp)
                if REMOTE=$(aws s3api head-object --bucket "medical-rag-artifacts-${AWS_ACCOUNT}" \
                  --key "corpus/$(basename "$PDF")" --checksum-mode ENABLED \
                  --query ChecksumSHA256 --output text 2>"$ERRFILE"); then
                  if [ -s "$ERRFILE" ]; then echo "head-object warned: $(cat "$ERRFILE")"; fi
                else
                  echo "head-object did not answer: $(cat "$ERRFILE")"
                  REMOTE=missing
                fi
                rm -f "$ERRFILE"
                echo "corpus local=$LOCAL s3=$REMOTE"
                test "$LOCAL" = "$REMOTE" || {
                  echo "The corpus in S3 is not the PDF in Git. Upload it first (app guide step 13), then rerun."
                  exit 1
                }
              '''
            }
          }
        }
      }
    }
```
Add `AWS_ACCOUNT` to the `tools` container's environment, next to `AWS_REGION`:
```yaml
        - name: AWS_ACCOUNT
          value: "${ACCOUNT}"
```

In the `Dockerfile`, add a stage that writes the version to a file, after the `test` stage:
```dockerfile
# Computes the index version from the corpus in the build context, for the pipeline (Jenkins guide step 15).
# It starts from the test stage, which is the one that has src/ and the full virtual environment, so it uses
# exactly the code and settings of this commit.
FROM test AS indexversion
COPY data /data
RUN DATA_PATH=/data PYTHONPATH=/app/src .venv/bin/python -m app.index version | tail -n 1 > /version.txt

# Exported on its own, so `--output type=local` copies one small file and not a whole image.
FROM scratch AS indexversion-out
COPY --from=indexversion /version.txt /version.txt
```

**Why:**

- **The version is computed, never typed.** The same code, the same corpus, the same settings as the image.
- **A build stage, not a container run.** The build pod has no way to run an image; BuildKit can.
- **The checksum comparison uses the value S3 stored at upload** (app guide step 13), so no download is needed.
  A missing object is expected to answer `403` rather than `404`, because the role cannot list the bucket
  ([concepts §20](0-concepts.md#20-the-index-version-in-ci)) — **expected, not measured**: the only hand-run
  of `head-object` was from the workstation, whose identity can list and therefore answered `404`. The stage
  keeps the error now, so the first build that hits this path prints which it was. Either way both are
  treated as "not there".
- **The pipeline never uploads the corpus.** Putting 12 MB of new data into the bucket stays a deliberate step.

**Check**, on a temporary branch, three cases. The first two are quick; the third needs a change you will revert.

1. **Nothing changed:** the stage prints `index version: built=cc759ae1a093 dev=cc759ae1a093 prod=cc759ae1a093`
   and the build continues.
2. **A chunk setting changed** (change `chunk_size` in the app's settings by one and push): the versions differ, the
   corpus checksums still match, because the PDF itself did not change, and the stage passes. The new version is
   what step 16 would write. Revert this before moving `main`.
3. **The corpus changed but was not uploaded** (replace one byte of the PDF in Git and push): the versions differ
   and the checksums do not, so the stage stops with `The corpus in S3 is not the PDF in Git`. Revert this too.

The version itself is built by the Job inside the cluster on the next sync, not by the pipeline: the CI role cannot
even read `faiss/`.

**Record** the three outputs, and the built version.

---

## Step 16 — The bot updates dev

**Problem now.** The image exists, is scanned and signed, but someone still has to edit `deploy/envs/dev/values.yaml`
by hand.

**Why it matters.** This is the step that makes the pipeline worth having: commit to dev with no command at all, and
criterion #8 measured from it.

**This step.** A stage, `main` only, that writes the new image tag (and the index version when it changed) into
dev's values, commits as `jenkins-bot` and pushes, retrying on a rebase.

**After this step.**
- Works: a commit on `main` reaches a running dev pod on its own.
- Proven by: the bot's commit appears in Git, Argo CD syncs it, and a new dev pod runs the new digest. Criterion #8
  is the time from your commit to that pod being Ready.
- Still missing: prod is still updated by hand → step 17.

| File | Change |
|---|---|
| `Jenkinsfile` | The `Promote to dev` stage |

**Laptop.** Add after `Index version`:
```groovy
    stage('Promote to dev') {
      when { branch 'main' }
      steps {
        container('tools') {
          withCredentials([usernamePassword(credentialsId: 'github',
                                            usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
            sh """
              set -e
              git config user.name jenkins-bot
              git config user.email jenkins-bot@users.noreply.github.com
              yq -i '.image.tag = "${env.GIT_TAG}@${env.IMAGE_DIGEST}"' deploy/envs/dev/values.yaml
              if [ "${env.INDEX_CHANGED_DEV}" = "yes" ]; then
                yq -i '.index.version = "${env.INDEX_VERSION}"' deploy/envs/dev/values.yaml
              fi
              git add deploy/envs/dev/values.yaml
              git diff --cached --quiet && { echo "dev already runs this image"; exit 0; }
              git commit -m "dev: ${env.GIT_TAG}"
              # Someone may have pushed while this build ran; rebase and try again, three times.
              for i in 1 2 3; do
                git pull --rebase --quiet "https://\${GIT_USER}:\${GIT_TOKEN}@github.com/biabeogo147/Medical-RAG-Chatbot.git" main && \
                git push --quiet "https://\${GIT_USER}:\${GIT_TOKEN}@github.com/biabeogo147/Medical-RAG-Chatbot.git" HEAD:main && exit 0
                sleep 5
              done
              echo "could not push after three tries"; exit 1
            """
          }
        }
      }
    }
```

**Why:**

- **`yq -i`, not `sed`.** It edits the value and keeps every comment, which `sed` on a YAML file cannot be
  trusted to do. It does not leave the file untouched: it re-emits the whole document, so the first bot
  commit also drops the blank lines between sections, collapses the padding before end-of-line comments,
  and writes LF where the file had CRLF. Measured here: 3 blank lines gone, 12 CRLF down to 2. Later bot
  commits are a one-line diff. `.gitattributes` does not cover `*.yaml`; adding `*.yaml text eol=lf` would
  stop the line-ending half of that churn.
- **The bot's own name and address.** The skip guard recognises the author, so this commit does not start another
  build ([concepts §18](0-concepts.md#18-writing-back-to-git)).
- **Nothing to commit is a success.** Rebuilding the same commit twice must not fail the pipeline.
- **The token only inside `withCredentials`.** Jenkins masks it in the log, and it is never written to a file.

**Check.** On a temporary branch this stage is skipped, which the UI shows. Then move `main` and watch one real
release:
```bash
git log -1 --format='%H %cI' origin/main          # your commit, and its time
```
In the UI the build runs; then on the workstation:
```bash
kubectl -n argocd annotate applications.argoproj.io medical-rag-dev argocd.argoproj.io/refresh=normal --overwrite
kubectl -n medical-rag-dev rollout status deploy/medical-rag --timeout=5m
kubectl -n medical-rag-dev get pods -l app.kubernetes.io/component=web -o json \
  | jq -r '.items[] | [.metadata.creationTimestamp,
      ((.status.conditions[] | select(.type=="Ready" and .status=="True")
        | .lastTransitionTime) // "not-ready-yet"),
      .spec.containers[0].image] | @tsv'
```
Expected: `deployment ... successfully rolled out`, then a pod whose image ends in the digest from the
build, with its creation and Ready times.

**Three details here, each of which has produced a wrong number once.**

First, `.status=="True"`. A pod that has not started still carries a `Ready` condition with `status: False`,
and its `lastTransitionTime` is roughly when the pod was created. Without the test the command answers with
a plausible time for a pod that is not running; criterion #8 came out eleven seconds short that way.

Second, the `// "not-ready-yet"` fallback. Once the test is there, a pod that is not ready yields *nothing*
for that slot, and `@tsv` then prints two columns instead of three — the image quietly moves into the Ready
column. The fallback keeps three columns and names the pod that is not there yet.

Third, `rollout status` rather than a wait on Argo CD. `kubectl wait … =Synced` returns at once, because at
the moment you ask, the Application is still `Synced` against the *previous* commit; and `Synced` means the
manifests were applied, not that the new pod serves. `rollout status` blocks until the new ReplicaSet is up,
which is the moment criterion #8 measures.

To see the startup sequence on one pod:
```bash
kubectl -n medical-rag-dev get pod POD -o jsonpath="{range .status.conditions[*]}{.type}={.status} {.lastTransitionTime}{'\n'}{end}"
```
It lists `PodScheduled`, `PodReadyToStartContainers`, `Initialized`, `ContainersReady` and `Ready`, each
with its own time — eleven seconds end to end here, with an init container fetching the index.

**Record** for criterion #8: your commit's time, the build's stage durations (the build page's *Stage View*, or
`curl -s <build-url>/wfapi/describe | jq`), and the dev pod's Ready time. The difference is "commit to running".

---

## Step 17 — Prod by pull request

**Problem now.** Prod's values are still edited by hand, and the image prod runs has no `release-` tag, so step 2's
first lifecycle rule protects nothing yet.

**Why it matters.** Prod should change only through something a person reviews and merges, and the image it runs
must survive ECR's clean-up ([concepts §19](0-concepts.md#19-promotion-by-pull-request)).

**This step.** Two stages, `main` only:
- open a pull request that writes the same values into `deploy/envs/prod/values.yaml`, with the digest and the Trivy
  summary in its body;
- when a commit on `main` changes prod's values, that is a merged pull request: tag the image it names
  `release-<tag>`.

**After this step.**
- Works: prod changes by review, and its image is protected.
- Proven by: the bot's pull request exists and merges; prod runs the image; the image carries `release-…`.
- Still missing: the node role can still push and sign → Part 4.

| File | Change |
|---|---|
| `Jenkinsfile` | Two stages |

**Laptop.** Two additions, at two different places in the `Jenkinsfile`.

First, the stage that tags the image. It goes at the **top** of the pipeline, right after `stages {` and before
`stage('Skip guard')`:
```text
  stages {
    // ↓ the new stage goes here ↓

    stage('Skip guard') {
```
The stage itself:
```groovy
    // First, because the commit that merges a prod pull request changes only deploy/, which the skip guard
    // below ends as NOT_BUILT. This stage has to run before it (Jenkins guide step 17).
    stage('Tag the image prod runs') {
      when {
        allOf {
          branch 'main'
          changeset "deploy/envs/prod/values.yaml"
        }
      }
      steps {
        container('tools') {
          sh '''
            set -e
            PROD=$(yq '.image.tag' deploy/envs/prod/values.yaml | tr -d '"')
            TAG=${PROD%@*}
            if aws ecr describe-images --repository-name medical-rag --image-ids imageTag="release-$TAG" >/dev/null 2>&1; then
              echo "release-$TAG already exists"; exit 0
            fi
            IMG=$(aws ecr batch-get-image --repository-name medical-rag --image-ids imageTag="$TAG" --output json)
            MANIFEST=$(echo "$IMG" | jq -r '.images[0].imageManifest')
            MEDIA=$(echo "$IMG" | jq -r '.images[0].imageManifestMediaType')
            aws ecr put-image --repository-name medical-rag --image-tag "release-$TAG" \
              --image-manifest "$MANIFEST" --image-manifest-media-type "$MEDIA" \
              --query 'image.imageId.imageDigest' --output text
          '''
        }
      }
    }
```

Then, after `Promote to dev`:
```groovy
    stage('Prod pull request') {
      when { branch 'main' }
      steps {
        container('tools') {
          withCredentials([usernamePassword(credentialsId: 'github',
                                            usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
            sh """
              set -e
              export GH_TOKEN="\${GIT_TOKEN}"
              BRANCH="bot/prod-${env.GIT_TAG}"
              git checkout -b "\$BRANCH"
              yq -i '.image.tag = "${env.GIT_TAG}@${env.IMAGE_DIGEST}"' deploy/envs/prod/values.yaml
              if [ "${env.INDEX_CHANGED_PROD}" = "yes" ]; then
                yq -i '.index.version = "${env.INDEX_VERSION}"' deploy/envs/prod/values.yaml
              fi
              git add deploy/envs/prod/values.yaml
              git diff --cached --quiet && { echo "prod already runs this image"; exit 0; }
              git commit -m "prod: ${env.GIT_TAG}"
              git push --quiet "https://\${GIT_USER}:\${GIT_TOKEN}@github.com/biabeogo147/Medical-RAG-Chatbot.git" "\$BRANCH"
              SUMMARY=\$(jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity)
                          | map("\\(.[0].Severity) \\(length)") | join(", ")' trivy-report.json)
              {
                echo "Image: ${IMAGE}:${env.GIT_TAG}@${env.IMAGE_DIGEST}"
                echo "Index version: ${env.INDEX_VERSION}"
                echo "Trivy: \$SUMMARY"
                echo "Dev has been running this image since build ${env.BUILD_NUMBER}."
              } > pr-body.md
              # One pull request at a time: if an earlier one is still open, update it instead of opening another.
              if gh pr list --repo biabeogo147/Medical-RAG-Chatbot --head "\$BRANCH" --state open --json number \
                   | grep -q number; then
                gh pr edit --repo biabeogo147/Medical-RAG-Chatbot "\$BRANCH" --body-file pr-body.md
              else
                gh pr create --repo biabeogo147/Medical-RAG-Chatbot --base main --head "\$BRANCH" \
                  --title "prod: ${env.GIT_TAG}" --body-file pr-body.md
              fi
            """
          }
        }
      }
    }
```

**Why:**

- **A branch and a pull request, not a push.** Prod's values change only when a person merges
  ([concepts §19](0-concepts.md#19-promotion-by-pull-request)); the bot's branches are named `bot/prod-*`, which the
  job does not build.
- **The tag comes after the merge, not when the pull request opens.** Pull requests you close without merging then
  never push a real release out of the ten the lifecycle rule keeps. The stage sits at the top of the pipeline,
  because the commit that merges a prod pull request changes only `deploy/`, which the skip guard stops.
- **Merge the pull request with "Squash and merge".** The skip guard reads the files of one commit, and a merge
  commit lists none, so an ordinary merge would look like "unknown" and run the whole pipeline again. A squash
  merge produces one commit that changes only prod's values, which is what both stages above expect. GitHub has
  no "default merge method" setting; clear *Allow merge commits* and *Allow rebase merging* in
  *Settings → General → Pull Requests* and squash is the only button left.
- **The merge commit is authored by whoever pressed the button, not by the bot.** So on a prod merge the skip
  guard's author test never fires; what ends the build is the other half of the guard, "only docs or deploy
  files changed". Expect a message naming *you*, not `jenkins-bot`. Both reach `NOT_BUILT`, but only one of
  them is doing the work, and the author test protects the dev push in step 16, not this.
- **`ecr:PutImage` is a permission the CI role already has.** Re-tagging is the same call as pushing a manifest.
- **The body carries the digest and the scan summary.** What you review is what was scanned and signed.

**Check.** After a `main` build: the pull request exists (`gh pr list --repo …` on the workstation, or the GitHub
UI), its body has the digest and the Trivy counts, and its diff touches only prod's values. Merge it. The commit
that merges it changes only `deploy/envs/prod/values.yaml`, so its build:
1. runs `Tag the image prod runs` first, which prints the digest it tagged;
2. then ends `NOT_BUILT` at the skip guard, because only `deploy/` changed. Both are expected, in that order.

Then, on the workstation:
```bash
kubectl -n medical-rag-prod get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
aws ecr describe-images --repository-name medical-rag --image-ids imageTag="release-<tag>" \
  --query 'imageDetails[0].[imageDigest, join(`,`, imageTags)]' --output text
```
Expected: prod's pods run the new digest, and that image carries both tags.

**Also set the repository rule** on GitHub, once: *Settings → Rules → Rulesets*, a ruleset on `main` that blocks
force pushes and branch deletion. It cannot require a review from yourself, which is the limit recorded in the
[README](../README.md#15-known-limits-and-what-is-out-of-scope).

**Record** the pull request's URL, prod's image, the `release-` tag, and what happened in check 1.

---

## The finished pipeline

After step 17 the `Jenkinsfile` holds, in this order:

```
constants: ACCOUNT, REGION, REGISTRY, IMAGE, BUILDKIT, CI_TOOLS
pipeline
  agent  → pod: buildkit, tools, trivy
  options → disableConcurrentBuilds, timestamps, buildDiscarder
  stages
    Tag the image prod runs   main + prod values changed   (step 17)
    Skip guard                                             (step 10)
    Test                                                   (step 10)
    Log in to ECR                                          (step 11)
    Build and push                                         (step 11)
    Scan                                                   (step 12)
    SBOM and signature        main only                    (step 14)
    Index version                                          (step 15)
    Promote to dev            main only                    (step 16)
    Prod pull request         main only                    (step 17)
```

If your file differs from this, the difference is a mistake in one of the steps above, not a variation.

---

[← Part 2](2-jenkins.md) · [Index](../guide.md) · [Part 4 →](4-close-out.md) · [Troubleshooting](troubleshooting.md)
