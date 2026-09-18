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
| Backup in `medical-rag/wildcard-tls` vs the live Secret | Same `notAfter`, same SHA-256 fingerprint `63:1E:4F:A2:…:66:C2:59:3C` |

The **backup** path works: the bytes in Secrets Manager are the bytes in the cluster. The **restore**
path did not run in time, so this rebuild spent one of the 5 certificates Let's Encrypt allows for the
same set of names in 7 days. That is now explained.

### Why the restore lost the race

All times below come from the cluster, not from the workstation clock. The two differ: an ESO
`LAST SYNC` column, read against a `refreshTime` that cannot move (`refreshPolicy: CreatedOnce`,
1 h interval), puts one command 69 s later than the message that carried its output. So laptop
timestamps are not usable at second precision here.

| Cluster time (UTC) | Event |
|---|---|
| ~13:39:46 | `Issuing certificate as Secret does not exist`, then `CertificateRequest wildcard-recruitai-1` one second later |
| **13:40:34** | `ExternalSecret wildcard-recruitai-tls-restore` created, and the Secret `wildcard-recruitai-tls` with it — `creationTimestamp` and `status.refreshTime` equal to the second |
| 13:41:26 | The `Certificate` reaches `Ready=True` |

**cert-manager reconciled the `Certificate` and found no Secret about 48 seconds before the restored
Secret existed**, although `platform-secrets` is wave -1 and `platform-tls` is wave 0. The
`Certificate` object itself was created at or before that reconcile, so 48 s is a lower bound on the
distance between the two Applications.

How 13:39:46 is derived, since cert-manager prints event ages rather than timestamps. Two inputs:

1. `Ready` became true at **13:41:26**, read directly off the object.
2. The same `describe` shows **100 s** between the `Issuing` event and
   `The certificate has been successfully issued`.

13:41:26 − 100 s = **13:39:46**. That step assumes `Ready` lands on the issuance, and the
certificate's own `notBefore` corroborates it: Let's Encrypt backdates `notBefore`, and the size of
that backdate measured from the later manual experiment is ≈3510 s (revision 3, `notBefore 13:08:55`,
issued ≈14:07:25). Applying 3510 s to revision 1 (`notBefore 12:42:56`) gives 13:41:26 — the same
instant, from a different route. A round 3600 s instead would put `Issuing` *after* the Secret
existed, which the event text `Secret does not exist` rules out.

So 48 s is a derived figure, not one read off a clock. What needs no derivation at all is the
ordering itself: the event says the Secret did not exist, and the Secret's `creationTimestamp` is
13:40:34.

### The cause

The Application health check that was running at the time — the cluster's `argocd-cm` was read
directly and confirmed — copied each child Application's health and never looked at its sync status:

```lua
hs.status = obj.status.health.status
```

