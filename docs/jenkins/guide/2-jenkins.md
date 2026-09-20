# Jenkins guide — Part 2: Jenkins itself (steps 6–9)

[← Part 1](1-measure-and-foundations.md) · [Index](../guide.md) · [Concepts](0-concepts.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 1 is done and recorded. Its measurements decided three things this part relies on
([evidence](../../evidence/jenkins.md)):
- rootless BuildKit runs on these nodes with `Unconfined` seccomp and AppArmor, so the build pods' namespace must
  be at Pod Security level `privileged`, and step 7 is required;
- the free CPU per node is 560m, 775m and 720m, so each pod's requests must fit the smallest of those gaps.

Read sections [9](0-concepts.md#9-jenkins-controller-build-pods-executors-plugins) to
[14](0-concepts.md#14-credentials) of Concepts, about 15 minutes.

**Done when:** Jenkins runs, opens through the VPN, is configured entirely from Git, and a build pod proves it has
the CI role and cannot reach the node role.

**Every step follows [the loop](../guide.md#the-loop-for-every-step) and the [temporary branch
check](../guide.md#checking-a-change-before-it-reaches-main)**, because from here on a push to `main` is a deploy.

---

## Step 6 — Namespaces, credentials and network rules

**Problem now.** Nothing of Jenkins exists: no namespace to run in, no ServiceAccount the CI role trusts, no
credentials, and no rule that stops a Jenkins pod from asking the node for its AWS identity.

**Why it matters.** The role from step 3 only trusts `jenkins-agents:jenkins-agent`, so that exact ServiceAccount
has to exist in that exact namespace. The GitHub token must reach Jenkins without ever being in Git. And the whole
point of the CI role disappears if a container can still reach IMDS.

**This step.** One Application, `jenkins-platform`, that applies everything Jenkins needs before the chart:
- the two namespaces, with their Pod Security labels;
- the ServiceAccount `jenkins-agent`, and the RBAC that lets the controller create build pods in the other
  namespace;
- the admin password, generated in the cluster like Grafana's, and the GitHub token from Secrets Manager;
- NetworkPolicies: default deny in, egress only DNS, HTTPS and the controller's ports, never IMDS.

**After this step.**
- Works: the namespaces and credentials exist.
- Proven by: both Secrets exist with the expected keys; a test pod in each namespace times out against IMDS while
  DNS still works.
- Still missing: `jenkins-agents` is `privileged`, so it would accept a pod with a host path → step 7.

| File | Change |
|---|---|
| `deploy/argocd/manifests/jenkins/namespaces.yaml` | New: both namespaces |
| `deploy/argocd/manifests/jenkins/rbac.yaml` | New: ServiceAccount, Role, RoleBinding |
| `deploy/argocd/manifests/jenkins/secrets.yaml` | New: admin password generator, ExternalSecrets |
| `deploy/argocd/manifests/jenkins/networkpolicies.yaml` | New: four policies |
| `deploy/argocd/apps/jenkins-platform.yaml` | New: the Application, wave 3 |

**Workstation, first.** One of the two Secrets below is copied from Secrets Manager, so the value has to be
there before anything reads it. Terraform creates `medical-rag/github` **empty** on purpose — values are set once
with the CLI so they never enter Terraform state ([runbook §3](../../runbook.md)) — and the app phase never
needed this one, so on most clusters it is still empty:
```bash
aws secretsmanager describe-secret --secret-id medical-rag/github \
  --query '{Deleted: DeletedDate, Versions: length(VersionIdsToStages || `{}`)}'
aws secretsmanager get-secret-value --secret-id medical-rag/github \
  --query SecretString --output text | jq -r 'keys | join(",")'
```
Expected: `Versions` at least 1, `Deleted` null, and the second command prints exactly `token`. It prints only
the key names, never the value.

If `Versions` is 0, or the second command fails with `ResourceNotFoundException`, the secret has no value yet.
Create a GitHub token and store it — the permissions it needs are in
[concepts §14](0-concepts.md#14-credentials):
```bash
aws secretsmanager put-secret-value --secret-id medical-rag/github \
  --secret-string '{"token":"<the token>"}'
```

> **Why this check and not the one in Part 1.** Step 3 simulated `secretsmanager:GetSecretValue` on this ARN and
> got `implicitDeny` — correctly, because it simulated the *CI role*, which must not read this secret; the
> ExternalSecret reads it through the *node* role. So Part 1 proved nothing about this secret in either
> direction, and it never looked at its contents at all. A permission check and a content check are different
> questions, and the ExternalSecret reports the missing content as `SecretSyncedError` without saying which.

**Laptop.** Create `deploy/argocd/manifests/jenkins/namespaces.yaml`:
```yaml
# Two namespaces, because the controller and the builds need different rights (concepts §8).
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins
  labels:
    # The controller runs as one ordinary pod. Enforced at baseline rather than restricted: the upstream
    # chart does not set a seccomp profile on every container, and restricted requires one. warn and audit
    # stay at restricted, so the gap is visible in every dry run and in the audit log.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
---
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins-agents
  labels:
    # Rootless BuildKit needs Unconfined seccomp and AppArmor, which baseline refuses (Jenkins guide step 1.4).
    # privileged means "no checks", so step 7 adds a ValidatingAdmissionPolicy that refuses what BuildKit does
    # not need. warn and audit stay at baseline, so every relaxation is visible.
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: latest
```

Create `deploy/argocd/manifests/jenkins/rbac.yaml`:
```yaml
# The identity of every build pod. The CI role (infra/terraform/shared/irsa.tf) trusts exactly this
# ServiceAccount in exactly this namespace, and nothing else.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: jenkins-agents
# No annotation is needed: the pod template mounts the token and sets the AWS variables itself, as the app
# chart does (app guide step 17).
automountServiceAccountToken: false
---
# What the controller may do in the agents' namespace: start a build pod, watch it, read its log, run a command
# in it, and delete it. Nothing cluster-wide, and nothing in any other namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agent-runner
  namespace: jenkins-agents
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete", "deletecollection", "get", "list", "watch", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create", "delete", "get"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agent-runner
  namespace: jenkins-agents
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-agent-runner
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: jenkins
```

Create `deploy/argocd/manifests/jenkins/secrets.yaml`:
```yaml
# Jenkins' admin password, generated inside the cluster. Not in Git, not in Secrets Manager, not typed by
# anyone; a rebuilt cluster gets a new one, exactly like Grafana's (GitOps guide step 10).
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: jenkins-admin
  namespace: jenkins
spec:
  length: 32
  digits: 6
  symbols: 0
  noUpper: false
  allowRepeat: true
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jenkins-admin
  namespace: jenkins
spec:
  # "0" means generate once and never refresh: any other interval would change the password under a running
  # controller.
  refreshInterval: "0"
  target:
    name: jenkins-admin
    template:
      data:
        # The two keys the chart reads (controller.admin.userKey and passwordKey).
        jenkins-admin-user: admin
        jenkins-admin-password: "{{ .password }}"
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: jenkins-admin
---
# The GitHub token the pipeline pushes and opens pull requests with. Git holds only the secret's name.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jenkins-github
  namespace: jenkins
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: jenkins-github
  data:
    - secretKey: token
      remoteRef:
        key: medical-rag/github
        property: token
```

Create `deploy/argocd/manifests/jenkins/networkpolicies.yaml`:
```yaml
# Same shape as the app's rules (app guide step 16): deny everything in, allow only what each side needs out,
# and never the metadata service, so no Jenkins pod can borrow the node's AWS identity.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default
  namespace: jenkins
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
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
    # GitHub, the plugin update centre and AWS, but never IMDS.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 443
    # The Kubernetes API, to create and watch build pods. A NetworkPolicy is evaluated after kube-proxy has
    # replaced the ClusterIP, so the real destination is a control-plane address on 6443, not 443.
    - to:
        - ipBlock:
            cidr: 10.10.0.0/16
      ports:
        - protocol: TCP
          port: 6443
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress-nginx
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: jenkins-controller
  policyTypes: [Ingress]
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
          port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-agents
  namespace: jenkins
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: jenkins-controller
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: jenkins-agents
      ports:
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 50000
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default
  namespace: jenkins-agents
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
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
    # ECR, S3, STS, KMS, GitHub, Docker Hub and the package indexes a build needs. Never IMDS.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 443
    # Back to the controller: the agent program (50000) and the HTTP API.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: jenkins
      ports:
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 50000
```

Create `deploy/argocd/apps/jenkins-platform.yaml`:
```yaml
# Everything Jenkins needs before its chart: namespaces, the build pods' ServiceAccount and RBAC, the
# credentials, and the network rules. Wave 3, after the app (waves 1 and 2): nothing here is needed earlier.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jenkins-platform
  namespace: argocd
  labels:
    # A failed sync here means Jenkins cannot start; show it on root like the app's Applications.
    medical-rag/report-failed-sync: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
    targetRevision: main
    path: deploy/argocd/manifests/jenkins
  destination:
    server: https://kubernetes.default.svc
    namespace: jenkins
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

**Why:**

- **Two namespaces, two levels.** The controller does not need anything `restricted` forbids, so it stays as
  strict as the chart allows. Only the build pods' namespace is relaxed, and only because step 1.4 proved BuildKit
  needs it.
- **`automountServiceAccountToken: false` on the ServiceAccount.** The build pod never talks to the Kubernetes API
  with it; it only needs the name, so that STS trusts the projected token the pod mounts itself.
- **A Role, not a ClusterRole.** The controller can create pods in `jenkins-agents` and nowhere else. The chart
  creates an equivalent Role there as well, from `agent.namespace` (step 8); this one is written out so the
  permission is visible in Git, and the two grant the same verbs.
- **The admin password is generated, not stored.** Nobody, including Secrets Manager, holds a password that only
  one person uses through a VPN.
- **Egress to 443, plus 6443 for the controller.** A build reaches ECR, STS, KMS, GitHub and Docker Hub, all over
  HTTPS, and nothing else. The controller also creates and watches build pods, which means the Kubernetes API: a
  NetworkPolicy sees the address after kube-proxy has replaced the ClusterIP, so that rule names the control-plane
  range on 6443. `169.254.169.254/32` is excluded everywhere, so the node role stays out of reach.

**Check before the push.** Push to the temporary branch and, on the workstation, check the commit out. A server
dry run stores nothing, so the namespaces would not exist when the objects inside them are checked. Create those
two first: they hold nothing, Argo CD adopts them at the next sync, and creating them twice changes nothing.
```bash
kubectl apply -f deploy/argocd/manifests/jenkins/namespaces.yaml
kubectl apply --dry-run=server -f deploy/argocd/manifests/jenkins/
```
Expected: two namespaces `created` or `unchanged`, then twelve lines ending in `(server dry run)`, and no
`Warning: would violate PodSecurity`.

**Move `main`** to the checked commit, then on the workstation:
```bash
kubectl -n argocd annotate applications.argoproj.io root argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd wait applications.argoproj.io/jenkins-platform --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m
```
Expected: `condition met`. `root` creates the Application first, so the wait may fail once with `not found`:
repeat it.

**Check:**
```bash
kubectl -n jenkins get externalsecrets.external-secrets.io
kubectl -n jenkins get secret jenkins-admin jenkins-github -o json | jq -r '.items[] | "\(.metadata.name) \(.data | keys | join(","))"'
kubectl get ns jenkins jenkins-agents -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}'
```
Expected:
1. Both ExternalSecrets `Ready=True`.
2. `jenkins-admin jenkins-admin-password,jenkins-admin-user` and `jenkins-github token`.
3. `jenkins baseline` and `jenkins-agents privileged`.

Then prove that no Jenkins pod can reach the node role. One throwaway pod per namespace, deleted straight after:
```bash
for NS in jenkins jenkins-agents; do
  kubectl -n $NS run imds-test --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never --command -- \
    sh -c 'out=$(wget -qO- -T 3 http://169.254.169.254/latest/meta-data/ 2>&1); rc=$?; echo "$out" | head -1; echo "exit=$rc"'
  kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/imds-test --timeout=60s || true
  echo "--- $NS"; kubectl -n $NS logs imds-test
  kubectl -n $NS delete pod imds-test
done
```
Expected, in both namespaces: a timeout message from `wget` and `exit=1`. The exit code is read from `wget`
itself, not from the pipeline that prints its output, which would always be `0`. An answer listing metadata
categories means the policy does not select the pod: stop and look at the NetworkPolicy.

**Record** the three check outputs and both IMDS results.

---

## Step 7 — Narrow what the build namespace accepts

**Problem now.** `jenkins-agents` is at Pod Security level `privileged`, which checks nothing. A pod there could
mount the node's root filesystem, use the host network, or run as a truly privileged container
([concepts §8](0-concepts.md#8-pod-security-levels-and-admission-policies)).

**Why it matters.** BuildKit needs exactly two relaxations: `Unconfined` seccomp and `Unconfined` AppArmor. It does
not need any of the above. Without a second rule, the relaxation is far wider than the need.

**This step.** A ValidatingAdmissionPolicy, built into Kubernetes, that refuses pods in that namespace when they
ask for host access or a privileged container, and a binding that applies it to `jenkins-agents`.

**After this step.**
- Works: the namespace accepts a build pod and refuses a dangerous one.
- Proven by: one refusal per expression shape — a pod-level flag, a volume, a container field — each with the
  policy's own message; then the build pod's own shape accepted (dry run).
- Still missing: there is no Jenkins yet → step 8.

| File | Change |
|---|---|
| `deploy/argocd/manifests/jenkins/admission-policy.yaml` | New: the policy and its binding |

**Laptop.** Create `deploy/argocd/manifests/jenkins/admission-policy.yaml`:
```yaml
# The namespace is at Pod Security level "privileged" so that rootless BuildKit can ask for Unconfined
# seccomp and AppArmor (Jenkins guide step 1.4). This policy takes back everything else that "privileged"
# would allow. It is built into Kubernetes; nothing is installed.
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: jenkins-agents-restrictions
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: "!has(object.spec.hostNetwork) || object.spec.hostNetwork == false"
      message: "hostNetwork is not allowed in jenkins-agents"
    - expression: "!has(object.spec.hostPID) || object.spec.hostPID == false"
      message: "hostPID is not allowed in jenkins-agents"
    - expression: "!has(object.spec.hostIPC) || object.spec.hostIPC == false"
      message: "hostIPC is not allowed in jenkins-agents"
    - expression: "!has(object.spec.volumes) || object.spec.volumes.all(v, !has(v.hostPath))"
      message: "hostPath volumes are not allowed in jenkins-agents"
    - expression: >-
        (object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])).all(c,
          !has(c.securityContext) || !has(c.securityContext.privileged) || c.securityContext.privileged == false)
      message: "privileged containers are not allowed in jenkins-agents"
    - expression: >-
        (object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])).all(c,
          !has(c.securityContext) || !has(c.securityContext.capabilities) || !has(c.securityContext.capabilities.add)
          || c.securityContext.capabilities.add.size() == 0)
      message: "added capabilities are not allowed in jenkins-agents"
    - expression: >-
        (object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])).all(c,
          !has(c.ports) || c.ports.all(p, !has(p.hostPort)))
      message: "host ports are not allowed in jenkins-agents"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: jenkins-agents-restrictions
