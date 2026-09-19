# GitOps guide — Part 1: Argo CD: install by hand, then let it manage itself (steps 1–3)

[Index](../guide.md) · [Part 2 →](2-foundation.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** [Terraform guide](../../terraform/guide.md) steps 1–19 and [Ansible guide](../../ansible/guide.md) steps 1–11 done; the Rancher and alertmanager secrets hold values.

**Done when:** step 3 — `argocd` and `root` are `Synced` and `Healthy`, and `make bootstrap` is in the Makefile.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`; from step 3 on, refresh Argo CD with `kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite`; then run the checks. [tmux windows](../guide.md#tmux-windows): 0 for work, 1 for `make tunnel`, 2 for the short port-forward in step 2.

---

## Step 1 — Cluster up, tunnel open, secrets present

**Goal:** a running cluster, kubectl working from the workstation, and the two Rancher secrets filled
in, before anything is installed.

No files in this step.

**Run** on the workstation, window 0:
```bash
make infra
make cluster
```
Open window 1 (`Ctrl-b c`) and start the tunnel there. If window 1 already exists from the Ansible
guide, switch to it with `Ctrl-b 1` instead, stop whatever runs there with `Ctrl-C`, and start the
tunnel again. Leave it running:
```bash
cd ~/Medical-RAG-Chatbot
make tunnel
```
Back to window 0 (`Ctrl-b 0`).

**Check:**
```bash
kubectl get nodes
```
Three nodes, all `Ready`.

```bash
helm version --short
```
`v4.3.0+g…`. Helm was installed on the workstation by cloud-init; it is needed only for the first
Argo CD install.

The secrets the addons read must have a value, or those steps wait forever. This shows only version
labels, never the value:
```bash
aws secretsmanager list-secret-version-ids \
  --secret-id medical-rag/rancher-tls \
  --query 'Versions[].VersionStages'
aws secretsmanager list-secret-version-ids \
  --secret-id medical-rag/rancher \
  --query 'Versions[].VersionStages'
aws secretsmanager list-secret-version-ids \
  --secret-id medical-rag/alertmanager \
  --query 'Versions[].VersionStages'
```
Each prints a list containing `"AWSCURRENT"`. An empty list `[]` means the value was never stored: go
back to [Terraform guide step 17](../../terraform/guide/5-domain-certificate-and-secrets.md#step-17--migrate-dns-and-store-the-keys) for the
two Rancher secrets, or [Terraform guide step 19](../../terraform/guide/7-internal-uis.md#step-19--internal-ui-names-dns-permission-for-cert-manager-two-secrets) for `alertmanager`.

`medical-rag/wildcard-tls` is expected to be **empty** the very first time; [step 8](3-certificates-and-argocd-ui.md#step-8--keep-the-certificate-across-rebuilds) fills it.
That is fine here, because nothing reads it yet: the object that restores from it does not exist until
step 8.2. It is only a problem when the finished repository is deployed to a new account, where the
restore is present from the first sync — [step 8.3](3-certificates-and-argocd-ui.md#83-on-a-fresh-account-seed-the-backup-so-the-restore-cannot-fail)
covers that.

Nothing to commit.

---

## Step 2 — Install Argo CD by hand

**Goal:** understand what `make bootstrap` will do, by doing it once yourself.

Create `deploy/argocd/values/argocd.yaml`:
```yaml
# Values for the argo-cd chart. The same file is used twice: by the first `helm install` (step 2,
# later `make bootstrap`), and by the argocd Application that makes Argo CD manage itself (step 3).
# Keeping one file is what lets that takeover leave the running pods alone.

# Single sign-on is not used; kubectl and the admin account are enough for one operator.
dex:
  enabled: false

# No notification channel exists yet. Disabled rather than running with nothing to send to.
notifications:
  enabled: false

configs:
  cm:
    # Argo CD 1.8 stopped computing the health of Application resources, so by default one wave of
    # Applications does not wait for the previous one. The Lua below puts that back.
    #
    # It has to look at sync as well as health. Argo CD leaves a resource that does not exist yet out
    # of an Application's health total, on purpose - controller/health.go says "Missing resources
    # should not affect parent app health - the OutOfSync status already indicates resources are
    # missing". So an Application that has applied half of its manifests still reports Healthy. On
    # 2026-09-18 a health-only version of this check let root start wave 0 while platform-secrets was
    # still applying: the Certificate was created before the restored Secret, and cert-manager spent
    # one of the five Let's Encrypt issuances allowed that week. status.sync stays OutOfSync until
    # every resource exists, so it is the condition that actually orders the waves.
    #
    # Degraded is passed through, or a child that has failed would report Progressing and root would
    # wait for ever without saying why. An empty resource list is Degraded for the same reason: it
    # means the Application rendered nothing at all - a wrong `path:` - which would otherwise read
    # Healthy and Synced immediately and let root walk through every wave in one second.
    #
    # Two cases still leave root waiting with no explanation: a child that stays Healthy but
    # OutOfSync, and a child that reports Suspended. Neither has come up here.
    resource.customizations.health.argoproj.io_Application: |
      hs = {}
      hs.status = "Progressing"
      hs.message = "waiting for the child Application"

      if obj.status == nil or obj.status.health == nil or obj.status.sync == nil then
        return hs
      end

      if obj.status.health.status == "Degraded" then
        hs.status = "Degraded"
        hs.message = obj.status.health.message or "child Application is Degraded"
        return hs
      end

      if obj.status.health.status == "Healthy" and obj.status.sync.status == "Synced" then
        if obj.status.resources == nil or #obj.status.resources == 0 then
          hs.status = "Degraded"
          hs.message = "child Application reports no resources: check its source path"
          return hs
        end
        hs.status = "Healthy"
        hs.message = obj.status.health.message or "child Application is ready"
      end

      return hs

# Requests reserve room on the 8 GB nodes; limits stop one component from starving the others. These
# are starting points for a small cluster, not measured values.
controller:
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      memory: 1Gi

server:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi

redis:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 128Mi

applicationSet:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
```

> **Extended later.** App guide step 15 adds one rule to this check: a child Application labelled
> `medical-rag/report-failed-sync: "true"` reports a failed last sync as `Degraded`, so a failed index
> build shows on `root`. The repository's `values/argocd.yaml` carries that version; this page shows the
> check as it was built in this phase.

**Why:**

- **Helm, not `kubectl apply` of the upstream manifest.** The chart takes a values file, and Argo CD
  can later install the exact same chart with the exact same file. That is what lets Argo CD take over
  its own installation without changing anything.
- **The health check.** Every later step depends on waves waiting for each other, and when it does
  not work the failure is silent: everything starts at once, and Applications fail and retry until
  their dependencies happen to be ready.
- **Why it checks `sync` and not only `health`.** This is the part that does the work. Argo CD leaves
  a resource that does not exist yet out of an Application's health total, deliberately, because
  `OutOfSync` already says the resource is missing. So an Application halfway through applying its
  manifests still reports `Healthy`. `status.sync` stays `OutOfSync` until every resource exists,
  which is why it, not health, is what orders the waves. A version of this check that read health
  alone is what let the certificate restore in
  [step 8](3-certificates-and-argocd-ui.md#step-8--keep-the-certificate-across-rebuilds) lose its
  race and spend a Let's Encrypt issuance. With the check as written here, the rebuild of 2026-09-19 created
  the restored Secret 3 seconds before the Certificate and ordered nothing — see
  [the evidence](../../evidence/gitops.md).

**Commit and push** (the loop, message `Add the Argo CD values`), then `git pull` on the workstation.

**Run** on the workstation, one line at a time:
```bash
helm repo add argo https://argoproj.github.io/argo-helm      # where the chart comes from
helm repo update argo                                        # fetch its current index
helm show chart argo/argo-cd --version 10.9.2                # the version exists
```
The last command prints `version: 10.9.2` and `appVersion: v3.5.3`.

```bash
kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 10.9.2 \
  --values deploy/argocd/values/argocd.yaml
```
`STATUS: deployed`. Helm returns before the pods are ready, so wait for them:
```bash
kubectl -n argocd rollout status deployment/argocd-server --timeout=5m
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m
kubectl -n argocd get pods
```
Every pod `Running` and `READY 1/1`. No `dex` and no `notifications` pod.

**Check** that the API server answers. Open window 2 (`Ctrl-b c`) and start a port-forward:
```bash
kubectl -n argocd port-forward service/argocd-server 8080:443
```
In window 0 (`Ctrl-b 0`):
```bash
curl -sk https://127.0.0.1:8080/healthz
```
Prints `ok`. Go back to window 2, stop the port-forward with `Ctrl-C`, and close the window with `exit`.

This is the only time the Argo CD server is contacted through a port-forward; [step 9](3-certificates-and-argocd-ui.md#step-9--the-argo-cd-ui-through-the-vpn) gives its UI an
internal name.

---

## Step 3 — The root Application, and Argo CD managing itself

**Goal:** Argo CD reads `deploy/argocd/apps/` from Git, and its own installation is one of the files
in there.

Create `deploy/argocd/root.yaml`:
```yaml
# The app-of-apps. Its only job is to create one Application for each file in deploy/argocd/apps/.
# It is applied once, by `make bootstrap`; everything else arrives by committing a file.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  # No resources-finalizer on purpose. With one, deleting `root` would also delete every child
  # Application, and with them whatever those Applications cascade-delete. Without it, deleting
  # `root` deletes only `root`.
spec:
  project: default
  source:
    # The repository is public, so Argo CD reads it without any credential.
    repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
    targetRevision: main
    path: deploy/argocd/apps
  destination:
    server: https://kubernetes.default.svc   # this cluster
    namespace: argocd                        # Application resources live next to Argo CD
  syncPolicy:
    automated:
      prune: true      # a file removed from apps/ removes its Application
      selfHeal: true   # an Application edited by hand is put back to what Git says
```

Create `deploy/argocd/apps/argocd.yaml`:
```yaml
# Argo CD managing its own chart. Same chart, same version, same values file as the first install,
# so adopting the running installation changes only Argo CD's tracking annotation. To upgrade Argo CD
# later, change targetRevision here and push; `make bootstrap` also reads the version from this line.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations:
    # The foundation starts first. Waves run from the lowest number up.
    argocd.argoproj.io/sync-wave: "-3"
  # No resources-finalizer: deleting this Application must never uninstall Argo CD.
spec:
  project: default
  # Two sources: the chart from its Helm repository, and the values file from this Git repository.
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 10.9.2
      helm:
        releaseName: argocd   # the name used by `helm install`; resource names depend on it
        valueFiles:
          - $values/deploy/argocd/values/argocd.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values   # makes `$values` above mean "the root of this repository"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      # Not pruned automatically: a mistake in this chart's values could otherwise delete the
      # controller that is running the sync. Removals here are applied by hand, after a look.
      prune: false
      selfHeal: true
    syncOptions:
      # The Argo CD CRDs are too large for a client-side apply, which stores the whole object in an
      # annotation limited to 262 KB. Server-side apply has no such annotation.
      - ServerSideApply=true
```

**Why:**

- **`root` has no finalizer, `argocd` has no finalizer.** A finalizer turns "delete this Application"
  into "delete everything it installed". That is what you want for an addon during teardown ([step 12](5-teardown-and-rebuild.md#step-12--make-down)),
  and never what you want for Argo CD itself or for the parent of everything.
- **`ServerSideApply=true`.** Large CRDs fail a client-side apply with `metadata.annotations: Too long`.
  Every Application below uses it, so the rule is simple. `root` does not need it: it applies only
  small Application objects.

**Commit and push** (message `Add the root Application`), `git pull` on the workstation.

**Run:**
```bash
kubectl apply -f deploy/argocd/root.yaml
```

**Check:**
```bash
kubectl -n argocd get applications
```
Within a minute or two:
```
NAME     SYNC STATUS   HEALTH STATUS
argocd   Synced        Healthy
root     Synced        Healthy
```
`argocd` may show `OutOfSync` briefly first. Argo CD marks what it manages with an annotation, and the
objects Helm created do not have it yet; the first automatic sync adds it. Prove that this was all it
changed: the pods were not restarted.
```bash
kubectl -n argocd get pods
```
The `AGE` column still counts from the `helm install` in step 2.

**Now the make target.** You have just done by hand everything `make bootstrap` needs to do on a fresh
cluster. Add to the `Makefile`. **Recipe lines start with a tab, not spaces**; spaces give
`missing separator`.
```makefile
# --- GitOps: Argo CD, then everything Argo CD installs from deploy/argocd/ ----------------------
ARGOCD_APP     := deploy/argocd/apps/argocd.yaml
ARGOCD_VALUES  := deploy/argocd/values/argocd.yaml
# The chart version is written once, in the Application Argo CD uses to manage itself. Reading it
# here means the first install and the self-managed one can never disagree.
ARGOCD_VERSION  = $(shell yq '.spec.sources[0].targetRevision' $(ARGOCD_APP))

.PHONY: bootstrap apps

# Install Argo CD and hand it the root Application. Needs `make tunnel` open in another window.
# Safe to run again: the helm step is skipped once Argo CD manages itself.
bootstrap:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	@# Only the first bootstrap installs the chart. Once the argocd Application exists, Argo CD owns
	@# these objects through server-side apply, and a second `helm upgrade` fails on field conflicts.
	@if kubectl -n argocd get application argocd >/dev/null 2>&1; then \
	  echo "Argo CD already manages itself; skipping helm and applying root.yaml only"; \
	else \
	  helm upgrade --install argocd argo/argo-cd \
	    --namespace argocd --create-namespace \
	    --version $(ARGOCD_VERSION) \
	    --values $(ARGOCD_VALUES) \
	    --wait --timeout 10m; \
	fi
	kubectl apply -f deploy/argocd/root.yaml

# Sync and health of everything Argo CD manages.
apps:
	kubectl -n argocd get applications
```

**Commit** on the laptop, then `git pull` on the workstation:
```bash
git add Makefile
git commit -m "Add make bootstrap"
git push
```

**Check the target** without changing anything:
```bash
make -n bootstrap
```
`-n` prints the commands instead of running them. The `helm upgrade` line must contain
`--version 10.9.2`. Then run it for real:
```bash
make bootstrap
make apps
```
It prints `Argo CD already manages itself; skipping helm and applying root.yaml only`, and both
`argocd` and `root` stay `Synced` and `Healthy`.

**Why the target skips Helm here.** On a fresh cluster the first `make bootstrap` installs the chart.
After the takeover, Argo CD owns those objects with server-side apply under its own field manager, and
Helm 4 also applies server-side: a second `helm upgrade` then fails with
`Apply failed with 1 conflict: conflict with "argocd-controller"`. Nothing is broken when that happens;
the cluster still runs the same Argo CD. From here on, Argo CD is changed through Git, and
`make bootstrap` is for rebuilds.

---

[Index](../guide.md) · [Part 2 →](2-foundation.md) · [Troubleshooting](troubleshooting.md)
