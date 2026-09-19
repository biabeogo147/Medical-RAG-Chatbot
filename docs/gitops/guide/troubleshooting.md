# GitOps guide — Troubleshooting

[Index](../guide.md) · [Part 1](1-argocd.md) · [Part 2](2-foundation.md) · [Part 3](3-certificates-and-argocd-ui.md) · [Part 4](4-monitoring-and-rancher.md) · [Part 5](5-teardown-and-rebuild.md)

---

| Symptom | Cause and fix |
|---|---|
| `connection refused` on `127.0.0.1:6443` | The tunnel window (1) closed, or node 1 is stopped. Run `make tunnel` again in window 1 |
| An Application stays `OutOfSync` right after a push | Argo CD has not looked at Git yet. Run the refresh command from [the loop](../guide.md#the-loop-for-every-step), or wait three minutes |
| `Unknown` sync status with `authentication required` or `repository not found` | The `repoURL` is misspelt, or the repository was made private |
| `metadata.annotations: Too long` | `ServerSideApply=true` is missing from that Application's `syncOptions` |
| All Applications start at once; `platform-secrets` fails with `no matches for kind ExternalSecret` | The Application health check is missing from `values/argocd.yaml`. Fix it and run `make bootstrap`; the failed Application retries by itself |
| `argocd` stays `OutOfSync` after `make bootstrap` | The values file or the version differs between Helm and Git. Both must come from the same files; do not pass extra `--set` to Helm |
| `missing separator` from make | A recipe line starts with spaces instead of a tab |
| ingress target groups stay `unhealthy` | The NodePorts in `values/ingress-nginx.yaml` do not match Terraform (30080, 30443), or the controller pods are not on every node |
| A PVC stays `Pending` with `waiting for first consumer` | Normal until a pod uses it. With a pod: `kubectl describe pvc` shows the driver's error |
| A PVC stays `Pending` with `UnauthorizedOperation` or `no EC2 IMDS role found` | The driver cannot use the node role: check the `AmazonEBSCSIDriverPolicy` attachment in Terraform and the metadata hop limit of 2 on the nodes |
| `ClusterSecretStore` not `Valid` | Same two causes. `kubectl -n external-secrets logs deployment/external-secrets` shows the AWS error |
| ExternalSecret `SecretSyncedError` with `AccessDeniedException` | The secret name is not one of the six the node role may read (names in `infra/terraform/cluster/main.tf`, permission in `iam.tf`) |
| ExternalSecret `SecretSyncedError` with `ResourceNotFoundException` or no current version | The value was never stored: Terraform guide step 17 |
| Grafana pod in `CreateContainerConfigError` | The `grafana-admin` Secret does not exist yet. Refresh all Applications ([the loop](../guide.md#the-loop-for-every-step)), then check `kubectl -n monitoring get externalsecret` |
| `rancher` fails with `chart requires kubeVersion` | The cluster was upgraded past what chart 2.15.1 accepts. Follow the compatibility gate in design §4.2.1 |
| `rancher` keeps flipping between synced and out of sync around `bootstrap-secret` | `bootstrapPassword` was set in `values/rancher.yaml`. Remove it |
| `Verification error: unable to get local issuer certificate` from the gateway | `tls.crt` holds only the server certificate. Store the full chain again (Terraform guide step 17); External Secrets picks it up within the hour |
| An internal UI with VPN: timeout | No recent handshake, or the laptop is not using `10.10.0.2` for DNS. See Terraform guide step 18 |
| `make down`: the Application delete runs into its 10-minute timeout | Something it installed is stuck in `Terminating`. `kubectl -n monitoring get prometheus -o yaml` and look at `metadata.finalizers`; a finalizer whose operator was already deleted must be removed by hand |
| `make down`: the PVC delete runs into its 15-minute timeout | A pod still mounts the PVC (`kubectl describe pvc` lists it under `Used By`). Delete that workload, then run `make down` again |
| `make down` stops with `EBS volumes remain` | `kubectl get pv` and `kubectl describe pv <name>` show why; the driver must still be running. Fix it, then run `make down` again |
| cert-manager: `Certificate` stays `READY False`, challenge `pending` with `AccessDenied` | The node role cannot change the TXT record: Terraform guide step 19 not applied to this cluster (`make infra`), or the record name in the IAM condition does not match the domain |
| cert-manager: challenge waits with `propagation check failed` | Normal for up to a few minutes while Route 53 publishes the record. If it lasts longer, check that the registrar still points at the Route 53 name servers (Terraform guide step 17) |
| cert-manager: `too many certificates already issued` | The Let's Encrypt limit of 5 per week for these names. Wait (the error says until when), and make sure [step 8](3-certificates-and-argocd-ui.md#step-8--keep-the-certificate-across-rebuilds) is in place so rebuilds stop ordering new ones. Do **not** switch `issuerRef` to `letsencrypt-staging` on the running cluster: cert-manager issues again at once and the PushSecret copies the staging certificate over the production backup (this happened on 2026-09-18, commit `57da1c6`). A certificate that is already serving keeps serving until it expires, so waiting costs nothing. For a staging test, follow the note in `platform-tls/wildcard-certificate.yaml` |
| The browser shows `Kubernetes Ingress Controller Fake Certificate` | The wildcard Secret does not exist yet, so nginx serves its placeholder. `kubectl -n ingress-nginx get certificate` shows why |
| After a rebuild, `certificaterequests` lists a new request | The restore did not satisfy cert-manager. `kubectl -n ingress-nginx describe certificate wildcard-recruitai` names the reason in its events; compare the restored Secret's `cert-manager.io/*` annotations with the Certificate |
| `platform-secrets` `Degraded` on the very first bootstrap, `wildcard-recruitai-tls-restore` failing | The backup in Secrets Manager is still empty, which is expected before [step 8](3-certificates-and-argocd-ui.md#step-8--keep-the-certificate-across-rebuilds) has ever run. Remove `wildcard-tls-restore.yaml`, let the certificate be issued and backed up, then add the file back |
| PushSecret `SecretSyncedError` with `AccessDeniedException` on `DeleteResourcePolicy` or `PutSecretValue` | External Secrets calls both on every push. The `BackupWildcardCertificate` statement in `iam.tf` must allow both (Terraform guide step 19) |
| PushSecret `SecretSyncedError` mentioning `managed-by` | The secret lacks the tag `managed-by=external-secrets`. Terraform guide step 19 sets it; run `make shared` |
| The internal UI answers `403 Forbidden` through the VPN | The request did not arrive with a VPC source address. Check that `externalTrafficPolicy` is `Local` on the ingress-nginx Service ([step 4](2-foundation.md#step-4--ingress-nginx)) |
| No test alert email | `kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager` shows the SMTP error. `535 … Username and Password not accepted`: wrong app password, or 2-Step Verification is off. Fix the value with `put-secret-value`; it arrives within the hour, or at once after `kubectl -n monitoring annotate externalsecret alertmanager-email force-sync=$(date +%s) --overwrite` |
| A target `kube-etcd`, `kube-scheduler`, `kube-controller-manager` or `kube-proxy` is `down` | Ansible guide step 11 is not in effect: this cluster was built before it. Rebuild |
| `make down` destroyed the cluster but a volume is left (for example after a manual `make infra-destroy`) | Find it with the `describe-volumes` command of [step 12](5-teardown-and-rebuild.md#step-12--make-down) and delete it with `aws ec2 delete-volume --volume-id <id>` |
