# Jenkins guide — Part 4: Close out (steps 18–19)

[← Part 3](3-pipeline.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 3 is done: a commit on `main` reaches dev on its own, and prod changes through a merged
pull request.

**Done when:** only the build pods can push and sign, the phase survives a rebuild, the obsolete files are gone, and
the evidence is complete.

---

## Step 18 — Take push and sign away from the node role

**Problem now.** The node role still carries `ecr:PutImage` and `kms:Sign`. Every pod on every node can reach it
through IMDS, so the build pods' own role is an addition, not yet a boundary
([concepts §5](0-concepts.md#5-the-pipelines-aws-identity)).

**Why it matters.** This is the step that makes step 3 worth something: after it, the only way to push an image or
produce a signature is to be a build pod with the CI role.

**This step.** Remove the two statements from the node role's inline policy. The nodes keep pulling images, which is
a different set of actions.

**After this step.**
- Works: the pipeline still builds, pushes and signs, through the CI role.
- Proven by: a pod using the node role gets `AccessDenied` on both actions, while the next pipeline build is green.
- Still missing: nothing has shown that all of this survives a rebuild → step 19.

| File | Change |
|---|---|
| `infra/terraform/cluster/iam.tf` | The `EcrPullPush` statement loses its push actions; the `CosignSign` statement is removed |

**Laptop.** In `infra/terraform/cluster/iam.tf`:

1. In the statement with `sid = "EcrPullPush"`, rename it and keep only the pull actions:
```hcl
  # Pull only. The Jenkins build pods push with their own role (shared/irsa.tf, Jenkins guide step 3), and no
  # pod on a node may push through the node role any more.
  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }
```

2. Delete the whole statement with `sid = "CosignSign"`, including its comment. Signing now belongs to
   `medical-rag-ci` alone.

**Why:**

- **Pull stays.** The kubelet's credential provider uses the node role to pull every image the cluster runs.
- **`DescribeImages` and `ListImages` stay.** They are reads, useful when debugging a pull on a node. The teardown
  checks do not need them: they run from the workstation, whose role is separate.
- **One change, both actions.** They were added for a Jenkins that did not exist yet; now it does, with a role of
  its own.

**Check before:** on the laptop, `git status --short` shows only ` M infra/terraform/cluster/iam.tf`. Commit and push
(message `Take ECR push and cosign away from the node role`), then on the workstation:
```bash
git pull
make infra
```
Expect **0 to add, 1 to change, 0 to destroy**, and the change is the nodes' inline policy. Terraform prints that
policy as one long JSON string, so the whole document looks rewritten; read it for two things only: no `kms:Sign`
anywhere, and no `ecr:PutImage`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart` or `ecr:CompleteLayerUpload`.
Then type `yes`.

**Check, workstation.** First what the role may now do, without running anything:
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO_ARN=$(aws ecr describe-repositories --repository-names medical-rag --query 'repositories[0].repositoryArn' --output text)
KEY_ARN=$(aws kms describe-key --key-id alias/medical-rag-cosign --query KeyMetadata.Arn --output text)
aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$ACCOUNT:role/medical-rag-nodes" \
  --action-names ecr:PutImage ecr:BatchGetImage ecr:GetDownloadUrlForLayer --resource-arns "$REPO_ARN" \
  --query 'EvaluationResults[].[EvalActionName, EvalDecision]' --output text
aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$ACCOUNT:role/medical-rag-nodes" \
  --action-names kms:Sign --resource-arns "$KEY_ARN" \
  --query 'EvaluationResults[].[EvalActionName, EvalDecision]' --output text
```
Expected: `ecr:PutImage implicitDeny`, `ecr:BatchGetImage allowed`, `ecr:GetDownloadUrlForLayer allowed`, then
`kms:Sign implicitDeny`. Pulling still works, pushing and signing do not.

Then the same thing from a real pod that uses the node role, in a namespace that does not block IMDS:
```bash
AWSCLI=$(aws --version | cut -d' ' -f1 | cut -d/ -f2)
kubectl -n default run node-role-test --rm -it --restart=Never \
  --image="public.ecr.aws/aws-cli/aws-cli:$AWSCLI" -- \
  sh -c "aws sts get-caller-identity --query Arn --output text; \
         aws kms sign --key-id alias/medical-rag-cosign --message-type RAW --signing-algorithm ECDSA_SHA_256 \
           --message deny-test 2>&1 | tail -1"
```
Expected: an ARN containing `medical-rag-nodes`, then an error containing `AccessDenied` or `not authorized to
perform: kms:Sign`. `--message-type RAW` with a short string is used on purpose: a `DIGEST` message would have to
be exactly 32 bytes, and a size error would hide the permission error this check is about.

Then let the pipeline prove itself: push any small code change to `main` and watch the build. Expected: `Build and
push` and `SBOM and signature` both pass. If the push fails with `AccessDenied`, the build pod is not using the CI
role: step 9's check is the place to start.

**Record** both outputs and the build number that passed afterwards.

---

## Step 19 — A rebuild, the clean-up, and the evidence

**Problem now.** Everything works on the cluster that grew into it. Nothing has shown that `make down` followed by a
rebuild brings the same pipeline back, and the repository still holds the old `Jenkinsfile`'s companions.

**Why it matters.** "It works here" is not the claim this project makes. The claim is that the whole platform can be
destroyed and rebuilt from Git, and the evidence has to say so.

**This step.** Two halves. The first proves the phase is reproducible: remove the obsolete `k8s.yaml`, tear down,
rebuild, and run one release end to end. The second closes the phase on paper: preview the ECR lifecycle policy now
that the repository holds more images, measure what the cache costs, and finish the evidence and the Q&A this phase
answers.

**After this step.**
- Works: the phase is reproducible.
- Proven by: after a rebuild, a commit reaches dev with no manual step; the preview keeps every `release-*` image;
  no EBS volume is left after `make down`.
- Still missing: what the [README](../README.md#10-known-limits-and-what-is-out-of-scope) lists as out of scope,
  Kyverno first.

| File | Change |
|---|---|
| `k8s.yaml` | Deleted: replaced by the chart in `deploy/charts/medical-rag` |
| `.dockerignore` | The `k8s.yaml` line removed with it |

**Laptop.** Delete `k8s.yaml` (`git rm k8s.yaml`) and remove the `k8s.yaml` line from `.dockerignore`, then commit
and push with the message `Remove the pre-GitOps manifest`. The old `Jenkinsfile` is already gone: step 10 replaced
its contents.

**Check before the teardown**, on the workstation, so that the numbers of the rebuild can be compared:
```bash
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName
aws ec2 describe-volumes --region ap-southeast-1 \
  --filters Name=tag:project,Values=medical-rag Name=tag-key,Values=ebs.csi.aws.com/cluster \
  --query 'Volumes[].VolumeId' --output text
```
Expected: two PVCs, one for Jenkins and one for Prometheus, and two volume ids.

**Tear down and rebuild:**
```bash
time make down
time make infra
time make cluster
```
Then, in tmux window 1: `Ctrl-C` the old tunnel, which points at nodes that no longer exist, and open a new one
(`make tunnel`). `make bootstrap` needs it:
```bash
make ping
time make bootstrap
```
Expected: `make down` ends without the "EBS volumes remain" message, which is its own check that no volume is left;
then the rebuild commands, timed. Nothing about Jenkins is typed: `root` installs it at wave 4.

**Check after the rebuild**, with `make tunnel` open:
```bash
make apps
kubectl -n jenkins get pods
make oidc-check
```
Expected: every Application `Synced` and `Healthy`, `jenkins-0` running, and two `same` lines. The last one matters:
the build pods' role depends on the issuer, and the check proves it survived the rebuild.

The admin password is new, as it is generated in the cluster:
```bash
kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

Then run one release end to end: a small change to `src/`, pushed to `main`. Expected, in order: the build, the bot's
dev commit, Argo CD, a new dev pod, and a prod pull request.

**The lifecycle preview.** First count the images: the second rule keeps 30, so with fewer than that the preview
expires nothing and proves nothing.
```bash
aws ecr describe-images --repository-name medical-rag --query 'length(imageDetails)'
aws ecr get-lifecycle-policy --repository-name medical-rag --query lifecyclePolicyText --output text > /tmp/lifecycle.json
aws ecr start-lifecycle-policy-preview --repository-name medical-rag --lifecycle-policy-text file:///tmp/lifecycle.json
sleep 15
aws ecr get-lifecycle-policy-preview --repository-name medical-rag \
  --query '{status: status, expire: previewResults[].imageTags}'
```
Expected: `COMPLETE`. With **more than 30** images, `expire` lists the oldest ones and no `release-*` tag among
them: that is what step 2 promised. With fewer, `expire` is empty, which only says the repository is still small;
record the count and repeat this check later.

**The cost of the cache**, which no rule deletes ([README](../README.md#8-ecr-clean-up)):
```bash
aws ecr describe-images --repository-name medical-rag --query 'sum(imageDetails[].imageSizeInBytes)'
aws ecr describe-images --repository-name medical-rag --filter tagStatus=UNTAGGED --query 'length(imageDetails)'
```
Record both. The untagged count is not only old cache manifests: cosign's signatures and attestations are stored
the same way. They are the input for deciding, later, whether the cache needs a repository of its own.

**Finally, the writing.** In `docs/evidence/jenkins.md`, complete the "Still to check" list: stage durations,
commit-to-running for criterion #8, the Trivy counts before and after the hardening for #9, the `cosign verify`
outputs, the node role's refusals from step 18, and the rebuild timings.

Then the Q&A in `docs/common/answers.md`. Two kinds of work, and they are not the same:
- **Wrong today, so rewrite:** B4.1 still lists Syft and hadolint as pipeline stages; B4.3 and B5.2 say the build
  agents take their credentials from the node role through IMDS, which step 3 and step 18 changed.
- **Only a `[điền]` to fill:** B4.2 (the HIGH count from the report), B4.5 (the skip guard's real condition) and
  B5.1 (where the Jenkins admin password lives). Also update the index table at the top of that file.

A5.5 and A5.6 need nothing: their remaining `[điền]` is about Kyverno, which is out of scope
([README](../README.md#10-known-limits-and-what-is-out-of-scope)). Last, reread `docs/jenkins/README.md` and correct
anything this phase decided differently.

**Record** the rebuild timings, the preview result, the repository size, and the release that ran after the rebuild.

---

[← Part 3](3-pipeline.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Troubleshooting](troubleshooting.md)
