# GitOps phase — 2026-09-18

Argo CD installs everything that runs inside the cluster from `deploy/argocd/`. It was bootstrapped once
with `make bootstrap`, then took over its own chart. Versions: Argo CD chart 10.9.2 (v3.5.3),
ingress-nginx 4.15.1, aws-ebs-csi-driver 2.66.0, external-secrets 2.10.0, cert-manager v1.21.2,
kube-prometheus-stack 91.4.1, Rancher 2.15.1. Region `ap-southeast-1`.

## Rebuild from nothing

Measured on 2026-09-18, starting from a destroyed cluster stack. The shared and bootstrap stacks were
kept, as designed.

| # | Step | Measured |
|---|---|---|
| 1 | `time make infra` | **4 m 45 s** (`real 4m45.440s`) |
| 2 | `time make cluster` | **6 m 11 s** (`real 6m11.307s`) |
| 3 | `time make bootstrap` | **52 s** (`real 0m52.113s`) |
| 4 | `time kubectl -n argocd wait application/root --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m` | **2 m 22 s** (`real 2m22.179s`), `condition met` |

**Empty cluster stack → the whole platform Healthy: 14 m 11 s of measured command time**, of which
Argo CD is 3 m 14 s: 52 s to install itself, then 2 m 22 s for its nine Applications to turn `Healthy`.
The gaps between the commands, such as the SSM agents registering and opening `make tunnel`, were not
timed.

Step 4 waits on `root` alone. That is enough because `root` only turns `Healthy` when every child
Application is, thanks to the Application health check in `values/argocd.yaml`.

## Certificates

| Check | Result |
|---|---|
| `kubectl -n ingress-nginx get certificate wildcard-recruitai` | `READY True`, age **3 m 8 s** at the check |
| Issuer | `letsencrypt-production` |
| `kubectl -n ingress-nginx get certificaterequests` | **One request**, `wildcard-recruitai-1`, age 3 m 7 s |
| Backup in `medical-rag/wildcard-tls` vs the live Secret, earlier in the session | Same `notAfter`, both issued by Let's Encrypt production |

One `CertificateRequest` means cert-manager ordered a new certificate: the restore did not stop the
order. The restore `ExternalSecret` is in Git, at
`deploy/argocd/manifests/platform-secrets/wildcard-tls-restore.yaml`, and it reported `SecretSynced`
after the rebuild, so **why it did not take effect is not established**. Not captured at the time:
whether the Secret `wildcard-recruitai-tls` existed before the `Certificate` synced, the annotations on
the restored Secret, and cert-manager's own reason in the `Certificate` events.

This rebuild therefore spent one of the 5 certificates Let's Encrypt allows for the same set of names in
7 days. The mechanism stays unproven until a rebuild ends with `No resources found` for certificate
requests.

## Still to record

- `make apps`: nine Applications plus `root`, all `Synced` and `Healthy`, and a screenshot of the
  Argo CD Applications page (criterion #5).
- The Argo CD UI from the laptop: timeout without the VPN, `200` with it.
- Monitoring (criterion 5a): the active target list with `kube-etcd`, `kube-scheduler`,
  `kube-controller-manager` and `kube-proxy` all `up`, three each; `amtool alert query` showing only
  `Watchdog`; the test alert email; a screenshot of the Grafana etcd dashboard.
- Rancher (criterion #4): the security group query returning `[]`, the `308` answer from the public NLB,
  `Verification: OK` from the WireGuard gateway, the WireGuard handshake time, the timeout without the
  VPN and `pong` with it, and `Test-NetConnection` `True` on 443 and `False` on 6443.
- `time make down`: the last line it prints before `infra-destroy`, `Destroy complete!`, and
  `describe-volumes` returning no CSI volume afterwards.
- A rebuild that ends with no `CertificateRequest`, and an `openssl x509` `notAfter` equal to the one
  recorded before the teardown, to prove the certificate survives.

## Problems found and fixed during this phase

| Problem | Root cause | Fix |
|---|---|---|
| `make bootstrap` on a running cluster: `Apply failed with 1 conflict: conflict with "argocd-controller"` on two NetworkPolicies and the applicationset Deployment | Argo CD manages its own chart with server-side apply, and Helm 4 also applies server-side. Two field managers claimed the same fields | `make bootstrap` now installs the chart only while the `argocd` Application does not exist; afterwards it applies `root.yaml` alone |
| `cert-manager` Application stuck `Unknown`, `ComparisonError: open …/values/cert-manager.yaml: no such file or directory` | The values file was committed as `cert-manger.yaml`, a typo. Argo CD reads Git, so a correct file on the workstation would not have helped | `git mv` to `cert-manager.yaml` and rewrite its content, then `refresh=hard` because the error was cached. `deploy/argocd/apps/cert-manger.yaml` still carries the same typo in its file name |
| `platform-tls` `OutOfSync` / `Missing`, sync retrying forever | The restore `ExternalSecret` sat in the same Application as the backup. It failed with `could not get secret data from provider` because `medical-rag/wildcard-tls` was still empty, and its failure blocked the later sync wave that creates the `PushSecret`. The backup could never be written, so the restore could never succeed | Removed the restore from `platform-tls`; the `PushSecret` then synced and filled the secret, and the restore moved to `platform-secrets` (wave -1), which runs before the `Certificate` on a rebuild. `ServerSideDiff=true` was also added to `platform-tls` so the diff matches what the API server applies |
| Grafana answered `502 Bad Gateway` right after login | Memory: the pod restarted under the `256Mi` limit while loading its bundled dashboards. The kill reason was not captured, so this is the likely cause, not a proven one | `values/kube-prometheus-stack.yaml`: request 128Mi → 192Mi, limit 256Mi → 512Mi. The guide still shows 256Mi and needs the same change |
| The backup held a Let's Encrypt **staging** certificate | Step 8 was done before switching the issuer to production, so `PushSecret` copied whatever was in the Secret at the time | Switched to `letsencrypt-production`, then compared `notAfter` and the issuer of the backup against the live Secret until they matched |
| `amtool alert add` printed a parser warning about UTF-8 matchers | The annotation value contains spaces and the shell removed the quotes before `amtool` saw them | Wrap the argument in single quotes: `--annotation='summary="…"'`. Not yet applied to the guide |
