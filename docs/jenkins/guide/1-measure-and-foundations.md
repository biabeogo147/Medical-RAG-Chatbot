# Jenkins guide — Part 1: Measure, then lay the foundations (steps 1–5)

[← Concepts](0-concepts.md) · [Index](../guide.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** the [app guide](../../app/guide.md) is finished: dev and prod run the image
`1eaa43bf3512`, and Argo CD shows every Application `Synced` and `Healthy`. Read *The big picture* and
sections 1, 2, 6, 7 and 8 of [Concepts](0-concepts.md).

**Done when:**
- You know, from measurements, how many fixable CRITICAL vulnerabilities Trivy finds in today's image, how
  much CPU and memory the nodes have left, and whether rootless BuildKit runs on these nodes.
- The image prod runs is protected from ECR's automatic clean-up.
- An AWS role exists for the build pods, with only what a build needs.
- `jenkins.recruitai.io.vn` resolves to the internal load balancer.

**Every step follows [the loop](../guide.md#the-loop-for-every-step).** Nothing Argo CD manages changes in this
part, so no step needs a temporary branch. Step 1.4 runs one throwaway Job and deletes it.

**What has to be running.** Steps 1.2 and 1.4 measure the cluster, so the cluster must be up **with everything
it normally runs**: `make bootstrap` done, `root` `Healthy`, and dev and prod serving. A measurement taken while
the app is down would report room that does not exist. Steps 1.1, 2 and 3 need no cluster at all, and step 4 needs
only the cluster stack in Terraform.

---

## Step 1 — Measure before building anything

**Problem now.** Three questions that the rest of this guide depends on have no answer yet:
1. **How many fixable vulnerabilities does Trivy find?** The "before" numbers of criterion #9 (4 CRITICAL,
   14 HIGH) came from ECR's scanner. The pipeline will use Trivy, which counts differently
   ([concepts §2](0-concepts.md#2-cves-scanners-and-trivy)). A Trivy "after" compared with an ECR "before"
   would prove nothing.
2. **How much room is left on the nodes, while everything else runs?** 57–68% of each node's CPU was already
   requested before the app phase added its pods, and Jenkins will run next to all of it.
3. **Does rootless BuildKit run on these nodes?** They run Ubuntu 24.04, which may refuse BuildKit the rights
   it needs inside its user namespace ([concepts §7](0-concepts.md#7-rootless-user-namespaces-seccomp-and-apparmor)).

**Why it matters.** Each answer changes what Parts 2 and 3 write. The Trivy count decides whether the first
pipeline run will stop at the gate. The free room decides the build pod's requests. The BuildKit test decides
whether the nodes need step 5, and at which Pod Security level the build pods run
([concepts §8](0-concepts.md#8-pod-security-levels-and-admission-policies)).

**This step.** Four measurements answer the three questions: 1.1 answers the first, 1.2 the second, 1.3 and
1.4 the third. All run on the workstation. Three only read; 1.4 creates a throwaway namespace with one Job and
deletes it.

**After this step.**
- Works: nothing changes; you only learn three facts.
- Proven by: a Trivy report of the image prod runs; the free CPU and memory of each node while the platform and
  both app environments run; the AppArmor setting of each node; a rootless BuildKit build that succeeds, or fails
  with a recorded error.
- Still missing: nothing protects the image prod runs from ECR's clean-up → step 2.

### 1.1 Trivy on the image prod runs

**Workstation.** The tag prod runs, read from Git rather than typed, and the registry address. You need
`$ACCOUNT`, `$TAG` and `$IMAGE` again in steps 2 and 3; in a new shell, run this block again first:
```bash
cd ~/Medical-RAG-Chatbot
git pull
TAG=$(yq '.image.tag' deploy/envs/prod/values.yaml | cut -d@ -f1)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY=$ACCOUNT.dkr.ecr.ap-southeast-1.amazonaws.com
IMAGE=$REGISTRY/medical-rag:$TAG
echo "$IMAGE"
```
Expected: `<account>.dkr.ecr.ap-southeast-1.amazonaws.com/medical-rag:1eaa43bf3512`.

**Workstation.** Pull the image, then let Trivy read it from the local Docker. Trivy runs as a container,
pinned to 0.74.0, so nothing is installed. Its vulnerability database is cached in `~/.cache/trivy`, and the
report goes to `~/ci-baseline`, outside the repository:
```bash
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin "$REGISTRY"
docker pull "$IMAGE"
mkdir -p ~/ci-baseline ~/.cache/trivy
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.cache/trivy:/root/.cache/trivy \
  -v ~/ci-baseline:/out \
  aquasec/trivy:0.74.0 image --scanners vuln --format json --output "/out/trivy-$TAG.json" "$IMAGE"
```
Expected: `Login Succeeded`, the pull, then Trivy's download of its database and no error.

**Workstation.** Count the findings by severity and how many of each have a fix, then list the CRITICAL ones.
"Fixable" uses the same field as Trivy's `--ignore-unfixed`: `Status` is `fixed`:
```bash
REPORT=~/ci-baseline/trivy-$TAG.json
jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity) | .[]
       | "\(.[0].Severity) \(length) total, \(map(select(.Status == "fixed")) | length) fixable"' "$REPORT"
jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")
       | "\(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) status=\(.Status) fixed=\(.FixedVersion // "none")"' "$REPORT"
```
Expected: one line per severity, such as `CRITICAL 4 total, 1 fixable` (an `UNKNOWN` line is possible), then
one line per CRITICAL finding. The numbers are what this step is for; they may differ from ECR's.

**Workstation.** Now run exactly the gate the pipeline will run. Its exit code is the only thing the pipeline
will look at, so it is measured on its own:
```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.cache/trivy:/root/.cache/trivy \
  aquasec/trivy:0.74.0 image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 --quiet "$IMAGE"
echo "gate exit=$?"
```
Expected: `gate exit=1` if at least one CRITICAL has a fix, with those findings in a table above it; `gate
exit=0` if none has. Either is a result: it tells you whether step 12's first run will stop.

### 1.2 Free room on the nodes, with everything running

Jenkins will run beside the platform and both app environments, so the room has to be measured while those are
running. First confirm they are.

**Workstation**, with `make tunnel` open in tmux window 1:
```bash
make apps
kubectl get pods -A -l app.kubernetes.io/name=medical-rag -o wide
```
Expected: every Application `Synced` and `Healthy`, and three app pods `Running`: one in `medical-rag-dev`, two
in `medical-rag-prod`. If anything is missing, fix that first: a measurement taken now would report room that
disappears as soon as the app comes back.

**Workstation.** Then the requests each node has already promised:
```bash
kubectl describe nodes | grep -E '^Name:|^  (cpu|memory) '
```
Expected: for each of the three nodes, its name, then a `cpu` line and a `memory` line from *Allocated
resources*, such as `cpu  1350m (67%)  …`. The first number is the sum of requests; `2000m` minus it is what a
new pod can still request on that node. The memory line reads the same way against memory allocatable, which these
nodes do not print here; it works out at about 7.8 GiB, so treat the memory gaps as approximate.

These numbers are the budget for Part 2: the Jenkins controller and one build pod must fit in the smallest of the
three gaps, because a pod runs on one node.

### 1.3 The AppArmor setting of the nodes

**Workstation.** Ansible reaches the nodes through Session Manager, as `make ping` does. It needs the account
id: Session Manager moves each module through the bucket `medical-rag-ssm-transfer-<account>`
(`inventory/group_vars/nodes.yml`), so an empty value makes every node fail with `404 … HeadBucket`. The command
reads the id itself, so it does not depend on a variable set earlier:
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible
ansible nodes -m command -a 'sysctl -n kernel.apparmor_restrict_unprivileged_userns' \
  -e project=medical-rag -e aws_region=ap-southeast-1 \
  -e aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
cd ~/Medical-RAG-Chatbot
```
Expected: three `CHANGED | rc=0` blocks, each printing `1` (Ubuntu's rule is on) or `0` (off). `1` does not yet
mean rootless BuildKit fails; 1.4 shows whether it does.

### 1.4 A rootless BuildKit build on these nodes

This is BuildKit's rootless Job example (`examples/kubernetes/job.rootless.yaml` in BuildKit v0.33.0),
adapted: the image is pinned, the Dockerfile is replaced by one that runs a single command, and a namespace, a
retry limit and a deadline are added. The security settings are the example's own. `rootlesskit` creates the
user namespace as soon as `buildkitd` starts, and the `RUN` line then exercises it.

Two details:
- `--oci-worker-no-process-sandbox` lets BuildKit run build steps without creating a new PID namespace, which
  a container cannot do without extra rights. The upstream example uses it too.
- The namespace is labelled `privileged` explicitly: `Unconfined` seccomp and AppArmor are refused at every
  stricter level ([concepts §8](0-concepts.md#8-pod-security-levels-and-admission-policies)). Nothing is
  committed; the manifest goes straight from the terminal to the cluster.

**Workstation:**
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: buildkit-probe
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: batch/v1
kind: Job
metadata:
  name: buildkit-probe
  namespace: buildkit-probe
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: prepare
          image: busybox:1.37
          command: ["sh", "-c", "printf 'FROM busybox:1.37\\nRUN echo built-by-rootless-buildkit > /proof\\n' > /workspace/Dockerfile"]
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
          volumeMounts:
            - name: workspace
              mountPath: /workspace
      containers:
        - name: buildkit
          image: moby/buildkit:v0.33.0-rootless
          env:
            - name: BUILDKITD_FLAGS
              value: --oci-worker-no-process-sandbox
          command: ["buildctl-daemonless.sh"]
          args: ["build", "--frontend", "dockerfile.v0", "--local", "context=/workspace", "--local", "dockerfile=/workspace"]
          securityContext:
            seccompProfile:
              type: Unconfined
            appArmorProfile:
              type: Unconfined
            runAsUser: 1000
            runAsGroup: 1000
          # A build pod's rough shape, so this also shows whether such a pod can be scheduled at all
          # while the platform and both app environments run.
          resources:
            requests:
              cpu: 300m
              memory: 1Gi
            limits:
              memory: 2Gi
          volumeMounts:
            - name: workspace
              mountPath: /workspace
              readOnly: true
            - name: buildkitd
              mountPath: /home/user/.local/share/buildkit
      volumes:
        - name: workspace
          emptyDir: {}
        - name: buildkitd
          emptyDir: {}
EOF
```
Expected: `namespace/buildkit-probe created`, `job.batch/buildkit-probe created`.

**Workstation.** Wait up to five minutes, the Job's own deadline, then read the result whatever it was. An
empty number means zero:
```bash
kubectl -n buildkit-probe wait --for=condition=complete job/buildkit-probe --timeout=5m
kubectl -n buildkit-probe get job buildkit-probe -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}{"\n"}'
kubectl -n buildkit-probe get pods -o wide
kubectl -n buildkit-probe logs job/buildkit-probe --all-containers --tail=25
```
Expected, one of three:
- **It works:** `condition met`, `succeeded=1 failed=`, and the log shows the `RUN echo built-by-rootless-buildkit`
  line followed by `DONE`. Step 5 is not needed.
- **It is refused:** the wait times out, `succeeded= failed=1`, and the log ends with an error from `rootlesskit`,
  `newuidmap` or `mount`, typically containing `operation not permitted` or `permission denied`. Copy the whole
  error: step 5 starts from it.
- **It never ran:** `succeeded= failed=`, the pod is not `Completed` or `Error`. Look at the pod's events
  (troubleshooting) before drawing any conclusion. `Pending` with `Insufficient cpu` is a capacity result, not a
  BuildKit result: record it, and Part 2 sizes the build pod under that limit.

The `NODE` column shows where it ran. If 1.3 printed different values on different nodes, the result holds only
for that node: note it, step 5 then tests every node.

**Workstation.** Delete the namespace, and the Job and pod with it, whatever the result:
```bash
kubectl delete namespace buildkit-probe
```
Expected: `namespace "buildkit-probe" deleted`.

**Why:**

- **The image prod runs, not a fresh build.** It is the image the "before" numbers belong to. Its tag is read
  from `deploy/envs/prod/values.yaml`, so a typo cannot scan the wrong one.
- **Trivy in a container, pinned.** The workstation keeps its promise of no new tools, and the pipeline will
  run the same version, so its numbers compare with these.
- **The upstream example's security settings.** If BuildKit's own example fails on these nodes, the cause is
  the nodes, not a mistake in settings written for this guide.
- **Requests on the test Job.** 300m and 1Gi is roughly what a build container will ask for, so the Job also
  answers a second question: does a pod of that size still fit while everything else runs?
- **A throwaway namespace.** The test needs the level `privileged`; creating it only for these minutes leaves no
  relaxed namespace behind.

**Record** in `docs/evidence/jenkins.md`:
- the Trivy counts per severity, total and fixable, the CRITICAL list, and the gate's exit code;
- each node's CPU and memory requests, and that `make apps` showed everything `Healthy` when you took them;
- the three `sysctl` values;
- the BuildKit test: `succeeded` or `failed`, the node, and on failure the full error.

---

## Step 2 — Keep the images prod may run

**Problem now.** ECR keeps the last 20 tagged images and deletes older ones
([concepts §4](0-concepts.md#4-ecr-lifecycle-policies)). Today that is harmless: there is one image. Once the
pipeline runs, every build pushes an image, branch builds included. About twenty builds later, the image prod runs
would be deleted while prod still uses it, and the next prod pod started on another node would fail with
`ImagePullBackOff`.

**Why it matters.** Prod may legitimately run an old image for weeks while dev moves on. Rolling back also needs
the previous prod images to still exist.

**This step.**
- A first lifecycle rule keeps the last 10 images tagged `release-*`. An image kept by a higher-priority rule can
  never be expired by a lower one.
- The existing rule comes second and keeps 30 tagged images in total. It counts the `release-*` images and the
  cache too, but can never expire a `release-*` one.
- The image prod runs today gets the tag `release-1eaa43bf3512` now. From step 17 on, the pipeline gives this tag
  to every image that reaches prod's values on `main` ([concepts §19](0-concepts.md#19-promotion-by-pull-request)).

**After this step.**
- Works: the image prod runs, and the nine prod images before it, can no longer be expired.
- Proven by: the policy ECR holds has the two rules in this order; the prod image carries both tags with one
  digest. With a single image in the repository, no rule can expire anything yet; step 19 previews the policy
  again once the pipeline has pushed enough images.
- Still missing: no AWS identity exists for the build pods → step 3.

| File | Change |
|---|---|
| `infra/terraform/shared/registry.tf` | Replace the `aws_ecr_lifecycle_policy` resource |

**Laptop.** In `infra/terraform/shared/registry.tf`, replace the whole `resource "aws_ecr_lifecycle_policy" "app"`
block with:
```hcl
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  # Counts tagged images only. Cosign v3 stores signatures and SBOM attestations as untagged OCI
  # referrers, so a rule with tagStatus "any" would count them and could delete the signature of an
  # image that is still running.
  #
  # Rule 1 comes first on purpose: an image selected by a higher-priority rule can never be expired by a
  # lower one. Every image that reaches prod's values is tagged "release-<tag>" (Jenkins guide step 17),
  # so prod's image survives however many builds run after it. Rule 2 still counts those images.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 10 images that reached prod"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["release-*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 30 tagged images in total"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}
```

**Why:**

- **Protect by tag, not by count.** No count is safe: prod can stay on one image through any number of dev builds.
  A tag that only prod's images carry is kept by its own rule.
- **10 release images.** Enough to roll prod back several releases.
- **30 in total.** Each build pushes one image; 30 covers several days of branch and `main` builds.
- **The build cache.** Each build overwrites the one `buildcache` tag, so the cache is always a single tagged image.
  The cache manifests it replaces become untagged, and no rule here deletes untagged images, for the reason in the
  comment. They accumulate; Part 3 decides where the cache lives, and step 19 measures what it costs.

**Check before:** on the laptop, `git status --short` shows only ` M infra/terraform/shared/registry.tf`. Commit
and push (`git add infra/terraform/shared/registry.tf`, message `Protect release images in ECR`). Then, on the
workstation:
```bash
git pull
make shared
```
Expect **0 to add, 1 to change, 0 to destroy**, and the change is `aws_ecr_lifecycle_policy.app`. Then type `yes`.
Anything else: type `no` and stop.

**Workstation.** How many images the repository holds, and the policy ECR now applies:
```bash
aws ecr describe-images --repository-name medical-rag --query 'length(imageDetails)'
aws ecr get-lifecycle-policy --repository-name medical-rag --query lifecyclePolicyText --output text \
  | jq -c '[.rules[] | {rulePriority, tags: .selection.tagPatternList, keep: .selection.countNumber}]'
```
Expected: a small number, such as `1`; then
`[{"rulePriority":1,"tags":["release-*"],"keep":10},{"rulePriority":2,"tags":["*"],"keep":30}]`.

**Workstation.** The rest of this step uses `$TAG` from 1.1. Set it again and refuse to go on if it is empty: with
an empty value, the gate below asks about the tag `release-` and answers `ImageNotFoundException`, which looks
exactly like a pass:
```bash
cd ~/Medical-RAG-Chatbot
TAG=$(yq '.image.tag' deploy/envs/prod/values.yaml | cut -d@ -f1)
test -n "$TAG" && echo "TAG=$TAG"
```
Expected: `TAG=1eaa43bf3512`. No output at all: `yq` found nothing, so stop and check the values file and the
directory.

> **Shared state.** The next command adds a tag to the image prod runs. The repository is immutable, so a tag
> cannot be moved once set. Confirm it does not exist yet:
> ```bash
> aws ecr describe-images --repository-name medical-rag --image-ids imageTag="release-$TAG"
> ```
> Expected: `An error occurred (ImageNotFoundException)`, and the message must name `release-1eaa43bf3512`, not
> `release-`. Anything else: stop.

**Workstation.** Add the tag. ECR re-tags an image when you put the same manifest under a new tag, which is the
method AWS documents. The manifest stays in a shell variable, not a file, so no trailing newline changes its
digest:
```bash
MANIFEST=$(aws ecr batch-get-image --repository-name medical-rag --image-ids imageTag="$TAG" \
  --query 'images[0].imageManifest' --output text)
MEDIA=$(aws ecr batch-get-image --repository-name medical-rag --image-ids imageTag="$TAG" \
  --query 'images[0].imageManifestMediaType' --output text)
aws ecr put-image --repository-name medical-rag --image-tag "release-$TAG" \
  --image-manifest "$MANIFEST" --image-manifest-media-type "$MEDIA" \
  --query 'image.imageId.imageDigest' --output text
```
Expected: one `sha256:…` line.

**Check:**
```bash
aws ecr describe-images --repository-name medical-rag --image-ids imageTag="release-$TAG" \
  --query 'imageDetails[0].[imageDigest, join(`,`, imageTags)]' --output text
yq '.image.tag' deploy/envs/prod/values.yaml
```
Expected: the digest from `put-image` with both tags, `1eaa43bf3512` and `release-1eaa43bf3512`; then prod's value,
ending in the same digest.

**Record** the plan line, the image count, the rules, and the two check outputs.

---

## Step 3 — An AWS role for the build pods

**Problem now.** The design lets build pods use the node role, through IMDS. That role can read eight secrets,
including the wildcard certificate's private key and prod's API keys, and write several buckets. A build runs the
repository's own code: its tests and its Dockerfile. A malicious test or Dockerfile line could use every one of
those permissions.

**Why it matters.** If a build is compromised, the damage must stop at pushing an image and signing it, not reach
prod's keys. A build needs three things: push to one ECR repository, ask KMS to sign with one key, and read the
corpus checksum. The app phase already built the way to give a pod a role of its own
([concepts §5](0-concepts.md#5-the-pipelines-aws-identity)).

**This step.** One more entry in the shared stack's IRSA roles: `medical-rag-ci`. Only the ServiceAccount
`jenkins-agent` in the namespace `jenkins-agents` may assume it, and its policy allows exactly those three things.
Nothing uses it yet; Part 2 creates the ServiceAccount.

**After this step.**
- Works: the role exists, with its trust and permissions.
- Proven by: the trust policy names only `jenkins-agents:jenkins-agent`; IAM's policy simulator allows the three
  actions and denies writing to S3, reading the index and reading secrets.
- Still missing: Jenkins has no name reachable through the VPN → step 4.

| File | Change |
|---|---|
| `infra/terraform/shared/irsa.tf` | One more role in `irsa_roles`, its policy, and a map from role to policy |

**Laptop.** In `infra/terraform/shared/irsa.tf`, make three changes.

1. Replace the `locals` block that defines `irsa_roles` with:
```hcl
locals {
  # Role name suffix => the ServiceAccounts ("namespace:name") allowed to assume it.
  irsa_roles = {
    app-dev       = ["medical-rag-dev:medical-rag"]
    app-prod      = ["medical-rag-prod:medical-rag"]
    index-builder = ["medical-rag-dev:medical-rag-index-builder", "medical-rag-prod:medical-rag-index-builder"]
    ci            = ["jenkins-agents:jenkins-agent"] # the Jenkins build pods (Jenkins guide step 3)
  }

  # Role name suffix => its permissions policy.
  irsa_policies = {
    app-dev       = data.aws_iam_policy_document.index_read.json
    app-prod      = data.aws_iam_policy_document.index_read.json
    index-builder = data.aws_iam_policy_document.index_build.json
    ci            = data.aws_iam_policy_document.ci.json
  }
}
```

2. Add this block after the `index_build` policy document:
```hcl
# The Jenkins build pods: push the image, sign it, and read the corpus checksum. Nothing else, and in
# particular no secret: the GitHub token reaches Jenkins through External Secrets, not through this role.
data "aws_iam_policy_document" "ci" {
  # The only ECR action AWS cannot scope to a repository: it is registry-wide.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push and pull on this repository only: layers, manifests, and the BuildKit cache.
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # Ask KMS to sign image digests with the cosign key. The private key never leaves KMS.
  statement {
    sid       = "CosignSign"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [aws_kms_key.cosign.arn]
  }

  # Read the stored SHA-256 of the corpus (head-object with checksum mode), to compare it with Git's copy.
  # No ListBucket: a missing PDF then answers 403 instead of 404, and the pipeline treats both as "not
  # there". The pipeline never writes the corpus.
  statement {
    sid       = "ReadCorpusChecksum"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/corpus/*"]
  }
}
```

3. In `resource "aws_iam_role_policy" "irsa"`, replace the `policy = …` line with:
```hcl
  policy = local.irsa_policies[each.key]
```

**Why:**

- **A map instead of the ternary.** The old line chose between two policies. A third policy would need a nested
  condition; a map names each role's policy once, and a role missing from it fails the plan instead of silently
  getting the wrong policy.
- **`jenkins-agents:jenkins-agent` only.** The controller lives in `jenkins` and never gets a token for this role.
  A build pod in any other namespace, or with another ServiceAccount, is refused by STS.
- **No `ecr:ListImages`, no delete.** A build pushes; it never needs to list or remove images.
- **`s3:GetObject` on `corpus/*` only.** `head-object` needs `GetObject`. The index (`faiss/`) and the rest of the
  bucket stay out of reach.
- **In the shared stack.** The role references the registry, the key and the bucket, which all live there, and it
  must survive `make down` like the app's roles.

**Check before:** on the laptop, `git status --short` shows only ` M infra/terraform/shared/irsa.tf`. Commit and
push (`git add infra/terraform/shared/irsa.tf`, message `Add the CI role for Jenkins build pods`). Then, on the
workstation:
```bash
git pull
make shared
```
Expect **2 to add, 0 to change, 0 to destroy**: `aws_iam_role.irsa["ci"]` and `aws_iam_role_policy.irsa["ci"]`.
The three existing policies must not appear: the map gives each the same document the ternary did. Then type
`yes`. Anything else: type `no` and stop.

**Check** on the workstation. If `$ACCOUNT` is empty, this is a new shell: run the first block of 1.1 again.

The trust policy:
```bash
aws iam get-role --role-name medical-rag-ci \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' --output json
```
Expected: two keys, ending in `:aud` = `sts.amazonaws.com` and `:sub` = `system:serviceaccount:jenkins-agents:jenkins-agent`.

What the role may do. IAM's policy simulator evaluates the role's policies without calling anything:
```bash
ROLE_ARN=$(aws iam get-role --role-name medical-rag-ci --query Role.Arn --output text)
REPO_ARN=$(aws ecr describe-repositories --repository-names medical-rag --query 'repositories[0].repositoryArn' --output text)
KEY_ARN=$(aws kms describe-key --key-id alias/medical-rag-cosign --query KeyMetadata.Arn --output text)
BUCKET_ARN=arn:aws:s3:::medical-rag-artifacts-$ACCOUNT
sim() {
  aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" --action-names "$1" --resource-arns "$2" \
    --query 'EvaluationResults[0].[EvalActionName, EvalDecision]' --output text
}
sim ecr:PutImage "$REPO_ARN"
sim kms:Sign "$KEY_ARN"
sim s3:GetObject "$BUCKET_ARN/corpus/any.pdf"
sim s3:PutObject "$BUCKET_ARN/corpus/any.pdf"
sim s3:GetObject "$BUCKET_ARN/faiss/any"
sim secretsmanager:GetSecretValue "arn:aws:secretsmanager:ap-southeast-1:$ACCOUNT:secret:medical-rag/github"
```
Expected, in order, each action followed by its decision:
```
ecr:PutImage    allowed
kms:Sign        allowed
s3:GetObject    allowed
s3:PutObject    implicitDeny
s3:GetObject    implicitDeny
secretsmanager:GetSecretValue   implicitDeny
```

**Record** the plan line, the `StringEquals` block, and the six results.

---

## Step 4 — A name for Jenkins

**Problem now.** Every internal UI has a name under `recruitai.io.vn` that points at the internal load balancer, so
it opens only through the VPN. Jenkins has none.

**Why it matters.** Part 2's Ingress for Jenkins needs a host name, and the wildcard certificate only covers names
under the domain. The name belongs to the cluster stack, like the other internal UI names.

**This step.** `jenkins` added to `internal_ui_hosts`, which creates `jenkins.recruitai.io.vn` as an alias of the
internal load balancer.

**After this step.**
- Works: the name resolves.
- Proven by: it resolves to the same private addresses as `argocd.recruitai.io.vn`; through the VPN, ingress-nginx
  answers `404` for it with a valid certificate, because no Ingress claims it yet.
- Still missing: if the BuildKit test of step 1.4 failed, the nodes still refuse rootless BuildKit → step 5. If it
  succeeded, Part 1 is done.

| File | Change |
|---|---|
| `infra/terraform/cluster/internal-ui.tf` | `jenkins` added to the default list |

**Laptop.** In `infra/terraform/cluster/internal-ui.tf`, change the default of `internal_ui_hosts` to:
```hcl
  default     = ["argocd", "grafana", "prometheus", "alertmanager", "jenkins"]
```

**Check before:** on the laptop, `git status --short` shows only ` M infra/terraform/cluster/internal-ui.tf`. Commit
and push (`git add infra/terraform/cluster/internal-ui.tf`, message `Add the jenkins name`). Then, on the
workstation:
```bash
git pull
make infra
```
Expect **1 to add, 0 to change, 0 to destroy**: `aws_route53_record.internal_ui["jenkins"]`. Then type `yes`.
Anything else: type `no` and stop. If the cluster stack is down at the moment, skip the apply and the checks: the
next rebuild's `make infra` creates the name with everything else, and you run the checks after that rebuild.

**Check, workstation.** A name that did not exist a moment ago can be cached as "not found" for a few minutes; if
the first command prints nothing, wait five minutes and run it again:
```bash
getent ahostsv4 jenkins.recruitai.io.vn | awk '{print $1}' | sort -u
getent ahostsv4 argocd.recruitai.io.vn | awk '{print $1}' | sort -u
```
Expected: the same three `10.10.x.x` addresses twice.

**Check, laptop,** with WireGuard on, in PowerShell:
```powershell
curl.exe -sS -o NUL -w "%{http_code}\n" https://jenkins.recruitai.io.vn/
```
Expected: `404`, with no certificate error: ingress-nginx served its default, the wildcard certificate, and no
Ingress claims the name yet.

**Record** the plan line and the two outputs.

---

## Step 5 — Let rootless BuildKit run on the nodes (only if step 1.4 failed)

**If step 1.4 succeeded,** skip this step. Record "step 5 not needed: the BuildKit test succeeded on node
<name>". Part 1 is done.

**If step 1.4 failed,** stop here and do not change the nodes. Paste the full error you recorded into the chat:
this step is then written from it, in the same shape as every other step, because the right fix depends on the
exact error. Below is a draft, so you know what to expect.

**Problem now** *(draft)*. Ubuntu 24.04 gives an unconfined program no rights inside a user namespace it creates
(`kernel.apparmor_restrict_unprivileged_userns=1`), and a container with `appArmorProfile: Unconfined` is exactly
such a program. `rootlesskit` cannot set up the namespace BuildKit needs.

**Why it matters** *(draft)*. Without rootless BuildKit, the remaining ways to build an image in the cluster give the
build root on the node ([concepts §6](0-concepts.md#6-building-images-without-a-docker-daemon)).

**This step** *(draft)*. An AppArmor profile for BuildKit, installed on every node by Ansible, that allows user
namespaces (`userns,`) for that profile alone. The build pod then asks for it by name (`appArmorProfile:
{type: Localhost, localhostProfile: …}`) instead of `Unconfined`. Every other program on the node keeps Ubuntu's
rule. A named profile also counts as `Localhost` for Pod Security, which is one step towards running the build
pods at the level `baseline` instead of `privileged` ([concepts §8](0-concepts.md#8-pod-security-levels-and-admission-policies)).
The fix it avoids: setting the sysctl to `0`, which lifts the rule for every program on every node, including
everything that runs next to etcd.

**After this step** *(draft)*.
- Works: rootless BuildKit runs on every node.
- Proven by: the Job of 1.4, changed to use the profile, succeeds on each of the three nodes; a second
  `make cluster` reports `changed=0`.
- Still missing: there is still no Jenkins: no namespaces, no controller, no job → Part 2.

---

[← Concepts](0-concepts.md) · [Index](../guide.md) · [Troubleshooting](troubleshooting.md)
