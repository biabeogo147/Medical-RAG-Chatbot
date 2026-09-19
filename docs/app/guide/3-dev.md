# App guide — Part 3: The chart, deployed to dev (steps 14–19)

[← Part 2](2-image-and-index.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Next: Part 4 →](4-prod-and-measure.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Parts 1 and 2 are done. Step 7 passed: a pod gets its own role through its token,
and IMDS can be closed. ECR holds the image from step 11. The corpus is in S3. `faiss/` in S3 is still
empty.

**Done when:** `http://dev.recruitai.io.vn/` answers a medical question. The index was built once, in the
cluster, by a Job with its own role, and later syncs skip the build. The app container holds no AWS
credentials, and IMDS is closed to it. Prometheus scrapes the app.

**Every step follows [the loop](../guide.md#the-loop-for-every-step).** From step 15 on, a change is
checked on a temporary branch before it reaches `main`: [checking before `main`](../guide.md#checking-a-change-before-it-reaches-main).

---

New ideas in this part (Helm chart, values file, sync wave, hook, Pod Security, Ingress) are explained in
[concepts §16–§19](0-concepts.md#16-helm-charts-and-values-files).

**What this part builds.** One Helm chart, `deploy/charts/medical-rag`, that Argo CD installs once per
environment. Each environment has its own values file (`deploy/envs/dev/values.yaml`, later
`prod/values.yaml`). The chart grows one piece per step, so each step has one thing to prove:

| Step | Adds | Proves |
|---|---|---|
| 14 | Two DNS names | `dev.` and `app.recruitai.io.vn` reach ingress-nginx |
| 15 | One rule in Argo CD's health check | A failed sync of the app is visible on `root` |
| 16 | ServiceAccounts, the Secret, the network rules, the index build Job | The Job waits for the Secret, uses its own role, and builds the index once |
| 17 | The Deployment and its Service | Pods pull the pinned index; the app container has no AWS credentials; a failed build keeps the old pods serving |
| 18 | The Ingress | The app answers on its name; `/metrics` is not public |
| 19 | The ServiceMonitor | Prometheus scrapes the app |

**The order inside one sync** ([concepts §17](0-concepts.md#17-sync-waves-and-hooks)):

| Wave | Objects | Why here |
|---|---|---|
| 0 | ServiceAccounts, ExternalSecret, NetworkPolicies | Everything the Job needs must exist first |
| 1 | The index build Job (a Sync hook) | The index must exist before a pod asks for it |
| 2 | Deployment, Service, Ingress, ServiceMonitor, PDB | Pods start only once their index version is in S3 |

---

## Step 14 — Public names for the app

**Problem now.** The public load balancer has only its AWS name,
`medical-rag-ingress-….elb.ap-southeast-1.amazonaws.com`. ingress-nginx sends a request to an app by the
name in the request (the `Host` header), so each environment needs its own name.

**Why it matters.** With one name per environment, dev and prod never share a URL prefix or a session
cookie, and the app needs no code for serving under `/dev`. The names must exist before the Ingress in step
18 can be tested.

**This step.** Two alias records in Route 53, `dev.recruitai.io.vn` and `app.recruitai.io.vn`, both pointing
at the public load balancer, the same pattern as the internal UI names.

**After this step.**
- Works: both names resolve to the public load balancer.
- Proven by: `getent` returns the load balancer's addresses for `dev.`, and `curl` gets nginx's `404`.
- Still missing: nothing in the cluster answers for these names yet, and the Argo CD health check would not
  notice a failed app sync → step 15.

| File | Change |
|---|---|
| `infra/terraform/cluster/app-dns.tf` | New file: two alias records and their URLs as an output |

**Laptop.** Create `infra/terraform/cluster/app-dns.tf`:
```hcl
# Public names for the app, one per environment (app guide step 14). Like the internal UI names
# (internal-ui.tf), each is an alias record, but these point at the public load balancer, which listens on
# port 80 only. ingress-nginx routes by name: dev.<domain> to medical-rag-dev, app.<domain> to prod.

variable "app_hosts" {
  description = "First labels of the app's public names; each becomes <label>.<domain>."
  type        = set(string)
  default     = ["dev", "app"]
}

resource "aws_route53_record" "app" {
  for_each = var.app_hosts

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.ingress.dns_name
    zone_id                = aws_lb.ingress.zone_id
    evaluate_target_health = false
  }
}

output "app_urls" {
  description = "The app's public URLs, plain HTTP"
  value       = [for r in aws_route53_record.app : "http://${r.name}"]
}
```

**Why:**

- **Alias records, not CNAMEs.** An alias answers with the load balancer's current addresses, costs nothing
  per query, and follows the load balancer if AWS changes its addresses.
- **In the cluster stack.** The load balancer is destroyed with the cluster, so the records that point at it
  are too.
- **Do not look the names up until `make infra` has finished.** A resolver that is told "no such name"
  remembers that answer for a while (negative caching), and the check below would then fail even after the
  records exist. The gate below asks the Route 53 API instead, which is not cached.

**Check before:** `git status --short` shows only `?? infra/terraform/cluster/app-dns.tf`.

> **Shared state.** The records go into the project's public hosted zone. Confirm that neither name exists
> yet, so nothing is overwritten:
> ```bash
> ZONE=$(aws route53 list-hosted-zones-by-name --dns-name recruitai.io.vn --query 'HostedZones[0].Id' --output text)
> aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
>   --query "ResourceRecordSets[?Name=='dev.recruitai.io.vn.' || Name=='app.recruitai.io.vn.'].Name"
> ```
> Expected: `[]`. Anything else: **stop**.

**Commit and push** (`git add infra/terraform/cluster/app-dns.tf`, message `Add public names for the app`),
`git pull` on the workstation, then:
```bash
make infra
```
Expect **2 to add, 0 to change, 0 to destroy**, and `app_urls` among the outputs. Then type `yes`. Anything
else: type `no` and stop.

**Check:** the name resolves to the same addresses as the load balancer:
```bash
NLB=$(terraform -chdir=infra/terraform/cluster output -raw public_nlb_dns)
getent ahostsv4 "$NLB" | awk '{print $1}' | sort -u
getent ahostsv4 dev.recruitai.io.vn | awk '{print $1}' | sort -u
getent ahostsv4 app.recruitai.io.vn | awk '{print $1}' | sort -u
curl -s -o /dev/null -w '%{http_code}\n' http://dev.recruitai.io.vn/
```
Expected: the three address lists are identical, and `curl` prints `404`: nginx answers, but no Ingress claims
that name yet. New baseline: 90 managed resources in `cluster`.

**Record** the addresses and the `404`.

---

## Step 15 — Let `root` see a failed app sync

**Problem now.** The app's index build will run as an Argo CD *hook* ([concepts §17](0-concepts.md#17-sync-waves-and-hooks)).
Argo CD leaves hooks out of an Application's health. If the Job fails, the sync is marked `Failed`, but the
Application still *shows* `Healthy`. `root` then shows `Healthy` too, or waits forever without saying
why. Automated sync retries a failed sync only a few times (below), then never again for the same commit,
so nothing fixes itself.

**Why it matters.** A failed index build must be visible where you look first, on `root`, with the reason.
Otherwise a broken release looks like a healthy cluster.

**This step.** One more rule in the health check Argo CD uses for child Applications
(`deploy/argocd/values/argocd.yaml`). If a child carries the label `medical-rag/report-failed-sync: "true"`
and its last sync `Failed`, report it as `Degraded`, with the sync's message. Only the app's Applications
will carry the label, so the platform is judged exactly as before.

**After this step.**
- Works: Argo CD runs the new check.
- Proven by: `argocd-cm` contains the new rule, and `root` is still `Synced Healthy`. The `Degraded` path is
  proven on purpose in step 17.
- Still missing: there is no chart → step 16.

| File | Change |
|---|---|
| `deploy/argocd/values/argocd.yaml` | Four comment lines and one `if` block in the Application health check |

> **Shared state.** This changes how Argo CD judges every child Application. First confirm that no
> Application has a failed last sync, which the new rule could turn into a surprise:
> ```bash
> kubectl -n argocd get applications.argoproj.io -o json \
>   | jq -r '.items[] | "\(.metadata.name) \(.status.operationState.phase)"'
> ```
> Expected: every line ends in `Succeeded`. Only labelled Applications are affected, and none exists yet,
> so this is a second safety net. Anything else: **stop**.

**From this step on, a push to `main` is a deploy.** This is the first step that is checked on a temporary
branch before it reaches `main`: read the four items of [checking a change before it reaches
main](../guide.md#checking-a-change-before-it-reaches-main) now; every later step uses them.

**Laptop.** In `deploy/argocd/values/argocd.yaml`, find the comment that begins `# Two cases still leave
root waiting` (two lines, ending `Neither has come up here.`). Add these lines after it, before
`resource.customizations…`, at the same indentation:
```yaml
    #
    # A failed sync is a third case: Argo CD leaves hooks out of health, so a failed hook (the app's index
    # build Job) leaves the child Healthy. Children labelled medical-rag/report-failed-sync=true report a
    # failed last sync as Degraded instead (app guide step 15). The platform's children carry no label.
```
In the same file, inside the Lua, add this block directly after the first `end` (the one that closes the
`if obj.status == nil …` check), with a blank line before and after it:
```yaml
      if obj.metadata.labels ~= nil and obj.metadata.labels["medical-rag/report-failed-sync"] == "true" then
        local op = obj.status.operationState
        if op ~= nil and (op.phase == "Failed" or op.phase == "Error") then
          hs.status = "Degraded"
          hs.message = op.message or "the last sync of the child Application failed"
          return hs
        end
      end
```
The Lua lines are indented by six spaces, like the rest of the check.

**Why:**

- **Only labelled children.** A platform child whose first sync fails during a rebuild would otherwise turn
  `root` `Degraded` in the middle of bootstrap, and that path has never been exercised. Only the app's
  Applications carry the label. The platform's Applications are judged exactly as they were on 2026-09-19.
- **`operationState` is the last sync, not the current one.** The next successful sync replaces it. But when
  a fix makes the rendered objects equal the live ones again (a revert, for example), the app is already
  `Synced` and automated sync does not run: start one sync by hand (step 17 shows how).
- **Retries come first, so `Degraded` comes late.** When an Application has no `syncPolicy.retry`, Argo CD
  gives each automated sync `retry: {limit: 5}` itself (`controller/appcontroller.go`), waiting 5 s, then 10,
  20, 40 and 80 s between attempts. Each attempt runs the hook Job again. During the retries the phase is
  `Running`, which the rule above does not match, and `root` reads `Progressing` because the child is still
  `OutOfSync`. Only after the fifth failed retry is the phase `Failed`, and `root` `Degraded`. The waits
  alone add 155 s, so for a Job that fails in seconds this takes a few minutes. The default is kept: a
  retry gets past a short outage, such as a webhook that is not ready yet.
- **The GitOps guide's copy of this check stays as it was.** It shows the check as it was built in that
  phase; this step extends it.

**Commit** (`git add deploy/argocd/values/argocd.yaml`, message `Report a failed app sync on root`). Before the commit, `git status --short` shows exactly:
```
 M deploy/argocd/values/argocd.yaml
```
Push the commit to the temporary branch `app/step-15` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)).
```bash
yq '.configs.cm."resource.customizations.health.argoproj.io_Application"' deploy/argocd/values/argocd.yaml \
  | grep -c 'report-failed-sync'
```
Expected: `1`. `yq` parses the file, so a broken indentation fails here instead of in Argo CD.

**Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-15`; on the workstation, `git checkout main && git pull`. Argo CD applies its own values within a few minutes; to hurry it:
```bash
kubectl -n argocd annotate applications.argoproj.io argocd argocd.argoproj.io/refresh=normal --overwrite
```

**Check:**
```bash
kubectl -n argocd get configmap argocd-cm \
  -o jsonpath='{.data.resource\.customizations\.health\.argoproj\.io_Application}' \
  | grep -c 'report-failed-sync'
kubectl -n argocd get applications.argoproj.io root \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```
Expected: `1`, then `Synced Healthy`.

**Record** the `1` and `Synced Healthy`.

---

## Step 16 — The chart, and the index built in the cluster

**Problem now.** Nothing in the cluster can build the index: there is no chart, no namespace for the app,
no Secret with its API keys, and `faiss/` in S3 is empty. Part 1 proved the pieces by hand; now they have to
be written down as code that Argo CD applies.

**Why it matters.** This is the first time the design runs for real. The Job must wait for its Secret, use
its own role and not the node's ([concepts §9](0-concepts.md#9-sts-assumerolewithwebidentity-the-exchange)),
and build exactly the pinned version ([concepts §15](0-concepts.md#15-the-index-version)). The first build
calls the Hugging Face API for 7,079 chunks, so it should happen once.

**This step.** The first version of the chart:

- two ServiceAccounts;
- an ExternalSecret that copies `medical-rag/app-dev` into the Secret `app-secrets`;
- a NetworkPolicy that closes IMDS and every incoming connection;
- the index build Job, as a Sync hook at wave 1.

Plus the dev values file, and the Application `medical-rag-dev`. Argo CD creates the namespace with the
Pod Security level `restricted` ([concepts §18](0-concepts.md#18-pod-security-standards)).

**After this step.**
- Works: the index version `cc759ae1a093` exists in S3, built in the cluster.
- Proven by:
  - the Secret existed before the Job's pod;
  - the Job's log says `Built index cc759ae1a093: 759 pages, 7079 chunks`;
  - S3 holds three objects under `faiss/cc759ae1a093/` and no `faiss/LATEST`;
  - `medical-rag-dev` is `Synced Healthy Succeeded`;
  - ten minutes later, the Job has not run again.
- Still missing: no pod serves the app → step 17.

| File | Change |
|---|---|
| `deploy/charts/medical-rag/Chart.yaml` | New: the chart's name and version |
| `deploy/charts/medical-rag/values.yaml` | New: defaults for both environments |
| `deploy/charts/medical-rag/templates/_helpers.tpl` | New: names and snippets used by several templates |
| `deploy/charts/medical-rag/templates/serviceaccounts.yaml` | New: `medical-rag` and `medical-rag-index-builder` |
| `deploy/charts/medical-rag/templates/externalsecret.yaml` | New: `medical-rag/app-<env>` → Secret `app-secrets` |
| `deploy/charts/medical-rag/templates/networkpolicy.yaml` | New: no incoming traffic; outgoing only DNS and 443, never IMDS |
| `deploy/charts/medical-rag/templates/index-job.yaml` | New: the index build, a Sync hook |
| `deploy/envs/common.yaml` | New: settings both environments share |
| `deploy/envs/dev/values.yaml` | New: dev's image, index version and name |
| `deploy/argocd/apps/medical-rag-dev.yaml` | New: the Application, wave 1 |

**Laptop.** Create `deploy/charts/medical-rag/Chart.yaml`:
```yaml
# The medical RAG chatbot: its index build Job, its pods, and what they need in one namespace.
# Installed by Argo CD once per environment (deploy/argocd/apps/medical-rag-<env>.yaml), with that
# environment's values file (deploy/envs/<env>/values.yaml).
apiVersion: v2
name: medical-rag
description: Medical RAG chatbot with a versioned FAISS index
type: application
version: 0.1.0
```

Create `deploy/charts/medical-rag/values.yaml`:
```yaml
# Defaults for both environments. deploy/envs/common.yaml and deploy/envs/<env>/values.yaml set the rest;
# a value marked "required" has no default here, and rendering fails without it.

environment: ""            # required: dev or prod. Picks medical-rag/app-<environment> and the app role.

aws:
  accountId: ""            # required: the account that owns the roles, the registry and the buckets
  region: ap-southeast-1

image:
  tag: ""                  # required: "<12-hex commit>@sha256:<digest>", from make image (app guide step 11)

index:
  version: ""              # required: the version the Job must build and the pods pull (app guide step 12)

# The index build Job. Its first run embeds 7,079 chunks through the Hugging Face API; later runs find
# the version in S3 and stop within seconds.
indexBuild:
  resources:
    requests:
      cpu: 100m            # the nodes' CPU requests are already 56-67% used
      memory: 512Mi
    limits:
      memory: 2Gi          # an out-of-memory kill would waste the embedding calls; measured in step 21
```

Create `deploy/charts/medical-rag/templates/_helpers.tpl`:
```yaml
{{/*
Values and snippets shared by several templates.
*/}}

{{/* The image: registry and repository from the account, tag and digest from the values file. */}}
{{- define "medical-rag.image" -}}
{{ required "aws.accountId is required" .Values.aws.accountId }}.dkr.ecr.{{ .Values.aws.region }}.amazonaws.com/medical-rag:{{ required "image.tag is required" .Values.image.tag }}
{{- end }}

{{/* Where the corpus and the index versions live (infra/terraform/shared/storage.tf). */}}
{{- define "medical-rag.bucket" -}}
s3://medical-rag-artifacts-{{ .Values.aws.accountId }}
{{- end }}

{{- define "medical-rag.labels" -}}
app.kubernetes.io/name: medical-rag
app.kubernetes.io/instance: {{ .Release.Name }}
medical-rag/environment: {{ required "environment is required" .Values.environment }}
{{- end }}

{{/*
The pod side of the app's AWS identity: the same four variables and token volume as the proof pod of
app guide step 7. Call it with a dict: (dict "role" "<role name>" "Values" .Values).
*/}}
{{- define "medical-rag.awsEnv" -}}
- name: AWS_ROLE_ARN
  value: arn:aws:iam::{{ .Values.aws.accountId }}:role/{{ .role }}
- name: AWS_WEB_IDENTITY_TOKEN_FILE
  value: /var/run/secrets/aws/token
- name: AWS_REGION
  value: {{ .Values.aws.region }}
- name: AWS_STS_REGIONAL_ENDPOINTS
  value: regional
{{- end }}

{{- define "medical-rag.awsTokenVolume" -}}
- name: aws-token
  projected:
    sources:
      - serviceAccountToken:
          audience: sts.amazonaws.com
          expirationSeconds: 3600
          path: token
{{- end }}

{{/* Pod and container security settings that pass the Pod Security level "restricted". */}}
{{- define "medical-rag.podSecurity" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "medical-rag.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
```

Create `deploy/charts/medical-rag/templates/serviceaccounts.yaml`:
```yaml
# Two identities, two AWS roles (infra/terraform/shared/irsa.tf). The names are fixed, not derived from
# the release: each role's trust policy names exactly system:serviceaccount:<namespace>:<name>.
# Neither gets the default Kubernetes API token: no pod of the app talks to the Kubernetes API.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: medical-rag
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: medical-rag-index-builder
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
automountServiceAccountToken: false
```

Create `deploy/charts/medical-rag/templates/externalsecret.yaml`:
```yaml
# The app's keys for this environment: GOOGLE_API_KEY, HUGGINGFACEHUB_API_TOKEN, FLASK_SECRET_KEY
# (app guide step 8). External Secrets reads Secrets Manager with the node role and writes the Secret
# app-secrets; the app's pods only ever see that Secret. Wave 0: the Job at wave 1 waits until this
# reports Ready.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secrets
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: app-secrets
  dataFrom:
    - extract:
        key: medical-rag/app-{{ .Values.environment }}
```

Create `deploy/charts/medical-rag/templates/networkpolicy.yaml`:
```yaml
# Every pod in this namespace: no incoming connections, and outgoing only DNS and HTTPS, never IMDS
# (concepts §11). Later steps add one policy each to let ingress-nginx and Prometheus in. Policies only
# add permissions, so those steps never have to change this one.
# Outgoing 443 covers STS, S3 (through the VPC's gateway endpoint), Hugging Face and Gemini.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 443
```

Create `deploy/charts/medical-rag/templates/index-job.yaml`:
```yaml
# Builds the pinned index version from the corpus in S3 (app guide step 16). A Sync hook at wave 1: Argo
# CD runs it on every sync, after wave 0 (the Secret, the ServiceAccounts, the network rules) is healthy
# and before wave 2 (the pods) starts. When the version already exists in S3, it stops within seconds
# without calling Hugging Face.
apiVersion: batch/v1
kind: Job
metadata:
  name: index-build
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
    app.kubernetes.io/component: index-build
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "1"
    # Delete the previous run just before the next one starts. Its log stays readable until then.
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  # No second attempt: the embedding client already retries each batch, and a second full run would spend
  # the Hugging Face quota twice.
  backoffLimit: 0
  activeDeadlineSeconds: 1200
  template:
    metadata:
      labels:
        {{- include "medical-rag.labels" . | nindent 8 }}
        app.kubernetes.io/component: index-build
    spec:
      serviceAccountName: medical-rag-index-builder
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        {{- include "medical-rag.podSecurity" . | nindent 8 }}
      containers:
        - name: index-build
          image: {{ include "medical-rag.image" . }}
          command: ["python", "-m", "app.index", "build"]
          env:
            - name: CORPUS_STORE
              value: {{ include "medical-rag.bucket" . }}
            - name: INDEX_STORE
              value: {{ include "medical-rag.bucket" . }}
            # Fail before any embedding call if the corpus does not hash to the pinned version.
            - name: INDEX_EXPECTED_VERSION
              value: {{ required "index.version is required" .Values.index.version | quote }}
            # Never move faiss/LATEST; the builder role is also denied it (infra/terraform/shared/irsa.tf).
            - name: INDEX_UPDATE_LATEST
              value: "false"
            - name: HUGGINGFACEHUB_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: HUGGINGFACEHUB_API_TOKEN
            - name: HOME
              value: /tmp
            {{- include "medical-rag.awsEnv" (dict "role" "medical-rag-index-builder" "Values" .Values) | nindent 12 }}
          securityContext:
            {{- include "medical-rag.containerSecurity" . | nindent 12 }}
          resources:
            {{- toYaml .Values.indexBuild.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: aws-token
              mountPath: /var/run/secrets/aws
              readOnly: true
      volumes:
        # The corpus copy (12 MB) and the new index are written here before the upload.
        - name: tmp
          emptyDir:
            sizeLimit: 512Mi
        {{- include "medical-rag.awsTokenVolume" . | nindent 8 }}
```

Create `deploy/envs/common.yaml`. Replace `<account>` with your account ID:
```yaml
# Settings both environments share. The account ID names the registry, the buckets and the roles. AWS
# documents account IDs as identifiers, not secrets, but from here on this one is in Git.
aws:
  accountId: "<account>"
  region: ap-southeast-1
```

Create `deploy/envs/dev/values.yaml`. Replace the tag and digest with the ones you recorded in step 11:
```yaml
# dev: the first environment every change reaches. Its index Job is the one that embeds a new corpus
# version; prod's finds it already built.
environment: dev

image:
  tag: "<12-hex tag>@sha256:<digest>"   # app guide step 11

index:
  # Quoted: a version of only digits (or digits and one "e") would otherwise be read as a number.
  version: "cc759ae1a093"                # app guide step 12
```

Create `deploy/argocd/apps/medical-rag-dev.yaml`:
```yaml
# The app in dev: the chart in deploy/charts/medical-rag with deploy/envs/dev/values.yaml.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: medical-rag-dev
  namespace: argocd
  labels:
    # A failed sync (a failed index build) shows as Degraded on root (app guide step 15).
    medical-rag/report-failed-sync: "true"
  annotations:
    # After the whole platform (waves -3 to 0): it needs External Secrets, ingress-nginx and Prometheus.
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  sources:
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      path: deploy/charts/medical-rag
      helm:
        # Fixed, so a local `helm template medical-rag …` renders exactly what Argo CD renders.
        releaseName: medical-rag
        valueFiles:
          - $values/deploy/envs/common.yaml
          - $values/deploy/envs/dev/values.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: medical-rag-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # Argo CD creates the namespace with these labels: the Pod Security level "restricted" is enforced,
    # so a pod that could run as root or gain privileges is refused (concepts §18).
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

- **A Sync hook, not a plain Job.** A Job's spec cannot be changed once created, so a plain Job could not be
  updated to a new version. Argo CD deletes and recreates a hook Job on every sync, so each sync runs the Job
  again with the current values. It cannot be a PreSync hook:
  that would run before the ExternalSecret exists, on the very first sync.
- **The Job's ServiceAccount has no Kubernetes API token** (`automountServiceAccountToken: false`). The token
  for AWS is a separate volume, so it still works.
- **`required` in the templates.** A missing account ID, tag or version fails the render with a clear message,
  both on the workstation check and in Argo CD, instead of producing a pod with an empty image.
- **Wave 1 for the Application.** The whole platform comes first. `root` waits for it with the check from step
  15, so a failed first build shows on `root`.

**Commit** (`git add deploy/charts deploy/envs deploy/argocd/apps/medical-rag-dev.yaml`, message `Add the app chart and the dev index build`). Before the commit, `git status --short` shows exactly:
```
?? deploy/argocd/apps/medical-rag-dev.yaml
?? deploy/charts/
?? deploy/envs/
```
Push the commit to the temporary branch `app/step-16` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)). Git shows a new folder as one line.

The namespace does not exist yet, so the objects are checked in `default`:
```bash
helm lint deploy/charts/medical-rag -f deploy/envs/common.yaml -f deploy/envs/dev/values.yaml
helm template medical-rag deploy/charts/medical-rag \
  -f deploy/envs/common.yaml -f deploy/envs/dev/values.yaml -n default \
  | kubectl apply --dry-run=server -n default -f -
kubectl apply --dry-run=server -f deploy/argocd/apps/medical-rag-dev.yaml
```
Expected:
- `1 chart(s) linted, 0 chart(s) failed` (an `[INFO] … icon is recommended` line before it is fine);
- five lines ending in `(server dry run)`: two ServiceAccounts, the NetworkPolicy, the ExternalSecret, the Job;
- `application.argoproj.io/medical-rag-dev created (server dry run)`.

> **Shared state.** The first run writes an index version to S3 that nothing in the cluster can delete (the
> builder role has no delete permission), and it spends Hugging Face quota. Confirm that nothing is there yet,
> and that the corpus is the one from step 13:
> ```bash
> ACC=$(aws sts get-caller-identity --query Account --output text)
> ARTIFACTS=medical-rag-artifacts-$ACC
> aws s3 ls "s3://$ARTIFACTS/faiss/"
> aws s3api head-object --bucket "$ARTIFACTS" \
>   --key corpus/The_GALE_ENCYCLOPEDIA_of_MEDICINE_SECOND.pdf \
>   --checksum-mode ENABLED --query ChecksumSHA256 --output text
> ```
> Expected: no output from the first command, and the checksum recorded in step 13. Anything else: **stop**.

Only if every check passed **and** the Shared state box printed what it must: **Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-16`; on the workstation, `git checkout main && git pull`.
`root` notices the new Application within three minutes; to hurry it:
```bash
kubectl -n argocd annotate applications.argoproj.io root argocd.argoproj.io/refresh=normal --overwrite
```
Then wait: first for Argo CD to create the Job (the Application, the namespace and wave 0 come first),
then for the build. The first run embeds for a few minutes. To watch it, run
`kubectl -n medical-rag-dev get pods -w` in tmux window 2.
```bash
kubectl -n medical-rag-dev wait job/index-build --for=create --timeout=10m
kubectl -n medical-rag-dev wait job/index-build --for=condition=complete --timeout=20m
```
Expected: `job.batch/index-build condition met` twice. If the second never comes, look at the pod in
window 2 instead of waiting 20 minutes.

**Check.** Record every output **now**: the next push (step 17) deletes this Job and its log.

1. The namespace enforces the `restricted` level:
   ```bash
   kubectl get namespace medical-rag-dev -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}'
   ```
   Expected: `restricted`.
2. The Secret is ready and has the three keys, and it existed before the Job's pod:
   ```bash
   kubectl -n medical-rag-dev get externalsecrets.external-secrets.io app-secrets \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
   kubectl -n medical-rag-dev get secret app-secrets -o json | jq -c '.data | keys'
   kubectl -n medical-rag-dev get secret app-secrets -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
   kubectl -n medical-rag-dev get pods -l job-name=index-build -o jsonpath='{.items[0].metadata.creationTimestamp}{"\n"}'
   kubectl -n medical-rag-dev get job index-build -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
   ```
   Expected: `True`; `["FLASK_SECRET_KEY","GOOGLE_API_KEY","HUGGINGFACEHUB_API_TOKEN"]`; then three times: the
   Secret's earlier than the pod's, which proves the wave order (the hook waited for the Secret); and the
   Job's own creation time, which check 7 compares against.
3. The build ran once, for the pinned version:
   ```bash
   kubectl -n medical-rag-dev logs job/index-build | grep -E 'Built index|already exists'
   ```
   Expected: `Built index cc759ae1a093: 759 pages, 7079 chunks in <n>s`. Criterion #6, first half: record `<n>`.
4. S3 holds the version, written by the builder role (the node role has had no access since step 9), and no
   pointer:
   ```bash
   ACC=$(aws sts get-caller-identity --query Account --output text)
   ARTIFACTS=medical-rag-artifacts-$ACC
   aws s3 ls "s3://$ARTIFACTS/faiss/cc759ae1a093/"
   aws s3api head-object --bucket "$ARTIFACTS" --key faiss/LATEST
   ```
   Expected: three objects, `index.faiss`, `index.pkl` and `manifest.json`; then `An error occurred (404)`.
5. Argo CD agrees:
   ```bash
   kubectl -n argocd get applications.argoproj.io medical-rag-dev \
     -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'
   ```
   Expected: `Synced Healthy Succeeded`.
6. The Job's peak memory. Prometheus keeps only 24 hours, so measure it now. A helper that asks Prometheus
   through the API server:
   ```bash
   promq() {
     local q
     q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")
     kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" \
       | jq -r '.data.result[] | "\(.metric.pod // .metric.namespace) \(.value[1])"'
   }
   promq 'max_over_time(container_memory_working_set_bytes{namespace="medical-rag-dev",container="index-build"}[3h])'
   ```
   Expected: one line, `index-build-<hash> <bytes>`. Record it. Prometheus samples every 30 seconds, so a short
   spike can be missed: the true peak is at least this.
7. Nothing re-runs the Job while nothing changes. Wait ten minutes, then:
   ```bash
   kubectl -n medical-rag-dev get job index-build -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
   ```
   Expected: the Job's creation time recorded in check 2, unchanged.

---

## Step 17 — The pods, and what happens when a build fails

**Problem now.** The index exists in S3, but no pod serves the app.

**Why it matters.** The serving pod is the one that faces the internet. It must get the index with the app
role, then keep no AWS credentials and no route to IMDS while it answers requests. A failed build of a new
version must also leave the running pods alone.

**This step.**
- A Deployment at wave 2.
- Its init container runs the same image with `python -m app.index pull`. It is the only container with the
  token for AWS.
- The app container starts gunicorn against the index on the shared `/tmp`.
- A Service in front of it.
- Then, on purpose, a failed build, to prove that it shows on `root` and that the pods keep serving.

**After this step.**
- Works: the app runs in dev, reachable through a port-forward.
- Proven by:
  - this sync's Job skipped the build (criterion #6, second half);
  - the init container pulled `cc759ae1a093`;
  - the time from pod creation to Ready (criterion #7);
  - from the app container, IMDS times out and AWS finds no credentials;
  - `/metrics` reports `rag_index_info{version="cc759ae1a093"}`;
  - a wrong version turns `root` `Degraded` while the pod keeps running.
- Still missing: the app has no public name → step 18.

| File | Change |
|---|---|
| `deploy/charts/medical-rag/values.yaml` | Replicas, resources and probe settings for the pods |
| `deploy/charts/medical-rag/templates/deployment.yaml` | New: the Deployment, wave 2 |
| `deploy/charts/medical-rag/templates/service.yaml` | New: the Service, wave 2 |

**Laptop.** Add to the end of `deploy/charts/medical-rag/values.yaml`:
```yaml

# The pods that serve the app.
replicas: 1
# Spread the replicas over different nodes (prod). A replica that has nowhere to go stays Pending rather
# than sharing a node, so losing one node never takes every replica.
spreadAcrossNodes: false

resources:
  requests:
    cpu: 100m
    memory: 768Mi          # a starting point; measured in step 21
  limits:
    memory: 1536Mi

# The init container that downloads the pinned index.
indexPull:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 512Mi
```

Create `deploy/charts/medical-rag/templates/deployment.yaml`:
```yaml
# The app (app guide step 17). Wave 2: the pods start only after the index Job (wave 1) succeeded, so the
# pinned version is in S3 when the init container asks for it.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: medical-rag
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
    app.kubernetes.io/component: web
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  replicas: {{ .Values.replicas }}
  revisionHistoryLimit: 3
  # Start the new pod before stopping an old one: the app never has fewer ready pods than asked for.
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: medical-rag
      app.kubernetes.io/component: web
  template:
    metadata:
      labels:
        {{- include "medical-rag.labels" . | nindent 8 }}
        app.kubernetes.io/component: web
    spec:
      serviceAccountName: medical-rag
      automountServiceAccountToken: false
      securityContext:
        {{- include "medical-rag.podSecurity" . | nindent 8 }}
      # gunicorn stops within its graceful_timeout (30 s); preStop gives ingress-nginx time to stop sending.
      terminationGracePeriodSeconds: 45
      {{- if .Values.spreadAcrossNodes }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: medical-rag
              app.kubernetes.io/component: web
      {{- end }}
      initContainers:
        # Downloads exactly the pinned version into /tmp/index, with the app role. The only container with
        # the token for AWS: the app container below never calls AWS.
        - name: index-pull
          image: {{ include "medical-rag.image" . }}
          command: ["python", "-m", "app.index", "pull"]
          env:
            - name: INDEX_STORE
              value: {{ include "medical-rag.bucket" . }}
            - name: INDEX_VERSION
              value: {{ required "index.version is required" .Values.index.version | quote }}
            # Refuse "latest": a pod must never read the moving pointer.
            - name: INDEX_REQUIRE_PINNED
              value: "true"
            - name: HOME
              value: /tmp
            {{- include "medical-rag.awsEnv" (dict "role" (printf "medical-rag-app-%s" .Values.environment) "Values" .Values) | nindent 12 }}
          securityContext:
            {{- include "medical-rag.containerSecurity" . | nindent 12 }}
          resources:
            {{- toYaml .Values.indexPull.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: aws-token
              mountPath: /var/run/secrets/aws
              readOnly: true
      containers:
        - name: app
          image: {{ include "medical-rag.image" . }}
          ports:
            - name: http
              containerPort: 8000
          env:
            # The init container already pulled the index into /tmp/index (INDEX_DIR, set in the image).
            - name: INDEX_PULL_ON_START
              value: "false"
          # GOOGLE_API_KEY, HUGGINGFACEHUB_API_TOKEN and FLASK_SECRET_KEY.
          envFrom:
            - secretRef:
                name: app-secrets
          # /readyz answers 200 once the RAG chain is built; about 6 s locally. Up to 5 minutes is allowed.
          startupProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 10
            failureThreshold: 3
          # /healthz answers as long as gunicorn does. Generous, so a pod busy with slow LLM calls is not
          # restarted.
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "5"]
          securityContext:
            {{- include "medical-rag.containerSecurity" . | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        # One writable folder for everything the app writes: the index (/tmp/index), gunicorn's heartbeat
        # files, the Prometheus multiprocess files (/tmp/prometheus) and the Hugging Face cache (/tmp/hf).
        # The root filesystem is read-only.
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        {{- include "medical-rag.awsTokenVolume" . | nindent 8 }}
```

Create `deploy/charts/medical-rag/templates/service.yaml`:
```yaml
# A stable address for the pods. The port is named http: the Ingress (step 18) and the ServiceMonitor
# (step 19) refer to it by name.
apiVersion: v1
kind: Service
metadata:
  name: medical-rag
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
    app.kubernetes.io/component: web
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  selector:
    app.kubernetes.io/name: medical-rag
    app.kubernetes.io/component: web
  ports:
    - name: http
      port: 8000
      targetPort: http
```

**Why:**

- **One `emptyDir` at `/tmp`, not one per folder.** `start.sh` deletes and recreates `/tmp/prometheus` at every
  start. That fails if `/tmp/prometheus` is itself a mount point.
- **The app container has no AWS variables and no token.** It never calls AWS: the index is already on disk.
  If it were taken over, it would find no credentials to steal, and IMDS is closed.
- **Readiness is per worker.** gunicorn runs two workers, each building its own chain, and a probe reaches one
  of them. A worker that never loads makes Ready flicker; the startup probe allows five minutes.

**Commit** (`git add deploy/charts/medical-rag`, message `Add the app Deployment and Service`). Before the commit, `git status --short` shows exactly:
```
 M deploy/charts/medical-rag/values.yaml
?? deploy/charts/medical-rag/templates/deployment.yaml
?? deploy/charts/medical-rag/templates/service.yaml
```
Push the commit to the temporary branch `app/step-17` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)).

The namespace exists now, so the check runs in it, and its Pod Security labels apply: a Deployment that
would break `restricted` gets a warning.
```bash
helm lint deploy/charts/medical-rag -f deploy/envs/common.yaml -f deploy/envs/dev/values.yaml
helm template medical-rag deploy/charts/medical-rag \
  -f deploy/envs/common.yaml -f deploy/envs/dev/values.yaml -n medical-rag-dev \
  | yq 'select(.kind != null and .kind != "Job")' \
  | kubectl apply --dry-run=server -n medical-rag-dev -f -
```
Expected: `1 chart(s) linted, 0 chart(s) failed`, then six lines ending in `(server dry run)` (the
Deployment and the Service are new), and no line that starts with `Warning: would violate PodSecurity`.
The Job is left out (`yq`): a dry run cannot change a Job that already ran, and Argo CD recreates it on
every sync anyway. For the objects Argo CD already manages, kubectl also warns that they are `missing the
kubectl.kubernetes.io/last-applied-configuration annotation`: expected, because Argo CD applies
server-side. A dry run changes nothing.

**Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-17`; on the workstation, `git checkout main && git pull`. Then:
```bash
kubectl -n argocd annotate applications.argoproj.io medical-rag-dev argocd.argoproj.io/refresh=normal --overwrite
kubectl -n medical-rag-dev wait deployment/medical-rag --for=create --timeout=10m
kubectl -n medical-rag-dev rollout status deployment/medical-rag --timeout=10m
```
Expected: `deployment.apps/medical-rag condition met`, then `deployment "medical-rag" successfully rolled out`.
The first line waits for the hook Job (wave 1) to finish, because the Deployment is created only after it.

**Check:**

1. This sync's Job found the version and stopped:
   ```bash
   kubectl -n medical-rag-dev logs job/index-build | grep -E 'Built index|already exists'
   ```
   Expected: `Index version cc759ae1a093 already exists, skipping build`. Criterion #6, second half.
2. The Job finished before the Deployment was created (wave 1 before wave 2):
   ```bash
   kubectl -n medical-rag-dev get job index-build -o jsonpath='{.status.completionTime}{"\n"}'
   kubectl -n medical-rag-dev get deployment medical-rag -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
   ```
   Expected: the first time is earlier than, or equal to, the second.
3. The init container pulled the pinned version:
   ```bash
   kubectl -n medical-rag-dev logs deployment/medical-rag -c index-pull | grep 'Pulled index'
   ```
   Expected: `Pulled index cc759ae1a093 (7079 chunks) into /tmp/index`.
4. Criterion #7, the time from pod creation to Ready:
   ```bash
   kubectl -n medical-rag-dev get pods -l app.kubernetes.io/component=web -o json \
     | jq -r '.items[0] | [.metadata.creationTimestamp, (.status.conditions[] | select(.type=="Ready") | .lastTransitionTime)] | @tsv'
   ```
   Expected: two times; record both and the difference. It includes the image pull if the node did not have
   the image yet.
5. The app container cannot reach IMDS and has no AWS credentials:
   ```bash
   kubectl -n medical-rag-dev exec deployment/medical-rag -c app -- \
     python -c "import socket; socket.create_connection(('169.254.169.254', 80), 3)"
   kubectl -n medical-rag-dev exec deployment/medical-rag -c app -- \
     python -c "import boto3; boto3.client('sts', region_name='ap-southeast-1').get_caller_identity()"
   ```
   Expected: the first ends in `TimeoutError: timed out`: the policy lets out only DNS and port 443, and
   port 443 excludes IMDS. The second, after a few seconds, ends in
   `botocore.exceptions.NoCredentialsError: Unable to locate credentials`.
6. The app reports its index. In tmux window 2 (`Ctrl-b c`), forward a local port to the Service and leave it
   running:
   ```bash
   kubectl -n medical-rag-dev port-forward svc/medical-rag 8000:8000
   ```
   Back in window 0 (`Ctrl-b 0`):
   ```bash
   curl -s localhost:8000/readyz
   curl -s localhost:8000/metrics | grep '^rag_index_info'
   ```
   Expected: `{"status":"ready"}`, then `rag_index_info{version="cc759ae1a093"} 1.0`. Close the forward
   (`Ctrl-C`, `exit`).

   If `/readyz` prints something else, compare with the app's code in `src/app/application.py`: it answers
   200 once the chain is ready.

**Record checks 1–6 now**, before the test below: the test deletes this Job and its log. Do not commit the
evidence until the test's revert is pushed, or `git revert HEAD` would revert the evidence instead.

**Prove what a failed build does.** Pin a version that does not exist, and watch it fail safely. The Job
stops in its first seconds, before any Hugging Face call, because the corpus does not hash to it.

1. On the laptop, in `deploy/envs/dev/values.yaml`, change the version to `version: "000000000000"`, **with**
   the quotes. Without them YAML reads twelve zeros as the number `0`, and the Job's message says `0`.
   This is the one change that skips the branch check: it is meant to fail.
   ```bash
   git status --short                 # only: M deploy/envs/dev/values.yaml
   git add deploy/envs/dev/values.yaml
   git commit -m "Test: pin an index version that does not exist"
   git push origin HEAD:main
   ```
2. On the workstation, make Argo CD read the new commit now instead of within three minutes:
   ```bash
   kubectl -n argocd annotate applications.argoproj.io medical-rag-dev argocd.argoproj.io/refresh=normal --overwrite
   ```
3. Wait for the sync to give up. It is retried five times first (step 15, *Retries come first*), so this
   takes about five minutes:
   ```bash
   kubectl -n argocd wait applications.argoproj.io/medical-rag-dev \
     --for=jsonpath='{.status.operationState.phase}'=Failed --timeout=15m
   ```
   Expected: `application.argoproj.io/medical-rag-dev condition met`. Meanwhile, a look at the retries is
   optional (in another window):
   ```bash
   kubectl -n argocd get applications.argoproj.io medical-rag-dev \
     -o jsonpath='{.status.operationState.phase} {.status.operationState.retryCount} {.status.operationState.message}{"\n"}'
   ```
   It prints `Running`, a count from 0 to 5, and `… Retrying attempt #N at …`. `root` reads `Progressing`
   meanwhile, not yet `Degraded`.
4. Once the wait returns, look at the result:
   ```bash
   kubectl -n argocd get applications.argoproj.io medical-rag-dev \
     -o jsonpath='{.status.operationState.phase} {.status.health.status}{"\n"}'
   kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.status.health.status}{"\n"}'
   kubectl -n argocd get applications.argoproj.io medical-rag-dev -o jsonpath='{.status.operationState.message}{"\n"}'
   kubectl -n medical-rag-dev logs job/index-build | tail -n 2
   kubectl -n medical-rag-dev get pods -l app.kubernetes.io/component=web
   ```
   Expected:
   - `Failed Healthy`: the child's own health ignores the hook;
   - `root` is `Degraded`: the rule from step 15. If it still reads `Progressing`, wait for `root`'s next
     refresh (up to three minutes) and run the line again;
   - the failed sync's message, which says a sync task completed unsuccessfully; the Argo CD UI shows it on
     `root`'s tree;
   - the Job's log ends with `…builds version cc759ae1a093, but 000000000000 was expected…`;
   - the same pod as before is still `Running` and ready: wave 2 was never applied.
5. Undo the test. On the laptop:
   ```bash
   git log -1 --oneline               # must show "Test: pin an index version that does not exist"
   git revert --no-edit HEAD
   git push origin HEAD:main
   ```
   The rendered objects now equal the live ones again, so the app reads `Synced`, and automated sync does not
   run: the last sync stays `Failed`, and `root` stays `Degraded`.
6. On the workstation, make Argo CD read the revert, and check that it has:
   ```bash
   kubectl -n argocd annotate applications.argoproj.io medical-rag-dev argocd.argoproj.io/refresh=normal --overwrite
   kubectl -n argocd wait applications.argoproj.io/medical-rag-dev \
     --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m
   ```
   Expected: `condition met`. Syncing before this could still use the test's commit.
7. Start one sync by hand:
   ```bash
   kubectl -n argocd patch applications.argoproj.io medical-rag-dev --type merge \
     -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{"syncStrategy":{"hook":{}}}}}'
   ```
   If the patch is refused, press **Sync** on `medical-rag-dev` in the Argo CD UI (through the VPN), with
   **Retry** left off.
8. Wait for it. The Job finds the index already built, so this takes about a minute:
   ```bash
   kubectl -n argocd wait applications.argoproj.io/medical-rag-dev \
     --for=jsonpath='{.status.operationState.phase}'=Succeeded --timeout=10m
   ```
   Then run the first two lines of point 4 again. Expected: `Succeeded Healthy`, then `Healthy` (again, give
   `root` up to three minutes).

**Record** the outputs of points 3, 4 and 8. Then commit the evidence.

---

## Step 18 — The app's public name

**Problem now.** The app answers only through a port-forward. ingress-nginx answers `dev.recruitai.io.vn`
with `404`, and the NetworkPolicy from step 16 refuses every incoming connection, including nginx's.

**Why it matters.** Users need the name. But only the chat page should be public: `/metrics`, `/healthz`
and `/readyz` are for Kubernetes and Prometheus, not for the internet. Each question also spends Gemini and
Hugging Face quota, so a single client should not be able to send hundreds.

**This step.** An Ingress for `dev.recruitai.io.vn` ([concepts §19](0-concepts.md#19-ingress)) that routes
exactly `/` and `/clear`, with a longer read timeout and a rate limit. Plus a NetworkPolicy that lets
ingress-nginx reach the pods on port 8000.

**After this step.**
- Works: the app answers on `http://dev.recruitai.io.vn/`.
- Proven by: `/` answers `200`; `/metrics` and `/healthz` answer `404`; a question gets an answer.
- Still missing: Prometheus does not scrape the app → step 19.

| File | Change |
|---|---|
| `deploy/charts/medical-rag/values.yaml` | The Ingress settings |
| `deploy/charts/medical-rag/templates/ingress.yaml` | New: the Ingress, wave 2 |
| `deploy/charts/medical-rag/templates/networkpolicy-from-ingress.yaml` | New: nginx may reach the pods |
| `deploy/envs/dev/values.yaml` | The host name |

**Laptop.** Add to the end of `deploy/charts/medical-rag/values.yaml`:
```yaml

ingress:
  host: ""                 # required: the environment's public name
  # Requests per minute from one client address. externalTrafficPolicy: Local on ingress-nginx keeps the
  # real address, so this limits each user, not the load balancer.
  limitRpm: 30
```

Add to the end of `deploy/envs/dev/values.yaml`:
```yaml

ingress:
  host: dev.recruitai.io.vn            # app guide step 14
```

Create `deploy/charts/medical-rag/templates/ingress.yaml`:
```yaml
# The app's public name, plain HTTP through the public load balancer (app guide step 18). Only the chat page
# and its "clear" link are routed; /metrics, /healthz and /readyz stay inside the cluster, and nginx answers
# 404 for them.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: medical-rag
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    # An answer can take over 60 s: the embedding call retries, then up to two 30 s LLM attempts.
    nginx.ingress.kubernetes.io/proxy-read-timeout: "120"
    nginx.ingress.kubernetes.io/limit-rpm: {{ .Values.ingress.limitRpm | quote }}
spec:
  ingressClassName: nginx
  rules:
    - host: {{ required "ingress.host is required" .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Exact
            backend:
              service:
                name: medical-rag
                port:
                  name: http
          - path: /clear
            pathType: Exact
            backend:
              service:
                name: medical-rag
                port:
                  name: http
```

Create `deploy/charts/medical-rag/templates/networkpolicy-from-ingress.yaml`:
```yaml
# Lets the ingress-nginx controllers reach the app's pods on port 8000. Everything else stays refused by
# the policy "default" (networkpolicy.yaml).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress-nginx
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: medical-rag
      app.kubernetes.io/component: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8000
```

**Why:**

- **`Exact` paths.** The page has no static files (its CSS is inline), and its two forms go to `/` and `/clear`.
  So two exact paths serve the whole app, and anything else is nginx's `404`.
- **No `tls` section.** The public load balancer listens on port 80 only; app traffic is plain HTTP, as the
  design states.
- **The check below runs ingress-nginx's own validation.** Its admission webhook rejects an Ingress that
  clashes with another one, before Argo CD ever sees it.

**Commit** (`git add deploy/charts/medical-rag deploy/envs/dev/values.yaml`, message `Add the dev Ingress`). Before the commit, `git status --short` shows exactly:
```
 M deploy/charts/medical-rag/values.yaml
 M deploy/envs/dev/values.yaml
?? deploy/charts/medical-rag/templates/ingress.yaml
?? deploy/charts/medical-rag/templates/networkpolicy-from-ingress.yaml
```
Push the commit to the temporary branch `app/step-18` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)). The same two commands as in step 17. Expected: `1 chart(s) linted, 0 chart(s) failed`, then eight lines
ending in `(server dry run)`, including `ingress.networking.k8s.io/medical-rag`.

**Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-18`; on the workstation, `git checkout main && git pull`. Then refresh `medical-rag-dev` as in step 17, and wait a minute.

**Check:**
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://dev.recruitai.io.vn/
curl -s -o /dev/null -w '%{http_code}\n' http://dev.recruitai.io.vn/metrics
curl -s -o /dev/null -w '%{http_code}\n' http://dev.recruitai.io.vn/healthz
```
Expected: `200`, `404`, `404`.

Ask one question, keeping the session cookie in a file:
```bash
curl -s -c /tmp/jar -b /tmp/jar -o /dev/null -w '%{http_code}\n' \
  --data-urlencode 'prompt=What are the common symptoms of measles?' \
  http://dev.recruitai.io.vn/
curl -s -b /tmp/jar http://dev.recruitai.io.vn/ | grep -c 'class="message assistant"'
rm /tmp/jar
```
Expected: `302` (the app redirects back to the page after answering), then `1`. A `502` means the model call
failed: the page says which error, and `kubectl -n medical-rag-dev logs deployment/medical-rag -c app` has
the details.

**Record** the three status codes and the question's result. Open `http://dev.recruitai.io.vn/` in a
browser once too.

---

## Step 19 — Prometheus scrapes the app

**Problem now.** The app counts its requests and times its retrieval and LLM calls on `/metrics`, but
nothing collects them, and the NetworkPolicy refuses Prometheus.

**Why it matters.** Step 21 sizes the pods from these measurements, and later alerts and dashboards depend
on them.

**This step.** A ServiceMonitor, the Prometheus Operator's object that says "scrape this Service's `http`
port at `/metrics`", plus a NetworkPolicy that lets Prometheus in on port 8000.

**After this step.**
- Works: Prometheus scrapes the app every 30 seconds.
- Proven by: `up{namespace="medical-rag-dev"}` is `1`.
- Still missing: prod does not exist → Part 4, step 20.

| File | Change |
|---|---|
| `deploy/charts/medical-rag/templates/servicemonitor.yaml` | New: scrape the Service's `http` port |
| `deploy/charts/medical-rag/templates/networkpolicy-from-monitoring.yaml` | New: Prometheus may reach the pods |

**Laptop.** Create `deploy/charts/medical-rag/templates/servicemonitor.yaml`:
```yaml
# Tells Prometheus to scrape the app (app guide step 19). kube-prometheus-stack picks up every
# ServiceMonitor in every namespace (serviceMonitorSelectorNilUsesHelmValues: false in its values).
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: medical-rag
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: medical-rag
      app.kubernetes.io/component: web
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

Create `deploy/charts/medical-rag/templates/networkpolicy-from-monitoring.yaml`:
```yaml
# Lets Prometheus reach the app's pods on port 8000 to scrape /metrics.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-prometheus
  labels:
    {{- include "medical-rag.labels" . | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: medical-rag
      app.kubernetes.io/component: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 8000
```

**Commit** (`git add deploy/charts/medical-rag`, message `Scrape the dev app`). Before the commit, `git status --short` shows exactly:
```
?? deploy/charts/medical-rag/templates/networkpolicy-from-monitoring.yaml
?? deploy/charts/medical-rag/templates/servicemonitor.yaml
```
Push the commit to the temporary branch `app/step-19` and run the check below on the workstation ([how](../guide.md#checking-a-change-before-it-reaches-main)). The same two commands as in step 17. Expected: ten lines ending in `(server dry run)`, including
`servicemonitor.monitoring.coreos.com/medical-rag`.

**Move `main`** to the checked commit: on the laptop, `git push origin HEAD:main`, then
`git push origin --delete app/step-19`; on the workstation, `git checkout main && git pull`.

Check that `main` now holds this step's commit: `git log -1 --oneline` on the workstation must show the
message of your step 19 commit. If it shows the step 18 commit, the push went somewhere else: compare
`git ls-remote origin main app/step-19` with `git log -1` on the laptop, and push again.

Then make Argo CD read it, and wait until the sync of that commit has finished:
```bash
kubectl -n argocd annotate applications.argoproj.io medical-rag-dev argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd wait applications.argoproj.io/medical-rag-dev \
  --for=jsonpath='{.status.operationState.syncResult.revisions[0]}'=$(git rev-parse HEAD) --timeout=10m
kubectl -n argocd get applications.argoproj.io medical-rag-dev \
  -o jsonpath='{.status.sync.status} {.status.operationState.phase}{"\n"}'
```
Expected: `condition met`, then `Synced Succeeded`. Then wait two minutes: Prometheus reloads its targets,
then scrapes.

**Check**, with the `promq` helper from step 16 (define it again in a new shell):
```bash
promq 'up{namespace="medical-rag-dev"}'
promq 'sum by (namespace) (http_requests_total{namespace="medical-rag-dev",route="/"})'
```
Expected: one line ending in `1` (the pod is scraped), then `medical-rag-dev <n>` with `<n>` above zero: the
requests to `/` from step 18.

**Record** both lines.

---

[← Part 2](2-image-and-index.md) · [Index](../guide.md) · [Next: Part 4 →](4-prod-and-measure.md) · [Troubleshooting](troubleshooting.md)
