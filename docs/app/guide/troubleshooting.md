# App guide — Troubleshooting

[Index](../guide.md) · [Concepts](0-concepts.md) · [Part 1](1-pod-identity.md) · [Part 2](2-image-and-index.md) · [Part 3](3-dev.md) · [Part 4](4-prod-and-measure.md)

Find the symptom, read the cause, fix that, then repeat the step's check. When nothing here matches,
stop and collect the exact output before changing anything.

## Part 1: workload identity

| Symptom | Cause and fix |
|---|---|
| Step 1: `BlockPublicPolicy` or `RestrictPublicBuckets` is `true` at account level | Public bucket policies are disabled for the whole account. Do not turn that off. The issuer would have to be served through CloudFront from a private bucket instead, which changes the issuer URL and is not in this guide yet. Stop and decide first |
| Step 1: `head-bucket` returns `403` | Another account owns `medical-rag-oidc-<account>`. The name must change in `shared/oidc.tf` and `group_vars/all.yml` together, before anything is created |
| Step 2: `VersionIdsToStages` is not `null` | A key is already stored. If step 4 has run, that key is in use, and replacing it breaks every role until the new documents are published. Keep it. If you really must start again, the order is: new key, rebuild (step 4), publish, then delete the two old objects in the bucket by hand. It cannot be done in place |
| Step 2: round-trip prints a diff, not `MATCH` | The secret holds something other than `sa.key` (a wrong file name after `file://`). Put the right file, as long as step 4 has not run yet |
| Step 3: the plan shows `must be replaced` for the bucket | Something changed the bucket name. Stop: a replaced issuer bucket means a new issuer URL. Find the change first |
| Step 3: `AccessDenied` on `PutBucketPolicy` | Usually the bucket's own public access block had not taken effect yet: S3 applies it with a delay. Run `make shared` again; the plan should show only the policy to add. If it fails again, account-level Block Public Access was switched on after step 1: see the first row |
| Step 4: `Refuse to go on with a cluster built with a different key` | The running cluster was built before step 4, or with another key. Rebuild: `make down`, `make infra`, `make cluster` |
| Step 4: `Read the service-account signing key` fails, output hidden | `no_log` hides the error. Run the same command on the workstation to see it: `aws secretsmanager get-secret-value --secret-id medical-rag/sa-signer --query SecretString --output text >/dev/null` |
| Step 4: `Validate the kubeadm configuration` fails | Its message names the field. Usually indentation: `extraArgs` must sit under `apiServer:` at the same level as `certSANs` |
| Step 4: `kubeadm init` times out waiting for the control plane | kube-apiserver does not start, typically because of a misspelt flag or a wrong value in `extraArgs` (validation does not check them). On node 1: `sudo crictl ps -a \| grep kube-apiserver`, then `sudo crictl logs <id>` names the flag |
| Step 4: `.issuer` is still `https://kubernetes.default.svc.cluster.local` | The API server signs with the first issuer it is given. Either this cluster was built before step 4 (rebuild), or the S3 URL is not the first `service-account-issuer` (step 4, check 3) |
| Step 4: the `sa.pub` hashes differ between nodes | A join did not receive the key through `--upload-certs`. A successful join shows only `changed` in the `make cluster` output; to see kubeadm's own messages, rebuild and add `-v` to the `ansible-playbook` line of the `cluster` target for that run. Do not copy the key by hand |
| Step 4: an Application stays `Degraded` or `Progressing` after the rebuild | Look for `invalid bearer token` or `audience` in its pods' logs: a component asked for an audience outside `api-audiences`. Record which one before changing the list |
| Step 5: `The API server's issuer is …, expected …` | Same as the `.issuer` row above |
| Step 5: `DIFFERENT` | The cluster signs with a different key than the one published. **Do not overwrite.** Compare `sha256sum /etc/kubernetes/pki/sa.pub` on node 1 with step 2's record. If they differ, the cluster was built with another key: rebuild with step 4 in place |
| Step 5: `PreconditionFailed` from `put-object` | The object already exists, but `curl` could not read it. Check the bucket policy (`get-bucket-policy-status`), then run `make oidc-check` |
| Step 6: `terraform plan` says `thumbprint_list` is required | The provider is older than expected. `terraform -chdir=infra/terraform/shared providers` shows the version. Upgrade it within `~> 6.64` rather than adding a thumbprint by hand |
| Step 6: `CreateOpenIDConnectProvider` fails to reach the issuer | Step 5 has not published the documents, or they are not public. `ISSUER=$(terraform -chdir=infra/terraform/shared output -raw oidc_issuer_url)`, then `curl "$ISSUER/.well-known/openid-configuration"` must return JSON |
| Step 7: a pod stays `ImagePullBackOff` | The `public.ecr.aws/aws-cli/aws-cli` tag does not exist. Use a tag listed in the ECR Public Gallery, then reapply |
| Step 7.1: the ARN contains `medical-rag-nodes` | The SDK did not use the token and fell back to IMDS. `kubectl -n medical-rag-dev exec irsa-proof -- env \| grep AWS_` must show all four variables. `… -- ls -l /var/run/secrets/aws/token` must show the file |
| Step 7.1: `InvalidIdentityToken: No OpenIDConnect provider found` | The issuer in the token is not the provider URL. Decode the token's payload and compare `iss` with `aws iam list-open-id-connect-providers`: `kubectl -n medical-rag-dev exec irsa-proof -- cat /var/run/secrets/aws/token \| cut -d. -f2 \| tr '_-' '/+' \| base64 -d 2>/dev/null; echo`. A missing `}` at the end is only base64 padding |
| Step 7.1: `InvalidIdentityToken: Couldn't retrieve verification key` | AWS could not fetch the key set: `make oidc-check` |
| Step 7.1: `AccessDenied … AssumeRoleWithWebIdentity` for `medical-rag` | The `sub` or `aud` condition does not match. The payload shows `sub` (`system:serviceaccount:medical-rag-dev:medical-rag`) and `aud` (`sts.amazonaws.com`). Compare them with step 6's trust policy |
| Step 7.1: `Permission denied` reading the token | The token file is not readable by UID 10001. Keep `runAsUser` and `fsGroup` at pod level, as in the manifest |
| Step 7.6: still `exit=0` after the policy | The policy selects no pod (`kubectl -n medical-rag-dev get pods --show-labels`: `app=irsa-proof`), or Calico is not enforcing: `kubectl get pods -n calico-system` |
| Step 7.6: STS times out after the policy | DNS is blocked: check the CoreDNS pod labels, `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| Step 9: `AccessDenied` for the app role too | The app role never had permissions on its own. Check step 6's inline policy with `aws iam get-role-policy --role-name medical-rag-app-dev --policy-name medical-rag-app-dev` |

## Part 2: image, index and corpus

| Symptom | Cause and fix |
|---|---|
| Step 10: `permission denied … docker.sock` | The `docker` group applies at the next login: `exit`, then `sudo su - ubuntu` again |
| Step 10: fewer or more than `26 passed` | A test was added or lost. Compare `tests/test_index.py` with the step. Anything that fails is fixed on the laptop and pushed again before step 11 |
| Step 11: `Uncommitted changes` | Something on the workstation differs from Git: `git status`. Nothing should be edited on the workstation; discard it, or commit it from the laptop |
| Step 11: `HEAD is not origin/main` | Run `git pull`. If `git status` says the branches have diverged, the workstation has a local commit: remove it |
| Step 11: `… is already in ECR, and tags are immutable` | This commit already has an image. That is the gate working. Build a new image only from a new commit |
| Step 11: any other AWS error printed by the gate | Usually credentials or region. The target stops before building. Fix, then run it again |
| Step 11: `docker buildx` is killed during `uv sync` | Out of memory. `free -h` must show the 2 GB of swap; close other work in tmux and run again |
| Step 12: a version other than `cc759ae1a093` | The PDF, `CHUNK_SIZE`, `CHUNK_OVERLAP` or `EMBEDDING_MODEL_NAME` differs from the local run. `git log -- data/ src/app/config/config.py` shows what changed. Decide deliberately which version is right before pinning it |
| Step 13: `head-object` returns `200` | The corpus is already uploaded. Skip the upload and run the check. If the checksum differs, stop: the object in S3 is not the file in Git |
| Step 13: `Unknown options: --if-none-match` | The AWS CLI on the workstation is too old for conditional writes. Update it with the same installer as `workstation-init.sh`, then run again |
| Step 13: `PreconditionFailed` | The object appeared between the check and the upload. Run the check |


## Parts 3 and 4: the chart, dev and prod

| Symptom | Cause and fix |
|---|---|
| Step 14: `getent` returns nothing for `dev.recruitai.io.vn` | The name was looked up before the record existed, and the answer "no such name" is cached. Wait a few minutes; `getent ahostsv4 dev.recruitai.io.vn` from another machine, or `dig @8.8.8.8 dev.recruitai.io.vn` if `dig` exists, shows the record |
| Step 15: the gate shows an Application whose last sync is not `Succeeded` | Look at it first: `kubectl -n argocd get applications.argoproj.io <name> -o jsonpath='{.status.operationState.message}'`. The new rule ignores unlabelled Applications, but a failed platform sync deserves a look before anything else changes |
| Step 15: `yq` prints `0` | The `if` block is not inside the Lua string. It must be indented exactly like the lines around it (six spaces) |
| Branch check: `helm lint` or `helm template` fails with `… is required` | A required value is missing: `aws.accountId`, `image.tag`, `index.version`, `environment` or `ingress.host`. Pass both values files, `common.yaml` first |
| Branch check: `field is immutable` for `job.batch/index-build` | The Job was not filtered out. In a namespace where the Job already ran, keep the `yq 'select(.kind != null and .kind != "Job")'` line of the check: a dry run cannot change a finished Job, and Argo CD recreates it on every sync anyway |
| Branch check: `Warning: would violate PodSecurity "restricted:latest"` | A pod or container lost a security setting. Compare with `medical-rag.podSecurity` and `medical-rag.containerSecurity` in `_helpers.tpl`. The pods would be refused by `enforce` |
| Step 16: `medical-rag-dev` does not appear | `root` has not read the new file yet: refresh `root` (step 16). `kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.status.sync.status}'` should turn `Synced` |
| Step 16: the Job never starts; the ExternalSecret is not `Ready` | `kubectl -n medical-rag-dev describe externalsecrets.external-secrets.io app-secrets`. `AccessDenied`: the node role cannot read `medical-rag/app-dev` (Part 1 step 8, `make infra`). `ResourceNotFound` or no current version: the secret has no value |
| Step 16: the Job fails with `AccessDenied` on `AssumeRoleWithWebIdentity` | The ServiceAccount is not exactly `medical-rag-index-builder`, or the namespace is not `medical-rag-dev`: the builder role's trust policy names both (Part 1 step 6) |
| Step 16: the Job fails with `… but cc759ae1a093 was expected` | The corpus in S3 does not hash to the pinned version: compare its checksum with step 13, and the chunk settings in the image with step 12 |
| Step 16: the Job fails on Hugging Face (`429`, `503`) | The quota or the service. The Job has no second attempt on purpose. Wait, then start one sync by hand with the `kubectl patch` of step 17 point 3 (or **Sync** in the Argo CD UI). A new commit does not help unless it changes the rendered objects |
| After a fix, `root` stays `Degraded` and the app's last sync stays `Failed` | The fix made the rendered objects equal the live ones, so the app is `Synced` and automated sync does not run. Start one sync by hand (step 17 point 3) |
| `kubectl wait … --for=condition=…` fails at once with `NotFound` | The object does not exist yet: Argo CD creates it later in the sync. Run the `--for=create` line first, as the steps do |
| Step 16: the Job is `OOMKilled` | `kubectl -n medical-rag-dev describe pod -l job-name=index-build` shows it. Raise `indexBuild.resources.limits.memory` in the chart's `values.yaml` |
| Step 17: the pod stays in `Init:Error` or `Init:CrashLoopBackOff` | `kubectl -n medical-rag-dev logs deployment/medical-rag -c index-pull`. `AccessDenied` on `AssumeRoleWithWebIdentity`: the ServiceAccount is not `medical-rag`. `… not found`: the version is not in S3 |
| Step 17: the pod is `Running` but never `Ready` | `kubectl -n medical-rag-dev logs deployment/medical-rag -c app`: the chain build is retried with its last error. A missing key in `app-secrets` or an unreachable model API shows here |
| Step 17: `CreateContainerConfigError` | The Secret `app-secrets` does not exist yet, or lacks a key. See the ExternalSecret row above |
| Step 17: the IMDS check connects instead of timing out | The NetworkPolicy `default` is missing or does not select the pod: `kubectl -n medical-rag-dev get networkpolicies`. Calico must be running: `kubectl get pods -n calico-system` |
| Step 17, failure test: `root` stays `Healthy` | The Application lacks the label `medical-rag/report-failed-sync`, or step 15's rule is not in `argocd-cm` (step 15 check). Revert the test commit first |
| Step 18: `curl` on `/` returns `404` | The Ingress did not match: `kubectl -n medical-rag-dev get ingress medical-rag` must show the host. `Exact` paths do not match `/?x=1` style variations in some clients; use the plain URL |
| Step 18: `curl` on `/` returns `502` or `504` | nginx cannot reach the pod: the policy `allow-from-ingress-nginx` must exist, and the controller pods must carry `app.kubernetes.io/name: ingress-nginx` (`kubectl -n ingress-nginx get pods --show-labels`) |
| Step 18: a question returns `503` | The chain is not ready yet: wait for `Ready` |
| Step 18: `429` | The rate limit (`ingress.limitRpm`) was hit. Wait a minute |
| Step 19: `promq` prints nothing | Prometheus has not picked up the ServiceMonitor yet (up to two minutes), or cannot reach the pod: the policy `allow-from-prometheus` must exist, and `kubectl -n monitoring get pods --show-labels` must show `app.kubernetes.io/name=prometheus` |
| Step 19: `promq` fails with `services "kube-prometheus-stack-prometheus" not found` | The Service has another name: `kubectl -n monitoring get svc`, and use that name in `promq` |
| Step 20: one prod pod stays `Pending` | `kubectl -n medical-rag-prod describe pod <name>`: `didn't match pod topology spread constraints` means only one node has room. Check the CPU requests with `kubectl describe nodes \| grep -A8 "Allocated resources"` |
| Step 20: the prod Job embeds again | dev and prod pin different versions, or dev never built this one. Compare `index.version` in both values files |
| Step 21: `promq` returns nothing for `container="app"` | The kubelet's cAdvisor metrics are scraped under the job `kubelet`: `promq 'count(container_memory_working_set_bytes{namespace="medical-rag-dev"})'` must be above zero |

---

[Index](../guide.md) · [Part 1](1-pod-identity.md) · [Part 2](2-image-and-index.md)