spec:
  policyName: jenkins-agents-restrictions
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: jenkins-agents
```

**Why:**

- **`failurePolicy: Fail`.** If the policy cannot be evaluated, the pod is refused rather than admitted.
- **The binding names the namespace, not the policy's own scope.** The same policy could later be bound to another
  namespace without being rewritten.
- **`validationActions: [Deny]`.** No warning-only mode: this is the rule that replaces what `privileged` gave up.
- **Both container lists.** An init container can do the same damage as a main one.

**Check before the push.** A policy can only be tested once it is live, so there is nothing to check on the
branch. Push it, **move `main`**, then run the gate and the four dry runs below, in that order.

**Wait until the API server has compiled the policy.** This gate is not optional: until `observedGeneration`
catches up with `generation`, the policy exists in `kubectl get` but is not yet enforced, and **every pod below
is accepted** — which is exactly what a pass looks like.
```bash
kubectl -n argocd annotate applications.argoproj.io root argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd wait applications.argoproj.io/jenkins-platform --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m
for i in $(seq 30); do
  GEN=$(kubectl get validatingadmissionpolicy jenkins-agents-restrictions -o jsonpath='{.metadata.generation}' 2>/dev/null)
  OBS=$(kubectl get validatingadmissionpolicy jenkins-agents-restrictions -o jsonpath='{.status.observedGeneration}' 2>/dev/null)
  [ -n "$GEN" ] && [ "$GEN" = "$OBS" ] && { echo "policy compiled: generation=$GEN"; break; }
  echo "waiting for the policy ($i): generation=${GEN:-none} observed=${OBS:-none}"; sleep 5