Argo CD deliberately leaves a resource that does not exist yet out of an Application's health total
(`controller/health.go`: *"Missing resources should not affect parent app health — the OutOfSync
status already indicates resources are missing"*). So every child Application reported `Healthy` the
moment it was created, `root` released all four waves within seconds, and `platform-secrets` and
`platform-tls` ran in parallel. The gap is simply the difference between two pipelines that were
never ordered: `platform-tls` only had to wait for its `ClusterIssuer`s at its internal wave 0, while
the restore sits at internal wave 1 of `platform-secrets` and targets the `ingress-nginx` namespace,
which another Application creates.

The timings corroborate this independently. `make bootstrap` took 52 s and the wait for `root` took
2 m 22 s, so 194 s covered installing five charts, registering an ACME account, solving a DNS-01
challenge and issuing a certificate. That looks far too short for waves that waited for each other,
though no per-wave timing was captured to prove it.

`status.sync` is the fix: `controller/state.go` forces `OutOfSync` while any managed resource is
missing, so an Application that has applied half its manifests cannot be `Synced`. The check in
`deploy/argocd/values/argocd.yaml` now requires `Healthy` **and** `Synced`, refuses an Application
that reports no resources at all, and propagates `Degraded` instead of leaving `root` waiting
silently. **This is not yet proven on AWS** — see "Still to record".

### Two things this rebuild also showed

- **A failed restore destroys its own evidence.** The `PushSecret` at `platform-tls` internal wave 2
  uploaded the newly issued certificate within minutes, overwriting the backup that the restore had
  failed to use. Before the rebuild the backup read `notAfter Dec 17 09:37:36`; afterwards both backup
  and live Secret read `Dec 17 12:42:55`. Any future investigation has to capture the backup *before*
  letting the cluster settle.
- **`kubectl -n argocd get app …` is ambiguous once Rancher is installed.** It resolves to Rancher's
  `apps.catalog.cattle.io` and answers `NotFound`. Evidence commands must say
  `kubectl -n argocd get applications.argoproj.io`.

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
  recorded before the teardown, to prove the certificate survives. The same rebuild should capture
  `kubectl -n ingress-nginx get externalsecret wildcard-recruitai-tls-restore -o jsonpath='{.metadata.creationTimestamp}'`
  and the same field on the `Certificate`, so the ordering is measured directly instead of derived.
- `kubectl -n argocd get applications.argoproj.io -w` and the application-controller log from the
  moment `root` is applied, which would have shown the wave collapse as it happened rather than
  leaving it to be reconstructed.

## Problems found and fixed during this phase

| Problem | Root cause | Fix |
|---|---|---|
| `make bootstrap` on a running cluster: `Apply failed with 1 conflict: conflict with "argocd-controller"` on two NetworkPolicies and the applicationset Deployment | Argo CD manages its own chart with server-side apply, and Helm 4 also applies server-side. Two field managers claimed the same fields | `make bootstrap` now installs the chart only while the `argocd` Application does not exist; afterwards it applies `root.yaml` alone |
| `cert-manager` Application stuck `Unknown`, `ComparisonError: open …/values/cert-manager.yaml: no such file or directory` | The values file was committed as `cert-manger.yaml`, a typo. Argo CD reads Git, so a correct file on the workstation would not have helped | `git mv` to `cert-manager.yaml` and rewrite its content, then `refresh=hard` because the error was cached. `deploy/argocd/apps/cert-manger.yaml` still carries the same typo in its file name |
| `platform-tls` `OutOfSync` / `Missing`, sync retrying forever | The restore `ExternalSecret` sat in the same Application as the backup. It failed with `could not get secret data from provider` because `medical-rag/wildcard-tls` was still empty, and its failure blocked the later sync wave that creates the `PushSecret`. The backup could never be written, so the restore could never succeed | Removed the restore from `platform-tls`; the `PushSecret` then synced and filled the secret, and the restore moved to `platform-secrets` (wave -1), which runs before the `Certificate` on a rebuild. `ServerSideDiff=true` was also added to `platform-tls` so the diff matches what the API server applies |
| Grafana answered `502 Bad Gateway` right after login | Memory: the pod restarted under the `256Mi` limit while loading its bundled dashboards. The kill reason was not captured, so this is the likely cause, not a proven one | `values/kube-prometheus-stack.yaml`: request 128Mi → 192Mi, limit 256Mi → 512Mi. The guide still shows 256Mi and needs the same change |
| The backup held a Let's Encrypt **staging** certificate | Step 8 was done before switching the issuer to production, so `PushSecret` copied whatever was in the Secret at the time | Switched to `letsencrypt-production`, then compared `notAfter` and the issuer of the backup against the live Secret until they matched |
| The wildcard certificate was re-issued on a rebuild although the restore was in Git and reported `SecretSynced` | The Application health check read health only. Argo CD excludes not-yet-created resources from an Application's health, so every child read `Healthy` at creation and `root` released all four waves at once; `platform-secrets` and `platform-tls` ran in parallel and cert-manager reconciled the `Certificate` with no Secret present ~48 s before the restore landed | The check now requires `Healthy` **and** `Synced`, rejects an Application reporting no resources, and passes `Degraded` through. Guide steps 2 and 8 carry the same text, checked byte for byte. Unproven until the next rebuild |
| `amtool alert add` printed a parser warning about UTF-8 matchers | The annotation value contains spaces and the shell removed the quotes before `amtool` saw them | Wrap the argument in single quotes: `--annotation='summary="…"'`. Not yet applied to the guide |
