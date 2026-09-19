# App guide — Part 4: Prod, and resources from measurements (steps 20–21)

[← Part 3](3-dev.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 3 is done: dev answers on `http://dev.recruitai.io.vn/`, and Prometheus scrapes it.

**Done when:**
- Prod answers on `http://app.recruitai.io.vn/` with two pods on two different nodes, and survives losing
  either one.
- The pods' requests and limits come from measurements, not guesses.
- Criteria #6, #7 and the "before" of #9 are recorded.

**Every step follows [the loop](../guide.md#the-loop-for-every-step)**, with [the check before
`main`](../guide.md#checking-a-change-before-it-reaches-main).

---

## Step 20 — Prod

**Problem now.** Only dev exists: one pod on one node. If that node is replaced or drained, the app is down.
Prod also must not share dev's session key: today both secrets hold the same `FLASK_SECRET_KEY` (step 8), so
a session cookie signed in dev is accepted by prod.

**Why it matters.** Prod is the environment users rely on. Two pods on two different nodes keep it up
through a node failure. A PodDisruptionBudget (PDB) keeps it up through planned work: `kubectl drain`
evicts a pod only while another one is still available. Prod also must not repeat dev's work: the index
version already exists, so its Job must skip.

**This step.**
- Give prod its own Flask key.
- Add a PDB template that renders only when there is more than one replica.
- Add the prod values file: 2 replicas spread across nodes, the host `app.`, the secret `app-prod`.
- Add the Application `medical-rag-prod` at wave 2, so a rebuild always lets dev (wave 1) build a new index
  first.

**After this step.**
- Works: prod answers on `http://app.recruitai.io.vn/`.
- Proven by:
  - the two pods run on two different nodes;
  - the PDB allows one disruption;
  - prod's Job logs `already exists, skipping build`;
  - `/` answers `200`, and prod's pods pulled the index with the `medical-rag-app-prod` role.
- Still missing: requests and limits are still guesses → step 21.

| File | Change |
|---|---|
| `deploy/charts/medical-rag/templates/pdb.yaml` | New: a PDB, only when replicas > 1 |
| `deploy/envs/prod/values.yaml` | New: prod's image, index version, replicas and name |
| `deploy/argocd/apps/medical-rag-prod.yaml` | New: the Application, wave 2 |

> **Shared state.** Replace prod's Flask key before prod exists, so no prod session is ever signed with
> dev's key. First confirm the two keys are still the same, without printing them:
> ```bash
> umask 077
> aws secretsmanager get-secret-value --secret-id medical-rag/app-dev --query SecretString --output text > /dev/shm/dev.json
> aws secretsmanager get-secret-value --secret-id medical-rag/app-prod --query SecretString --output text > /dev/shm/prod.json
> test "$(jq -r .FLASK_SECRET_KEY /dev/shm/dev.json)" = "$(jq -r .FLASK_SECRET_KEY /dev/shm/prod.json)" && echo SAME
> ```
> Expected: `SAME`. If it prints nothing, you already replaced it: skip the next block, but still run
> `shred -u /dev/shm/dev.json /dev/shm/prod.json; umask 022`.

Put a new random key into prod's secret, keeping its other two keys:
```bash
jq --arg k "$(openssl rand -hex 32)" '.FLASK_SECRET_KEY = $k' /dev/shm/prod.json > /dev/shm/prod-new.json
jq -c 'keys' /dev/shm/prod-new.json
aws secretsmanager put-secret-value --secret-id medical-rag/app-prod --secret-string file:///dev/shm/prod-new.json
shred -u /dev/shm/dev.json /dev/shm/prod.json /dev/shm/prod-new.json
umask 022
```
Expected: `["FLASK_SECRET_KEY","GOOGLE_API_KEY","HUGGINGFACEHUB_API_TOKEN"]`, then JSON with a `VersionId`.
To prove it, run the three lines of the gate again (then `shred` the two files and `umask 022`): no `SAME`.

**Laptop.** Create `deploy/charts/medical-rag/templates/pdb.yaml`:
```yaml
# Keeps one pod running through planned disruptions such as `kubectl drain` (app guide step 20). Rendered
# only with more than one replica: with a single replica, minAvailable 1 would block every drain forever.
{{- if gt (int .Values.replicas) 1 }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: medical-rag
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: medical-rag
      app.kubernetes.io/component: web
{{- end }}
```

Create `deploy/envs/prod/values.yaml`. Use the same tag, digest and version as dev:
```yaml
# prod: what users rely on. Its values change only on purpose, after dev has run the same image and index;
# until Jenkins opens pull requests for it, you edit this file by hand.
environment: prod

image:
  tag: "<12-hex tag>@sha256:<digest>"   # the same as dev

index:
  version: "cc759ae1a093"                # the same as dev: dev's Job built it, prod's finds it

replicas: 2
spreadAcrossNodes: true

ingress:
  host: app.recruitai.io.vn            # app guide step 14
```

Create `deploy/argocd/apps/medical-rag-prod.yaml`:
```yaml
# The app in prod: the same chart with deploy/envs/prod/values.yaml.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: medical-rag-prod
  namespace: argocd
  labels:
    medical-rag/report-failed-sync: "true"
  annotations:
    # After dev (wave 1): on a rebuild, dev's Job builds a new index version first, and prod's finds it.
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  sources:
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      path: deploy/charts/medical-rag
      helm:
        releaseName: medical-rag
        valueFiles:
          - $values/deploy/envs/common.yaml
          - $values/deploy/envs/prod/values.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: medical-rag-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/enforce-version: latest
        # enforce checks Pods only; warn also checks Deployments and Jobs, so a dry run shows a problem.
        pod-security.kubernetes.io/warn: restricted
        pod-security.kubernetes.io/warn-version: latest
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Why:**

- **`DoNotSchedule` spread with `maxSkew: 1`** (set by `spreadAcrossNodes`). Two replicas on three nodes always
  fit on two different nodes. A second replica is never put next to the first "for now", which is what the
  softer `ScheduleAnyway` allows.
- **Rolling update `maxUnavailable: 0`, `maxSurge: 1`** (in the Deployment since step 17). During an update,
  a third pod starts on the third node before an old one stops.
- **The CPU budget.** The nodes' CPU requests were 56–67% used before the app. Dev's pod, prod's two pods and a
  short Job request about 400m in total, which fits: that is why the requests are small.

**Commit** (`git add deploy/charts/medical-rag/templates/pdb.yaml deploy/envs/prod/values.yaml deploy/argocd/apps/medical-rag-prod.yaml`, message `Add prod`). Before the commit, `git status --short` shows exactly:
```
?? deploy/argocd/apps/medical-rag-prod.yaml
?? deploy/charts/medical-rag/templates/pdb.yaml
?? deploy/envs/prod/
```
Push the commit to the temporary branch `app/step-20` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)).

The prod namespace does not exist yet, so check in `default`:
```bash
helm lint deploy/charts/medical-rag -f deploy/envs/common.yaml -f deploy/envs/prod/values.yaml
helm template medical-rag deploy/charts/medical-rag \
  -f deploy/envs/common.yaml -f deploy/envs/prod/values.yaml -n default \
  | kubectl apply --dry-run=server -n default -f -
kubectl apply --dry-run=server -f deploy/argocd/apps/medical-rag-prod.yaml
helm template medical-rag deploy/charts/medical-rag \
  -f deploy/envs/common.yaml -f deploy/envs/dev/values.yaml | grep -c 'kind: PodDisruptionBudget'
```
Expected:
- `1 chart(s) linted, 0 chart(s) failed`;
- twelve lines ending in `(server dry run)`, including `poddisruptionbudget.policy/medical-rag`;
- `application.argoproj.io/medical-rag-prod created (server dry run)`;
- `0`: dev renders no PDB (`grep -c` exits with 1 when it counts 0; that is fine).

Only if every check passed **and** the Shared state box printed what it must: **Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-20`; on the workstation, `git checkout main && git pull`. Then:
```bash
kubectl -n argocd annotate applications.argoproj.io root argocd.argoproj.io/refresh=normal --overwrite
kubectl -n medical-rag-prod wait job/index-build --for=create --timeout=10m
kubectl -n medical-rag-prod wait job/index-build --for=condition=complete --timeout=10m
kubectl -n medical-rag-prod wait deployment/medical-rag --for=create --timeout=10m
kubectl -n medical-rag-prod rollout status deployment/medical-rag --timeout=10m
```
Expected: three `condition met` lines, then `deployment "medical-rag" successfully rolled out`.

**Check:**

1. Prod did not embed again:
   ```bash
   kubectl -n medical-rag-prod logs job/index-build | grep -E 'Built index|already exists'
   ```
   Expected: `Index version cc759ae1a093 already exists, skipping build`.
2. Two pods, two nodes, one disruption allowed:
   ```bash
   kubectl -n medical-rag-prod get pods -l app.kubernetes.io/component=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l
   kubectl -n medical-rag-prod get poddisruptionbudgets.policy medical-rag -o jsonpath='{.status.disruptionsAllowed}{"\n"}'
   ```
   Expected: `2`, then `1`.
3. Prod's pods pulled the index. They could do that only with the `medical-rag-app-prod` role: the node role
   has had no access to the bucket since step 9, and that role's trust policy accepts only the
   `medical-rag-prod` ServiceAccount:
   ```bash
   kubectl -n medical-rag-prod logs deployment/medical-rag -c index-pull | grep 'Pulled index'
   ```
   Expected: `Pulled index cc759ae1a093 (7079 chunks) into /tmp/index`.
4. The public name, and `root`:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://app.recruitai.io.vn/
   curl -s -o /dev/null -w '%{http_code}\n' http://app.recruitai.io.vn/metrics
   kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
   ```
   Expected: `200`, `404`, `Synced Healthy`.

**Record** the four checks, and open `http://app.recruitai.io.vn/` in a browser.

---

## Step 21 — Resources from measurements

**Problem now.** Every request and limit in the chart is a guess: 100m CPU, 768Mi to 1536Mi of memory for
the app, and 512Mi to 2Gi for the Job. The cluster has no metrics-server, so `kubectl top` does not work.

**Why it matters.**
- **A request that is too high** wastes the little CPU the nodes have left.
- **A limit that is too low** gets a pod killed for memory. In the GitOps phase, Grafana answered `502` for
  exactly that reason (most likely) until its limit was raised.
- **The numbers are also the evidence** for criteria #6 and #7, and the CVE list is the "before" of #9.

**This step.**
- Measure with Prometheus, which already scrapes every container's memory and CPU through the kubelet: idle,
  then under a few questions.
- Set requests near the measured working set and limits with headroom.
- Record the evidence.

**After this step.**
- Works: requests and limits based on measurements.
- Proven by: the values in the chart equal the recorded measurements plus the stated headroom, and the pods
  roll to Ready with them.
- Still missing: Jenkins builds images and promotes versions → the next phase.

### 21.1 Measure

With the `promq` helper from step 16. In a new shell, define it again first:
```bash
promq() {
  local q
  q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" \
    | jq -r '.data.result[] | "\(.metric.pod // .metric.namespace) \(.value[1])"'
}
```
First the app at rest, over the last hour:
```bash
promq 'max_over_time(container_memory_working_set_bytes{namespace=~"medical-rag-(dev|prod)",container="app"}[1h])'
promq 'max_over_time(rate(container_cpu_usage_seconds_total{namespace=~"medical-rag-(dev|prod)",container="app"}[5m])[1h:1m])'
```
Expected: one line per pod that ran in the last hour, memory in bytes, CPU in cores. Use the lines of the
current pods (one dev, two prod: `kubectl get pods -A -l app.kubernetes.io/component=web`), and record them.

Then under load. Ask ten questions of dev. This spends ten Gemini and Hugging Face calls:
```bash
for i in $(seq 10); do
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' \
    --data-urlencode "prompt=What causes fever? ($i)" http://dev.recruitai.io.vn/
done
```
Expected: ten lines, each `302` and the seconds it took. Record the times. Wait five minutes, then run the two
queries again with `[15m]` instead of `[1h]`, and record the dev line.

Step 16 already recorded the Job's peak memory.

The CVE list for criterion #9, with the image tag from step 11:
```bash
TAG=1eaa43bf3512                  # your tag from step 11
aws ecr describe-image-scan-findings \
  --repository-name medical-rag \
  --image-id imageTag="$TAG" \
  --query "imageScanFindings.findings[?severity=='CRITICAL'].[name, attributes[?key=='package_name'].value | [0]]" \
  --output text
```
Expected: one line per CRITICAL finding counted in step 11 (four), each a CVE ID and the package it is in. Record them: the Jenkins phase hardens the
base image and measures again.

### 21.2 Set the resources

**From the outputs to the numbers.** Three measurements decide everything:

| Measurement | Where it comes from | Unit in the output |
|---|---|---|
| App memory under load | The dev pod's line of the memory query, run after the ten questions | bytes |
| App CPU under load | The dev pod's line of the CPU query, run after the ten questions | cores (`0.12` = 120m) |
| Job memory peak | Step 16, check 6 | bytes |

These are the dev lines you recorded in 21.1; the lines below only put them in variables, so that nothing
is copied by hand. On the workstation, in the shell where `promq` is defined, run them **within 30 minutes
of the ten questions**. The two queries are the ones from 21.1, reduced to one line for dev
(`max by (namespace)`), over the last 30 minutes:
```bash
APP_MEM=$(promq 'max by (namespace) (max_over_time(container_memory_working_set_bytes{namespace="medical-rag-dev",container="app"}[30m]))' | awk '{print $2}')
APP_CPU=$(promq 'max by (namespace) (max_over_time(rate(container_cpu_usage_seconds_total{namespace="medical-rag-dev",container="app"}[5m])[30m:1m]))' | awk '{print $2}')
JOB_MEM=336347136                 # your Job peak from step 16, in bytes
echo "app memory $APP_MEM bytes, app CPU $APP_CPU cores, Job peak $JOB_MEM bytes"
```
Expected: three numbers, and `APP_MEM` and `APP_CPU` at least as high as the dev lines you recorded under
load in 21.1. A lower number means the ten questions are older than 30 minutes, so the window holds only
idle time: ask them again, then rerun these lines. An empty one usually means `promq` is not defined in
this shell.

Then let Python apply the rules of the table below and print the two blocks to copy:
```bash
python3 - "$APP_MEM" "$APP_CPU" "$JOB_MEM" <<'EOF'
import datetime, math, sys
app_mem, app_cpu, job_mem = (float(x) for x in sys.argv[1:])
mib = lambda b: b / 2**20
up = lambda x, step: int(math.ceil(x / step) * step)
day = datetime.date.today().isoformat()
req_mem = up(mib(app_mem), 64)
lim_mem = max(2 * req_mem, 512)
req_cpu = max(up(app_cpu * 1000, 50), 50)
job_req = up(mib(job_mem), 64)
job_lim = max(up(1.5 * mib(job_mem), 64), 1024)
print(f"""indexBuild:
  resources:
    requests:
      cpu: 100m            # the nodes' CPU requests are already 57-68% used
      memory: {job_req}Mi  # {day}: Job peak {mib(job_mem):.0f}Mi (step 16)
    limits:
      memory: {job_lim}Mi  # {day}: max(1.5 x {mib(job_mem):.0f}Mi, 1Gi)

resources:
  requests:
    cpu: {req_cpu}m        # {day}: {app_cpu:.3f} cores peak under 10 questions
    memory: {req_mem}Mi    # {day}: {mib(app_mem):.0f}Mi peak under 10 questions
  limits:
    memory: {lim_mem}Mi    # {day}: 2 x request, at least 512Mi""")
EOF
```
Expected: two YAML blocks. With the Job peak of 321Mi, for example, the first one reads `memory: 384Mi`
and `memory: 1024Mi`. **Record** the three variables and the printed blocks.

**Laptop.** Copy the printed blocks from the workstation. In `deploy/charts/medical-rag/values.yaml`, replace
the whole `indexBuild:` block and the top-level `resources:` block with them. Leave `indexPull:` as it is. The rules the script
applies:

| Setting | New value |
|---|---|
| `resources.requests.memory` | The highest app working set under load, rounded up to the next 64Mi |
| `resources.limits.memory` | Twice the request, at least 512Mi |
| `resources.requests.cpu` | The highest app CPU under load, rounded up to the next 50m, at least 50m |
| `indexBuild.resources.requests.memory` | The Job's peak from step 16, rounded up to the next 64Mi |
| `indexBuild.resources.limits.memory` | 1.5 times the Job's peak, at least 1Gi: an out-of-memory kill wastes the embedding |

The printed blocks already carry, next to each number, the date and the measurement it came from.

**Commit** (`git add deploy/charts/medical-rag/values.yaml`, message `Set app resources from measurements`). Before the commit, `git status --short` shows exactly:
```
 M deploy/charts/medical-rag/values.yaml
```
Push the commit to the temporary branch `app/step-21` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)).
```bash
helm lint deploy/charts/medical-rag -f deploy/envs/common.yaml -f deploy/envs/prod/values.yaml
helm template medical-rag deploy/charts/medical-rag \
  -f deploy/envs/common.yaml -f deploy/envs/dev/values.yaml -n medical-rag-dev \
  | yq 'select(.kind != null and .kind != "Job")' \
  | kubectl apply --dry-run=server -n medical-rag-dev -f -
helm template medical-rag deploy/charts/medical-rag \
  -f deploy/envs/common.yaml -f deploy/envs/prod/values.yaml -n medical-rag-prod \
  | yq 'select(.kind != null and .kind != "Job")' \
  | kubectl apply --dry-run=server -n medical-rag-prod -f -
```
Expected: `0 chart(s) failed`, then ten lines for dev and eleven for prod ending in `(server dry run)`, and
no `Warning: would violate PodSecurity`. The Job is left out (`yq`): a dry run cannot change a Job that already ran, and Argo CD recreates it on
every sync anyway. For the objects Argo CD already manages, kubectl also warns that they are `missing the
kubectl.kubernetes.io/last-applied-configuration annotation`: expected, because Argo CD applies
server-side. A dry run changes nothing.

**Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-21`; on the workstation, `git checkout main && git pull`. Then refresh both Applications, and wait until the Deployments carry the new
values before waiting for the rollout (otherwise `rollout status` reports the old Deployment as done):
```bash
kubectl -n argocd annotate applications.argoproj.io medical-rag-dev medical-rag-prod argocd.argoproj.io/refresh=normal --overwrite
kubectl -n medical-rag-dev get deployment medical-rag -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
kubectl -n medical-rag-prod get deployment medical-rag -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```
Repeat the two `get` lines until both print the new values, then:
```bash
kubectl -n medical-rag-dev rollout status deployment/medical-rag --timeout=10m
kubectl -n medical-rag-prod rollout status deployment/medical-rag --timeout=10m
```
Expected: two `successfully rolled out`.

**Record** for criteria #6 and #7 in `docs/evidence/app.md`:
- #6: the first build's time and chunk count (step 16), and the skip lines (steps 17 and 20);
- #7: pod creation to Ready (step 17), and the ten answer times above;
- #9 before: the scan counts (step 11) and the four CRITICAL packages.

---

[← Part 3](3-dev.md) · [Index](../guide.md) · [Troubleshooting](troubleshooting.md)