done
kubectl get validatingadmissionpolicy jenkins-agents-restrictions \
  -o jsonpath='typeChecking={.status.typeChecking}{"\n"}'
```
Expected: `condition met`, then `policy compiled: generation=1`, then `typeChecking=` followed by either nothing
or a `{"expressionWarnings":null}`-shaped value. If the loop runs out of tries, **stop**: a dry run now proves
nothing. If `typeChecking` lists a warning, it names the expression that does not match the Pod schema — record
it and stop.

**Three refusals, one per expression shape.** The seven rules are written in three shapes, and one test per shape
is the smallest set that exercises all of them: a boolean at pod level (`hostNetwork`, `hostPID`, `hostIPC`), a
list of objects asked with `has()` (`volumes`), and a field inside the container list (`privileged`,
`capabilities.add`, `ports.hostPort`). Testing only one shape would leave the other two unproven.
```bash
# 1. pod-level boolean
kubectl -n jenkins-agents apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: policy-test
spec:
  hostNetwork: true
  containers:
    - name: c
      image: public.ecr.aws/docker/library/busybox:1.37
EOF
# 2. a list of objects
kubectl -n jenkins-agents apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: policy-test
spec:
  containers:
    - name: c
      image: public.ecr.aws/docker/library/busybox:1.37
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
EOF
# 3. a field inside a container
kubectl -n jenkins-agents apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: policy-test
spec:
  containers:
    - name: c
      image: public.ecr.aws/docker/library/busybox:1.37
      securityContext:
        privileged: true
