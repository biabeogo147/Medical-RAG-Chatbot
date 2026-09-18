# GitOps guide — Part 5: Teardown, rebuild and evidence (steps 12–13)

[← Part 4](4-monitoring-and-rancher.md) · [Index](../guide.md) · [Next: runbook →](../../runbook.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 4 done.

**Done when:** steps 12–13 — after a rebuild every Application is `Synced` and `Healthy`, no new certificate request exists, `make down` leaves no CSI volume, and the evidence is committed.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`, then refresh Argo CD with `kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite` and run the checks. [tmux windows](../guide.md#tmux-windows): 0 for work, 1 for `make tunnel`.

---

## Step 12 — `make down`

**Goal:** destroying the cluster leaves no EBS volume behind.

`make infra-destroy` alone would terminate the nodes and leave Prometheus's volume in EC2, still
billed, and unknown to Terraform. Do the teardown by hand once to see each part, then turn it into a
target.

**Run by hand** in window 0 (the tunnel must be open in window 1).

Stop `root` from putting Applications back:
```bash
kubectl -n argocd patch application root \
  --type merge \
  --patch '{"spec":{"syncPolicy":{"automated":null}}}'
```
`application.argoproj.io/root patched`.

See which Applications own volumes (the `medical-rag/volumes` label set in [step 10](4-monitoring-and-rancher.md#step-10--monitoring-the-whole-cluster-alert-email-three-uis)), then delete them:
```bash
kubectl -n argocd get applications --selector medical-rag/volumes=true
kubectl -n argocd delete applications --selector medical-rag/volumes=true --timeout=10m
```
`kube-prometheus-stack` is listed, then deleted. The command returns only after Argo CD has removed what
the Application installed, because of its finalizer.

A StatefulSet leaves its PVCs behind when deleted. Delete them:
```bash
kubectl get pvc --all-namespaces
kubectl delete pvc --all --all-namespaces --timeout=15m
```

Wait until the PersistentVolumes are gone; each one disappears only after its EBS volume is deleted:
```bash
kubectl get pv
```
Repeat until `No resources found`. Then confirm on the AWS side:
```bash
aws ec2 describe-volumes \
  --filters Name=tag:project,Values=medical-rag Name=tag-key,Values=ebs.csi.aws.com/cluster \
  --query 'length(Volumes)'
```
`0`. Only now:
```bash
make infra-destroy
```
Terraform shows the plan and waits for you to type `yes`; `make down` below does the same at the end.

**Now the target.** Add to the `Makefile`, and add `down` to the `.PHONY` line of the GitOps block from [step 3](1-argocd.md#step-3--the-root-application-and-argo-cd-managing-itself).
Recipe lines start with a tab.
```makefile
# The CSI volumes that still exist. Terraform does not know them, so they are found by the tags the
# driver adds (ebs.csi.aws.com/cluster) and the one from values/aws-ebs-csi-driver.yaml (project).
CSI_VOLUMES = aws ec2 describe-volumes --region $(REGION) --query 'length(Volumes)' --output text \
  --filters Name=tag:project,Values=$(PROJECT) Name=tag-key,Values=ebs.csi.aws.com/cluster

# Release the EBS volumes the cluster created, then destroy the cluster stack. Needs `make tunnel`.
# The order matters: the CSI driver must still be running while the volumes are deleted.
down: init
	@# The leading "-" lets make continue when root does not exist, e.g. after a failed bootstrap.
	-kubectl -n argocd patch application root --type merge --patch '{"spec":{"syncPolicy":{"automated":null}}}'
	kubectl -n argocd delete applications --selector medical-rag/volumes=true --timeout=10m
	kubectl delete pvc --all --all-namespaces --timeout=15m
	@for i in $$(seq 30); do \
	  n=$$($(CSI_VOLUMES)) || exit 1; \
	  test "$$n" = 0 && break; \
	  echo "$$n EBS volume(s) still exist, waiting"; \
	  sleep 10; \
	done
	@test "$$($(CSI_VOLUMES))" = 0 || { echo "EBS volumes remain; not destroying the cluster"; exit 1; }
	$(MAKE) infra-destroy
```

**Why:**

- **The gate asks AWS, not the cluster.** An empty answer from kubectl can also mean the tunnel just
  dropped. `aws ec2 describe-volumes` either returns a number or fails, and `|| exit 1` stops `make` on
  a failure. The last `test` stops `make` if a volume is still there after five minutes, so the cluster
  is never destroyed while it still owns one.
- **Deleting the PVCs, not the Applications, releases the volumes.** A StatefulSet keeps its PVCs, and
  with `reclaimPolicy: Delete` the driver deletes the EBS volume only when its PVC is gone.
- **`$$` in a Makefile** is a plain `$` for the shell; a single `$` would be read by make itself. A `\`
  at the end of a recipe line continues the same shell command on the next line.

**Commit and push** (message `Add make down`, with `git add Makefile`), then `git pull` on the
workstation. **Check** that the target is what you expect without running it:
```bash
make -n down
```
The printed commands match the ones you ran by hand above. The target itself runs in step 13, where it is
also timed.

---

## Step 13 — Rebuild from nothing, and the evidence

**Goal:** prove the whole platform comes back from Git alone, and measure how long it takes.

Start from a destroyed cluster (step 12 left it that way). Window 0:
```bash
time make infra
time make cluster
```
Window 1:
```bash
make tunnel
```
Window 0:
```bash
time make bootstrap
```
`make bootstrap` returns once Argo CD itself is running. The rest installs in waves; time that part
separately:
```bash
time kubectl -n argocd wait application/root \
  --for=jsonpath='{.status.health.status}'=Healthy \
  --timeout=30m
```
This waits on `root` alone, and that is enough: right after `make bootstrap` the child Applications do
not exist yet, and `root` turns `Healthy` only when every one of them is, thanks to the health check in
`values/argocd.yaml`.

**Check:**
```bash
make apps
```
```
NAME                    SYNC STATUS   HEALTH STATUS
argocd                  Synced        Healthy
aws-ebs-csi-driver      Synced        Healthy
cert-manager            Synced        Healthy
external-secrets        Synced        Healthy
ingress-nginx           Synced        Healthy
kube-prometheus-stack   Synced        Healthy
platform-secrets        Synced        Healthy
platform-tls            Synced        Healthy
rancher                 Synced        Healthy
root                    Synced        Healthy
```

**The certificate came back instead of being ordered again:**
```bash
kubectl -n ingress-nginx get certificate wildcard-recruitai
kubectl -n ingress-nginx get certificaterequests
```
The certificate `READY True`, and `No resources found` for certificate requests: cert-manager found the
restored certificate valid and asked Let's Encrypt for nothing. Its expiry is the `notAfter` date you wrote
down in [step 7](3-certificates-and-argocd-ui.md#step-7--cert-manager-and-the-wildcard-certificate); run that step's `openssl x509` check to compare.

Repeat the checks of steps 9, 10 and 11. On the laptop, deactivate and activate the tunnel first: a
rebuild gives the gateway a new public address.

Then tear it down, timed:
```bash
time make down
```

**Record** in `docs/evidence/gitops.md`:

- the `real` times of `make infra`, `make cluster`, `make bootstrap`, the wait for `root`, and
  `make down`
- the `make apps` table above, and a screenshot of the Argo CD Applications page (criterion #5)
- the `certificaterequests` result `No resources found` after the rebuild
- from [step 11](4-monitoring-and-rancher.md#step-11--rancher) (criterion #4): the security group query `[]`, the `308` line, `Verification: OK` from
  the gateway, the timeout without VPN, the WireGuard handshake time, `pong` with VPN, the two
  `Test-NetConnection` results, and that the Rancher UI loaded
- from [step 9](3-certificates-and-argocd-ui.md#step-9--the-argo-cd-ui-through-the-vpn): the Argo CD timeout without VPN and `200` with it
- from [step 10](4-monitoring-and-rancher.md#step-10--monitoring-the-whole-cluster-alert-email-three-uis): the Prometheus target list including etcd, the `amtool alert query` output, the test
  alert email (a screenshot with the address blurred), and a screenshot of the Grafana etcd dashboard
- the last line `make down` printed before `infra-destroy`, and `Destroy complete!`

**Commit** on the laptop:
```bash
git add docs/evidence/gitops.md
git commit -m "docs: record the GitOps phase evidence"
git push
```

**End of the session:** stop the workstation (EC2 → Instances → Instance state → Stop).

---

[← Part 4](4-monitoring-and-rancher.md) · [Index](../guide.md) · [Next: runbook →](../../runbook.md) · [Troubleshooting](troubleshooting.md)
