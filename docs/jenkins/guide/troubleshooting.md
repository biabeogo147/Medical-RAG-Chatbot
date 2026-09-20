# Jenkins guide — Troubleshooting

[Index](../guide.md) · [Concepts](0-concepts.md) · [Part 1](1-measure-and-foundations.md)

Find the symptom, read the cause, fix that, then repeat the step's check. When nothing here matches, stop and
collect the exact output before changing anything.

## Part 1: measure, then lay the foundations

| Symptom | Cause and fix |
|---|---|
| Step 1.1: `echo "$IMAGE"` prints `…/medical-rag:` with no tag | `yq` found no `image.tag` in `deploy/envs/prod/values.yaml`: `git pull` first, and check you are in `~/Medical-RAG-Chatbot` |
| Step 1.1: `docker pull` says `no basic auth credentials` or `denied` | The ECR login expired (12 hours) or went to another registry. Repeat the `docker login` line |
| Step 1.1: Trivy fails while downloading its database | The workstation cannot reach `mirror.gcr.io` or GitHub's container registry, where Trivy keeps it. Run the command again; if it keeps failing, record the message before trying anything else |
| Step 1.1: the `jq` count prints nothing | The report is empty or at another path: `ls -l ~/ci-baseline`. A report with no `Vulnerabilities` at all would print nothing too; open it and look at `.Results[].Target` |
| Step 1.2: `The connection to the server 127.0.0.1:6443 was refused` | `make tunnel` is not open in window 1 |
| Step 1.2: an Application is not `Healthy`, or an app pod is missing | Do not take the numbers yet. Free room measured without the app is room Jenkins will not have. Fix the Application first (app guide troubleshooting), then measure |
| Step 1.3: every node fails with `404 … HeadBucket` | The account id passed to Ansible was empty, so the Session Manager transfer bucket name ended in nothing (`inventory/group_vars/nodes.yml`). Use the command as written, which reads the id itself. If it still fails, the cluster stack is down: `aws s3api head-bucket --bucket "medical-rag-ssm-transfer-$(aws sts get-caller-identity --query Account --output text)"` |
| Step 1.3: `UNREACHABLE` or `Failed to connect` | The nodes are not running, or Session Manager is not ready yet after a rebuild. `make ping` must work first |
| Step 1.3: `sysctl: cannot stat /proc/sys/kernel/apparmor_restrict_unprivileged_userns` | The kernel has no such setting: Ubuntu's restriction does not exist on this node. Record it; step 1.4 decides on its own |
| Step 1.4: the pod stays `Pending` | No node has room for it, or the images cannot be pulled. `kubectl -n buildkit-probe describe pod -l job-name=buildkit-probe` names the reason. Record it: it is also a capacity measurement |
| Step 1.4: `ErrImagePull` for `busybox` or `moby/buildkit` | Docker Hub refused the pull (rate limit) or the node has no internet route. Wait and repeat 1.4 after deleting the namespace |
| Step 1.4: the pod is refused with `violates PodSecurity` | The namespace label is missing: the `Namespace` part of the manifest was not applied. Delete the namespace and apply the whole manifest again |
| Step 1.4: the log shows `permission denied` or `operation not permitted` from `rootlesskit`, `newuidmap` or `mount` | This is the result step 1.4 is looking for, not a mistake: the node refuses rootless BuildKit. Record the full error and go to step 5 |
| Step 1.4: `succeeded= failed=` after five minutes, and the pod is not `Completed` or `Error` | The Job never ran its build, so this says nothing about BuildKit yet. `kubectl -n buildkit-probe describe pod -l job-name=buildkit-probe` shows why (a slow image pull hits the Job's five-minute deadline, for example). Delete the namespace and run 1.4 again |
| Step 1.4: `kubectl delete namespace` hangs | The Job's pod is still terminating. Wait a minute; the namespace goes once the pod is gone |
| Step 2: the plan shows changes other than `aws_ecr_lifecycle_policy.app` | Something else in the shared stack changed since the last apply. Type nothing, find the change first (`git log -- infra/terraform/shared`) |
| Step 2: the image count is 30 or more | The repository holds more images than expected, and the second rule would expire some of them. Record the list (`aws ecr describe-images --repository-name medical-rag --query 'imageDetails[].imageTags'`) before anything else |
| Step 2: the gate's message names `release-` with nothing after it | `$TAG` is empty in this shell, so the gate proved nothing. Set `TAG` with the block above and repeat the gate before the `put-image` line |
| Step 2: `put-image` fails with `ImageAlreadyExistsException` | The `release-` tag was already added: the check is `describe-images` with that tag, which must show the same digest as prod's values |
| Step 2: `put-image` fails with `ImageTagAlreadyExistsException` | The tag exists on a different image. Stop: compare its digest with prod's values before changing anything |
| Step 2: `put-image` returns a digest different from prod's | The manifest changed on its way through the shell (a file with a trailing newline, for example). Stop and record both digests; the new tag points at an image nobody runs |
| Step 3: the plan shows changes to the other three role policies | The map gives a role a different document than the ternary did. Compare `irsa_policies` with the old line: `index-builder` gets `index_build`, the others `index_read` |
| Step 3: `Reference to undeclared resource` for `aws_kms_key.cosign` or `aws_ecr_repository.app` | The block was pasted into the wrong stack. It belongs in `infra/terraform/shared/irsa.tf` |
| Step 3: `sim` prints `None None` or an error about the ARN | A variable is empty in this shell: run the first block of 1.1 again, then the `ROLE_ARN`… lines |
| Step 3: the simulator allows `s3:PutObject` or `secretsmanager:GetSecretValue` | A statement is broader than shown. `aws iam get-role-policy --role-name medical-rag-ci --policy-name medical-rag-ci` prints what was applied |
| Step 4: `getent` prints nothing for `jenkins.` | The resolver cached "not found" from before the record existed. Wait five minutes. `aws route53 list-resource-record-sets` for the zone shows whether the record exists |
| Step 4: `curl.exe` times out | WireGuard is off, or the tunnel is up but routes nothing to the internal load balancer. Check that `https://argocd.recruitai.io.vn/` opens first |
| Step 4: a certificate error instead of `404` | ingress-nginx is not serving the wildcard as its default. `argocd.` shows the same error then: see the GitOps guide's certificate troubleshooting |

## Parts 2–4: Jenkins and the pipeline

| Symptom | Cause and fix |
|---|---|
| Step 6: `jenkins-github` is `SecretSyncedError`, and `kubectl get secret jenkins-github` says `not found` | The ExternalSecret found nothing to copy. `kubectl -n jenkins get externalsecret jenkins-github -o jsonpath='{.status.conditions[*].message}'` names which: *can't find the specified secret value* means `medical-rag/github` is empty (the usual case — Terraform creates it empty); a message naming `token` means the JSON has a different key; `AccessDenied` means the node role cannot read it. Fix, then `kubectl -n jenkins annotate externalsecret jenkins-github force-sync="$(date +%s)" --overwrite`, because `refreshInterval` is 1h. `jenkins-platform` goes `OutOfSync` until `selfHeal` removes the annotation, which is harmless |
| Step 7: the `hostPath` pod is **accepted** instead of refused | The API server has not compiled the policy yet. `kubectl get validatingadmissionpolicy jenkins-agents-restrictions -o jsonpath='{.metadata.generation} {.status.observedGeneration}'` must print two equal numbers; until then the policy is listed but not enforced, and every dry run passes. Wait and repeat — do not change the policy |
| Step 7: a refusal quotes a different rule than the one you triggered | The expressions do not say what they look like they say. Record which message came back for which pod before changing anything |
| Step 8: the plugin-version command ends in `jq: parse error: Invalid numeric literal at line 1, column 10` | `jq` was handed HTML, not JSON. `updates.jenkins.io` answers `307` and redirects to a mirror, so the flags must be `curl -fsSL`. To see which it is: `curl -sS -o /tmp/uc.json -w 'http=%{http_code} redirect=%{redirect_url}
' <url>` then `head -c 200 /tmp/uc.json` — a `30x` with a `redirect` is the redirect, a `200` with `text/html` is something in the middle, `size=0` is no route out |
| Step 8: the plugin command prints fewer than four lines | A plugin was renamed or removed upstream. Do not pin the three that worked: find the new name on `plugins.jenkins.io` first |
| Step 8: `jenkins-0` is `Init:CrashLoopBackOff`, and the `init` container logs `Illegal character in path` for a URL containing `<version>` | The plugin placeholders in `deploy/argocd/values/jenkins.yaml` were never replaced. `jenkins-plugin-cli` builds `…/job-dsl/<version>/job-dsl.hpi` and fails. The "prerequisites not met" lines below it are a consequence: the string is not a version, so no dependency minimum can be satisfied. Fill in the four versions and push. The plugin list reaches the pod through a ConfigMap, so the StatefulSet may not roll by itself — `kubectl -n jenkins delete pod jenkins-0` after the sync |
| Step 8: the `init` container logs `requires a newer version of Jenkins` | A plugin version from the weekly channel needs a newer core than the chart's LTS image. Re-read the versions from `https://updates.jenkins.io/stable/update-center.actual.json` |
| Step 8: `helm template … \| kubectl apply -n jenkins` fails with *the namespace from the provided object "jenkins-agents" does not match* | The chart renders into two namespaces since the cloud moved to `agent.namespace`. Render to a file and apply it without `-n` |
| Step 8: `jenkins` stays `Progressing`, `jenkins-0` is `Pending` | No node has 250m of CPU left, or the `gp3` volume is not bound. `kubectl -n jenkins describe pod jenkins-0` names which; compare with the free CPU recorded in evidence 1.2 |
| Step 8: the controller starts but the UI shows no job, or the credential is the literal `${jenkins-github-token}` | JCasC did not resolve the Secret: `controller.additionalExistingSecrets` must list `jenkins-github` with `keyName: token`. `kubectl -n jenkins logs jenkins-0 -c init` shows JCasC's own errors |
| Step 9: the build pod appears in the namespace `jenkins`, not `jenkins-agents` | Two clouds are defined: the chart always writes one from `agent.*`. Remove any cloud written in a `configScript` and set `agent.namespace` instead (step 8) |
| Step 9: `get-caller-identity` prints `assumed-role/medical-rag-nodes/…` | The pod did not use its token. Check that the pod's ServiceAccount is `jenkins-agent` in `jenkins-agents`, that the four `AWS_*` variables are set, and that the projected token is mounted |
| Step 9 or 10: the build pod is refused with `violates PodSecurity` or the admission policy's message | The pod in the `Jenkinsfile` asks for something step 7 refuses. `kubectl -n jenkins-agents get events --sort-by=.lastTimestamp` prints the message in full |
| Step 11: `docker login` works but the push fails with `no basic auth credentials` | BuildKit is not reading the login: both containers need `DOCKER_CONFIG` set to the same path in the shared workspace, and the login stage must run before the build stage |
| Step 11: the second build is as slow as the first | The cache was not read: check that the branch's build imports `…:buildcache`, and that the tag exists (`aws ecr describe-images --repository-name medical-rag --query 'imageDetails[?imageTags]'`) |
| Step 11: the push fails with `ImageTagAlreadyExistsException` | That commit already has an image: ECR tags are immutable. Build a new commit; do not delete the tag unless you mean to replace a release |
| Step 12: `archiveArtifacts` fails with "no artifacts found" | The scan did not reach the report. Look at the stage's log: the report is written before the gate, so a missing file means Trivy itself failed (usually the registry login) |
| Step 14: `cosign verify` fails on an image the pipeline signed | Compare the digest you verified with `describe-images`, and keep `--insecure-ignore-tlog`: the pipeline signs with `--tlog-upload=false`, so there is no log entry to check |
| Step 15: the stage stops with `The corpus in S3 is not the PDF in Git` | The PDF in Git changed and was never uploaded. Run app guide step 13, then rebuild. The pipeline never uploads the corpus itself |
| Step 16 or 17: the bot's push or pull request fails with `403` | The GitHub token expired, or a repository rule blocks it. Check that the ExternalSecret is `Ready`, then the ruleset on `main` |
| Step 17: after merging, the image has no `release-` tag | The merge was not a squash merge, so the commit lists no files and the stage's `changeset` condition did not match. Tag it by hand as in step 2, then set squash merge as the default |
| Step 18: the next build fails at the push with `AccessDenied` | The build pod is using the node role, which no longer pushes. Do not undo step 18: go back to step 9's check |
| Step 19: `make down` stops with `EBS volumes remain` | An Application holding a volume is missing the label `medical-rag/volumes: "true"`, or a StatefulSet recreated its PVC. Find it with `kubectl get pvc -A`, remove that Application's `automated` policy, then delete it |
| Step 19: `make oidc-check` prints `DIFFERENT` after the rebuild | The cluster was built with another signing key, so every build pod's token would be refused. Do not publish over it: see app guide step 4 |