EOF
```
Expected: three failures, each naming its own rule — `hostNetwork is not allowed in jenkins-agents`,
`hostPath volumes are not allowed in jenkins-agents`, `privileged containers are not allowed in jenkins-agents`.
Each message must name **the rule you triggered**: a refusal quoting a different rule means the expressions do
not say what they look like they say. The `Warning: would violate PodSecurity "baseline:latest"` line that comes
with tests 2 and 3 is the namespace's `warn` label, not this policy, and it appears whether or not the policy
works — do not read it as a refusal.

**Then the accept.** Run this one **last**: on its own it cannot tell "the policy allows this pod" from "there is
no policy", so it only means something after the three refusals above have been seen.
```bash
kubectl -n jenkins-agents apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: policy-test
spec:
  containers:
    - name: c
      image: public.ecr.aws/docker/library/busybox:1.37
      securityContext:
        seccompProfile:
          type: Unconfined
        appArmorProfile:
          type: Unconfined
        runAsUser: 1000
EOF
```
Expected: `pod/policy-test created (server dry run)`, with the PodSecurity warning about `Unconfined` — which is
the relaxation this namespace exists to allow.

**Record** the gate's `generation`, the three refusal messages and the accept.

---

## Step 8 — Jenkins itself

**Problem now.** There is no CI: no controller, no UI, nowhere for a pipeline to run.

**Why it matters.** Everything after this step is configuration of a running Jenkins, and that configuration must
come from Git, so that a rebuilt cluster returns the same Jenkins.

**This step.** An Application for the Jenkins Helm chart, pinned, with a values file that sets:
- the admin user from the generated Secret, and the GitHub token as a Jenkins credential;
- a pinned plugin list, and no automatic upgrades;
- the Kubernetes cloud: build pods in `jenkins-agents`, with the ServiceAccount from step 6, capped at one pod;
- the Multibranch job, declared as code;
- the home volume on `gp3`, and the Ingress on `jenkins.recruitai.io.vn`, VPN only.

**After this step.**
- Works: Jenkins runs and opens in the browser through the VPN.
- Proven by: `root` is `Healthy`; the UI asks for a login and the generated password works; the job exists and has
  scanned the repository.
- Still missing: nothing has proven that a build pod gets the CI role → step 9.

| File | Change |
|---|---|
| `deploy/argocd/values/jenkins.yaml` | New: the chart's values, including JCasC |
| `deploy/argocd/apps/jenkins.yaml` | New: the Application, wave 4 |

**Workstation, first.** The values file below pins four plugin versions that this project adds. Read them from
the **stable** channel: the chart's own four pins are built for an LTS core, and the weekly channel can hand
you a plugin built against a newer one. Keep the four lines to paste:
```bash
curl -fsSL https://updates.jenkins.io/stable/update-center.actual.json \
  | jq -r '.plugins | to_entries[]
           | select(.key == "job-dsl" or .key == "credentials-binding"
                    or .key == "pipeline-stage-view" or .key == "timestamper")
           | "    - \(.key):\(.value.version)"' | tee /tmp/plugins.txt
wc -l < /tmp/plugins.txt
```
Expected: **four** lines, one per plugin, then `4`. The names come from the filter, so a count below four means a
plugin was renamed or dropped upstream — stop and find out which before pinning anything. Versions are not all
`1.x`: `job-dsl` and `credentials-binding` publish incrementals such as `3732.v9a_c49a_61a_313`, which is a
version like any other.

**The channel is not a guarantee.** It settles *plugin against core*. It does not settle *plugin against
plugin*: these four and the chart's four are resolved independently, and one of them can raise a single member
of a shared dependency suite above its siblings. That split is invisible until Jenkins starts, which is why
step 8 ends with a check on what actually **loaded**.

`-fsSL` matters, one letter at a time: `-L` because `updates.jenkins.io` answers **307** and redirects to a
mirror, so without it `curl` returns the redirect's HTML page; `-f` so an HTTP error exits non-zero instead of
piping an error page into `jq`; `-S` so errors still print under `-s`.

**Laptop.** Create `deploy/argocd/values/jenkins.yaml`:
```yaml
# Values for the jenkins chart. Everything about this Jenkins is here: no setting is ever made in the UI,
# so a rebuilt cluster comes back identical (concepts §13).
controller:
  # The controller never runs a build: builds run in pods of their own (concepts §9).
  numExecutors: 0
  # Measured budget: the smallest node had 560m of CPU free before Jenkins (Jenkins guide step 1.2).
  resources:
    requests:
      cpu: 250m
      memory: 1Gi
    limits:
      memory: 1536Mi
  javaOpts: "-XX:MaxRAMPercentage=60"

  # The password is generated in the cluster by External Secrets (step 6). Keep `createSecret: true`: it is
  # what makes the chart mount an admin secret at all and define the ${chart-admin-*} variables its default
  # JCasC uses. With `existingSecret` set, the chart mounts that Secret instead of creating one of its own.
  admin:
    createSecret: true
    existingSecret: jenkins-admin

  # Mounts the Secret written by External Secrets, so JCasC can read ${jenkins-github-token} below. Without
  # this list the placeholder stays literal, and the credential becomes the string itself.
  additionalExistingSecrets:
    - name: jenkins-github
      keyName: token

  # Pinned, and never upgraded behind your back: an unpinned plugin update is a common way to break Jenkins.
  installLatestPlugins: false
  installLatestSpecifiedPlugins: false
  installPlugins:
    # Three groups: what the chart needs, what this project adds, and what the resolver had to be told about.
    # The first four are the chart's own defaults for 5.9.63, kept as they are.
    - kubernetes:4557.ve746270f672f      # build pods
    - workflow-aggregator:608.v67378e9d3db_1  # declarative pipelines
    - git:5.10.1                         # checkout
    - configuration-as-code:2121.v86fe99d4b_b_a_b_  # this file
    # The four below are added by this project. Put the versions the command in "Check before" prints, in
    # the same "name:version" form; do not guess them, and read them from the **stable** channel.
    # `installLatestPlugins: false` above means dependencies are installed at their *minimum* required
    # version. A plugin here that needs a newer member of a suite the four above already carry raises that one
    # member and not its siblings, and the split shows up as a refusal at startup, not a download failure.
    - job-dsl:<version>                  # the job below, as code
    - credentials-binding:<version>      # withCredentials
    - pipeline-stage-view:<version>      # stage durations for criterion #8
    - timestamper:<version>              # timestamps in the log
    # Left empty on the first pass. `installLatestPlugins: false` installs every dependency at its *minimum*
    # required version, so a plugin above can raise one member of a shared suite and leave its siblings
    # behind. Jenkins refuses the split at startup and names, by version, what each one must reach; those
    # lines go here. See "Two passes" under Check before the push. Nothing goes here by guesswork.
    # What the pins buy is that nothing upgrades behind your back. They do not guarantee that a future
    # install resolves the same set of files: only these eleven are pinned, the rest are chosen at install
    # time, and a withdrawn version, a rebuilt controller image or a home volume that survived a previous
    # install all change the outcome. Step 19's rebuild is the only clean-volume test of it.
    # - <raised-plugin>:<version>        # delete this line on the first pass; fill it on the second

  jenkinsUrl: https://jenkins.recruitai.io.vn

  ingress:
    enabled: true
    ingressClassName: nginx
    hostName: jenkins.recruitai.io.vn
    annotations:
      # The same VPC-only rule as every internal UI (GitOps guide step 9).
      nginx.ingress.kubernetes.io/allowlist-source-range: "10.10.0.0/16"
    tls:
      # No secretName: ingress-nginx serves the wildcard certificate it holds as its default.
      - hosts:
          - jenkins.recruitai.io.vn

  JCasC:
    defaultConfig: true
    configScripts:
      credentials: |
        credentials:
          system:
            domainCredentials:
              - credentials:
                  - usernamePassword:
                      scope: GLOBAL
                      id: github
                      username: jenkins-bot
                      # Read from the Secret External Secrets wrote; never in Git.
                      password: "${jenkins-github-token}"
                      description: "Fine-grained token for this repository"
      jobs: |
        jobs:
          - script: |
              multibranchPipelineJob('medical-rag') {
                branchSources {
                  git {
                    id('medical-rag')
                    remote('https://github.com/biabeogo147/Medical-RAG-Chatbot.git')
                    includes('main jenkins/step-*')
                  }
                }
                orphanedItemStrategy { discardOldItems { numToKeep(10) } }
                triggers { periodicFolderTrigger { interval('2m') } }
              }

# The Kubernetes cloud. The chart always writes one named "kubernetes" from these values, so it is configured
# here and not in a configScript: two clouds with the same name collide, and the chart's would win.
agent:
  # No default pod template: every pipeline brings its own pod definition, so the tools and their versions
  # live in the Jenkinsfile.
  enabled: false
  disableDefaultAgent: true
  # Build pods run in the other namespace, with the ServiceAccount the CI role trusts (step 6).
  namespace: jenkins-agents
  serviceAccount: jenkins-agent
  # One build pod at a time: a per-job limit would not span Multibranch branches (concepts §12), and the
  # nodes have little CPU to spare.
  containerCap: 1
  podRetention: Never

# The ServiceAccount for build pods is created by jenkins-platform, in the other namespace (step 6).
serviceAccountAgent:
  create: false

rbac:
  # Creates the controller's ServiceAccount and its permission to run build pods in agent.namespace.
  create: true
  # Not needed: the GitHub token reaches JCasC through additionalExistingSecrets, not by reading Secrets
  # through the API.
  readSecrets: false

persistence:
  enabled: true
  storageClass: gp3
  size: 8Gi
```

Create `deploy/argocd/apps/jenkins.yaml`:
```yaml
# Jenkins, from its Helm chart, with the values file above. Wave 4: after jenkins-platform (wave 3), which
# creates the namespace, the credentials and the build pods' ServiceAccount.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jenkins
  namespace: argocd
  labels:
    # The home volume must be released before the cluster stack is destroyed (GitOps guide step 12).
    medical-rag/volumes: "true"
    medical-rag/report-failed-sync: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "4"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://charts.jenkins.io
      chart: jenkins
      targetRevision: 5.9.63
      helm:
        releaseName: jenkins
        valueFiles:
          - $values/deploy/argocd/values/jenkins.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: jenkins
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

**Why:**

- **A second Application, not more files in `jenkins-platform`.** Four reasons, and the first one decides it:
  - **The sources are different kinds.** `jenkins-platform` renders a *directory of manifests* from this repo;
    this one renders an *upstream Helm chart* plus a values file from this repo, through `$values`. One
    Application renders one kind of source, so these cannot be merged.
  - **Order.** The chart needs the namespace, the two Secrets and the ServiceAccount to exist before its first
    pod starts. Waves 3 and 4 give that order, and nothing else in the cluster depends on Jenkins.
  - **Different lifetimes.** Only this Application carries `medical-rag/volumes` and a finalizer, because only
    this one owns a PVC. Separated, Jenkins can be deleted and reinstalled — a chart upgrade, a bad values
    change — without touching the credentials, the namespaces or the admission policy.
  - **Failure isolation.** Both have `prune: true` and `selfHeal: true`. A chart that will not render leaves
    `jenkins` `Degraded` while the credentials and network rules stay `Healthy`, so `root` says which layer
    broke; and pruning never operates on the objects holding the secrets.
- **`numExecutors: 0` and `agent.enabled: false`.** No build runs on the controller, and no default pod template
  is created: each pipeline defines its own pod, so the tool versions are in the `Jenkinsfile` and change with a
  commit.
- **`containerCap: 1`.** One build pod at a time across every branch.
- **`${jenkins-github-token}`.** The chart mounts every Secret listed in `additionalExistingSecrets` into the
  controller, and JCasC then reads `${<secret name>-<key>}` from it.
- **The cloud comes from `agent.*`, not from a configScript.** The chart's default JCasC always defines a cloud
  named `kubernetes`, and it is applied last. A second cloud with the same name would be overwritten, and build
  pods would start in the wrong namespace with the wrong ServiceAccount.
- **The volumes label and the finalizer.** `make down` releases the EBS volume before the cluster stack is
  destroyed, exactly as for Prometheus.

**Two passes, expected.** Mixing a pinned chart default list with plugins of your own can leave Jenkins refusing
a plugin at startup, and nothing before the install detects it (part 2 below says why). So plan for two: the
first install may be refused, the plugin-load check at the end of this step names exactly what to raise, you add
those lines to the third group of `installPlugins`, and the second install is the one that counts. That is not a
failure of the step; it is the step.

> **Before the second pass, settle two things — the loop does not converge without them.**
> 1. **Where the init container writes, and whether it overwrites.** The controller image copies a reference
>    plugin into `$JENKINS_HOME/plugins` only when the file is **absent**, unless the chart's
>    `controller.overwritePlugins` is set. It defaults to `false` and this values file does not set it. On a
>    volume that already holds the old version, raising a pin then changes nothing and the log repeats
>    unchanged. Read it before you loop:
>    ```bash
>    helm show values jenkins/jenkins --version 5.9.63 | yq '.controller | {overwritePlugins, overwritePluginsFromImage}'
>    kubectl -n jenkins get sts jenkins -o yaml | yq '.spec.template.spec.initContainers[].args'
>    ```
>    If the copy is conditional, the second pass also needs `controller.overwritePlugins: true`, or a deleted
>    volume.
> 2. **Which of two causes you actually have.** The split may come from dependency resolution, or from an
>    earlier failed install leaving older plugin files on the volume — this project's first install
>    crash-looped six times before it succeeded. `kubectl -n jenkins logs jenkins-0 -c init` records the
>    resolution and distinguishes them. Fixing the wrong one wastes a full pass.

**Check before the push**, on the temporary branch, on the workstation, in four parts.

**1. No placeholder is left.** The chart does not validate a plugin version, and `job-dsl:<version>` is valid
YAML, so both a render and a server dry run pass with the placeholders still in place. The failure appears
minutes later, inside an init container.
```bash
grep -n '<[A-Za-z][A-Za-z0-9_-]*>' deploy/argocd/values/jenkins.yaml deploy/argocd/apps/jenkins.yaml
```
Expected: no output. This is [rule 5](../guide.md#how-this-guide-works) and it covers both files the step
changes, not only the one you remember editing. It is still only a *presence* test — a version that is
well-formed but wrong passes it, which is what part 2 exists for.

**2. Every pinned version exists, and fits the core the chart runs.** Read the versions out of the file you are
about to push, not out of the update centre — otherwise the check passes while the file pins something else.
```bash
yq '.controller.installPlugins[]' deploy/argocd/values/jenkins.yaml | tee /tmp/plugins.txt | wc -l
while IFS=: read -r NAME VER; do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -I \
    "https://updates.jenkins.io/download/plugins/$NAME/$VER/$NAME.hpi")
  echo "$NAME:$VER $CODE"
done < /tmp/plugins.txt
```
Expected: `8`, then eight lines each ending in `200` or `302`. A `404` is the version that does not exist, named
for you — caught before the push instead of inside an init container.

**What neither part of this pre-flight can see.** All eight versions can exist, be fetchable and satisfy the
core, and Jenkins can still refuse three of them at startup, because a plugin's *dependencies* are resolved
separately from the plugin itself. Nothing before the install proves the resolved set is internally consistent.
The check that catches that is the plugin-load check after the sync.

Then the core, which is a weaker check but cheap:
```bash
helm template jenkins jenkins --repo https://charts.jenkins.io --version 5.9.63 \
  -f deploy/argocd/values/jenkins.yaml --namespace jenkins > /tmp/jenkins-render.yaml
yq 'select(.kind=="StatefulSet") | .spec.template.spec.containers[] | select(.name=="jenkins") | .image' \
  /tmp/jenkins-render.yaml
curl -fsSL https://updates.jenkins.io/stable/update-center.actual.json \
  | jq -r '.plugins | to_entries[]
           | select(.key=="job-dsl" or .key=="credentials-binding"
                    or .key=="pipeline-stage-view" or .key=="timestamper")
           | "\(.key) latest=\(.value.version) requiredCore=\(.value.requiredCore)"'
```
Expected: a controller image whose Jenkins version is at least every `requiredCore`. The update centre only
publishes the *latest* version's `requiredCore`, and a plugin's requirement never goes down, so this is an upper
bound: if the latest fits, the version you pinned fits too. This is the same channel the versions were read
from, so "latest" and "pinned" are normally the same string; if they differ, the file has drifted from the
channel and the comparison is only an upper bound. A `requiredCore` above the image's version means the plugin
needs a newer Jenkins than this chart installs — record it and stop.

**3. What the chart renders, and where.**
```bash
yq 'select(.kind != null) | [.kind, (.metadata.namespace // "<none>")] | @tsv' /tmp/jenkins-render.yaml   | sort | uniq -c
yq 'select(.kind != null) | .kind' /tmp/jenkins-render.yaml | wc -l
```
Expected: the second command prints **16**, and the first splits them across exactly two namespaces — 14 in
`jenkins`, and a `Role` and a `RoleBinding` named `jenkins-schedule-agents` in `jenkins-agents`, which the chart
creates from `agent.namespace`. `select(.kind != null)` drops the empty documents Helm leaves behind, which
would otherwise print as their own row. No `<none>` row: nothing this chart renders is cluster-scoped, so every
object names its namespace. A `<none>` on a namespaced kind would land in whatever namespace your context points
at — stop.

**4. The dry run**, with no `-n`, so each object goes to the namespace it names. Passing `-n jenkins` fails with
*the namespace from the provided object "jenkins-agents" does not match the namespace "jenkins"*.
```bash
kubectl apply --dry-run=server -f /tmp/jenkins-render.yaml
```
Expected: every line ends in `(server dry run)`. Three things in that output are not errors:

- **`configured` instead of `created`,** with `Warning: resource … is missing the
  kubectl.kubernetes.io/last-applied-configuration annotation`. The object already exists and was not applied
  client-side by `kubectl` — here that means Argo CD, which applies server-side. Seeing this before `main` moves
  means the Application was synced earlier than the guide intends: note it, nothing is broken.
- **`pod/jenkins-ui-test-…`,** the chart's Helm *test* Pod. `helm template` renders it, `helm install` never
  creates it, and Argo CD maps `test-success`/`test-failure` hooks to `Skip`, so it never reaches the cluster.
  The loud PodSecurity warning about `runAsNonRoot` and `allowPrivilegeEscalation` is its. Its companion
  `configmap/jenkins-tests` may or may not carry the hook annotation — `yq 'select(.kind=="ConfigMap" and
  .metadata.name=="jenkins-tests") | .metadata.annotations' /tmp/jenkins-render.yaml` says which — and it holds
  a test script, so it is harmless either way.
- **`Warning: would violate PodSecurity` naming `restricted`** on `statefulset.apps/jenkins`: the namespace's
  `warn` label is deliberately stricter than what the chart produces, so this is the expected shape. A
  *warning* can only ever name `restricted` here, because that is the `warn` label; a violation of the enforced
  `baseline` level comes back as an **`error:`** and the object does not apply at all. An `error` mentioning
  PodSecurity: stop.

**Move `main`**, then on the workstation:
```bash
kubectl -n argocd annotate applications.argoproj.io root argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd wait applications.argoproj.io/jenkins --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m
# If this fails at once with "not found", `root` has not created the Application yet: repeat it.
# If it runs the full 15 minutes, the pod is not becoming Healthy — stop waiting and read
#   kubectl -n jenkins get pods
# first, because `wait` cannot tell "slow" from "crash-looping".
kubectl -n jenkins get pods
```
Expected: `condition met`, then one `jenkins-0` pod `2/2 Running`. The first start downloads the plugins, so it
can take several minutes.

**Then check the plugins *loaded*, not that they downloaded.** A plugin whose dependencies are at the wrong
versions is written to disk, appears in `ls`, and is refused at startup. Jenkins keeps running, the pod stays
`2/2 Running`, the UI opens and the job exists — and a feature is simply absent.
```bash
kubectl -n jenkins logs jenkins-0 -c jenkins | grep -c "Jenkins is fully up and running"
kubectl -n jenkins logs jenkins-0 -c jenkins | grep -cE "Failed Loading plugin|Failed to load:|Failed to initialize plugin"
kubectl -n jenkins logs jenkins-0 -c jenkins | grep -A 6 "Failed Loading plugin" | head -40
kubectl -n jenkins logs jenkins-0 -c init | tail -20
```
Expected: `1`, then `0`, then nothing from the third command, and an init log ending without an error.

**Read the first number first.** The second grep is a *negative* assertion — it passes when the evidence is
absent — and the evidence goes absent for three innocent reasons: the boot has not reached the plugin phase yet
(`argocd wait … Healthy` is satisfied while Jenkins is still starting), the pod restarted since
(`kubectl logs` shows only the current instance; add `--previous`), or the startup block aged out of the
kubelet's rotated log. `Jenkins is fully up and running` must be present **in the same output**, or `0` means
nothing. A plugin disabled rather than refused prints no line at all, which this cannot see either.

Any non-zero: **stop**, and read the third command — Jenkins names the plugin and the exact version each
dependency must reach (`Update required: … to be updated to … or higher`). Do not fix it in the UI. Then, per
round:

1. Put each named plugin in the **third group** as `name:version`. If it is already there from an earlier round,
   **raise that line** — never add a second entry for the same name. Before pushing:
   `yq '.controller.installPlugins[]' deploy/argocd/values/jenkins.yaml | cut -d: -f1 | sort | uniq -d`
   must print nothing.
2. Push, then **wait for Argo CD** before touching the pod — the plugin list travels in a ConfigMap, and a pod
   deleted before the sync comes back with the old list and an identical log, which reads as "the fix did
   nothing":
   `kubectl -n argocd wait applications.argoproj.io/jenkins --for=jsonpath='{.status.sync.status}'=Synced --timeout=5m`,
   then confirm the new version string is in the ConfigMap.
3. `kubectl -n jenkins delete pod jenkins-0`, and repeat this check.
4. Confirm the file on disk changed:
   `kubectl -n jenkins exec jenkins-0 -c jenkins -- ls /var/jenkins_home/plugins | grep <the plugin>`.

**Two exits that are not another round.** A demanded version whose `requiredCore` is above the controller
image's version cannot be satisfied by any pin — the answer is a newer chart or image, not another pass. And an
unchanged `.jpi` at point 4 means the copy is conditional, not that the pin is wrong: go back to the box above.

**And `0` is not the end.** It proves every declared minimum is satisfied, not that the combination was ever
tested together, and a plugin *disabled* rather than refused prints nothing at all. The check that closes this
is step 10's requirement of two `[Pipeline] stage` lines in a real build.

To find out *which* plugin asked for the newer member, ask the update centre who depends on it:
```bash
curl -fsSL https://updates.jenkins.io/stable/update-center.actual.json \
  | jq -r --arg dep '<the plugin named in the first SEVERE line>' \
      '.plugins | to_entries[] | .key as $k | .value.dependencies[]?
       | select(.name == $dep) | "\($k) needs \($dep) >= \(.version)"'
```
Expected: one line per plugin that depends on it, with the version each requires. The one asking for the
version in the log is the plugin that split the suite — **probably**: this file publishes the dependency table
of each plugin's *latest* version only, and seven of the eight pins need not be latest, so it answers "who
depends on it today". The version-exact answer is in the init container's own resolution log. Add `.optional`
to the output if you extend it: an optional dependency still imposes its floor once the plugin is present.

**Check.** The password, and the volume:
```bash
kubectl -n jenkins get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
kubectl -n jenkins get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.status.capacity.storage
kubectl get storageclass gp3 -o jsonpath='{.reclaimPolicy}{"\n"}'
kubectl -n jenkins-agents get role,rolebinding
```
Expected: a 32-character password; one PVC on `gp3`, 8Gi; `Delete`, so `make down` releases the volume; and in
`jenkins-agents` **two Roles and two RoleBindings** — `jenkins-agent-runner` from step 6 and
`jenkins-schedule-agents` from the chart. Their verbs overlap rather than match: the hand-written one adds
`deletecollection` on pods and is narrower on `pods/exec`. Two Applications own them separately, so neither
prunes the other.

On the laptop, with WireGuard on, open `https://jenkins.recruitai.io.vn`, log in as `admin` with that password. The
job `medical-rag` exists. Open it: after the first scan, the branch `main` is listed. What matters here is that the
branch appears at all, which shows the job can reach GitHub. That first build may pass, fail or end `NOT_BUILT`,
because `main` still holds the old `Jenkinsfile`; step 9 replaces it.

**Record** the wait's duration, the pod line, the PVC line, that the UI opened only with the VPN, and **both
numbers from the plugin-load check** — `1` for the boot line and `0` for the failures. The third group is empty
on a first pass and empty on a skipped second pass, and nothing else in this step tells them apart.

---

## Step 9 — Prove the build pod's identity

**Problem now.** The role, the ServiceAccount and the network rules exist, but nothing has shown that a real build
pod gets the CI role, or that it cannot reach the node role.

**Why it matters.** Every later step assumes both. If the token were wrong, the pipeline would fail at the first
`docker login`; if IMDS were reachable, the build would silently use the node role instead, and the whole point of
step 3 would be lost.

**This step.** A `Jenkinsfile` with one stage, on the temporary branch only: it starts a build pod with the CI
identity and prints who it is, then shows that the metadata service does not answer.

**After this step.**
- Works: Jenkins can run a build pod, and that pod has the CI role.
- Proven by: `aws sts get-caller-identity` shows `assumed-role/medical-rag-ci/…`; the request to IMDS times out.
- Still missing: nothing is built, and nothing decides which commits deserve a build → Part 3.

| File | Change |
|---|---|
| `Jenkinsfile` | Replaced: the identity test (the pipeline itself comes in Part 3) |

**Laptop.** Replace the whole `Jenkinsfile` with:
```groovy
// Step 9 only: prove that a build pod gets the CI role and cannot reach the node's metadata service.
// Part 3 replaces this with the real pipeline.
pipeline {
  agent {
    kubernetes {
      // Named explicitly, so a cloud misconfigured in step 8 fails here instead of quietly starting the pod
      // in the wrong namespace.
      cloud 'kubernetes'
      namespace 'jenkins-agents'
      defaultContainer 'tools'
      yaml '''
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  automountServiceAccountToken: false
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
  containers:
    - name: tools
      # The tag you verified in app guide step 7: `aws --version` on the workstation prints it.
      image: public.ecr.aws/aws-cli/aws-cli:<aws-cli version>
      # `cat` with a tty keeps the container alive for the whole build, however long it takes; `sleep 3600`
      # would end it after an hour.
      command: ["cat"]
      tty: true
      env:
        # The same four variables the app's pods use (app guide step 7), for the CI role.
        - name: AWS_ROLE_ARN
          value: arn:aws:iam::242834061265:role/medical-rag-ci
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/aws/token
        - name: AWS_REGION
          value: ap-southeast-1
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 512Mi
      volumeMounts:
        - name: aws-token
          mountPath: /var/run/secrets/aws
          readOnly: true
  volumes:
    - name: aws-token
      projected:
        sources:
          - serviceAccountToken:
              audience: sts.amazonaws.com
              expirationSeconds: 3600
              path: token
'''
    }
  }
  options { disableConcurrentBuilds() }
  stages {
    stage('Who am I') {
      steps {
        sh 'aws sts get-caller-identity'
        sh 'curl -sS -m 3 http://169.254.169.254/latest/meta-data/ || echo "IMDS unreachable, exit=$?"'
      }
    }
  }
}
```

**Why:**

- **The pod defines its own identity.** No webhook and no annotation: the projected token and the four variables
  are written here, exactly as the app's chart does.
- **`automountServiceAccountToken: false`.** The build never talks to the Kubernetes API.
- **The account id and the image tag are written out.** The account id is not a secret, and a pipeline cannot read
  a values file before it has a workspace; Part 3 keeps both in one place at the top of the file. Replace
  `<aws-cli version>` with the tag you used in app guide step 7.
- **A temporary branch, not `main`.** Jenkins builds `jenkins/step-*`, so this runs without touching what `main`
  does.

**Check.** Push the branch (`git push origin HEAD:jenkins/step-9`). In the Jenkins UI, the job scans the repository
within two minutes, finds the branch and builds it. Open the build's console output.

Expected:
1. `aws sts get-caller-identity` prints an ARN containing `assumed-role/medical-rag-ci/`.
2. The IMDS line prints a timeout, then `IMDS unreachable, exit=…` with a non-zero code.

If the first command prints `medical-rag-nodes` instead, the pod did not use the token: stop, and compare the four
variables with the app guide's step 7.1 troubleshooting.

**Then move `main`** to this commit and delete the branch, so that `main` also has a `Jenkinsfile` of the new
shape. On `main`, this build runs once and does the same thing.

**Record** the two outputs, and the time from the push to the build starting (the polling delay).

---

[← Part 1](1-measure-and-foundations.md) · [Index](../guide.md) · [Part 3 →](3-pipeline.md) · [Troubleshooting](troubleshooting.md)
