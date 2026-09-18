# GitOps guide — Part 2: Foundation: ingress, volumes, secrets (steps 4–6)

[← Part 1](1-argocd.md) · [Index](../guide.md) · [Part 3 →](3-certificates-and-argocd-ui.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 1 done: Argo CD manages itself and syncs `deploy/argocd/apps/`.

**Done when:** steps 4–6 — both ingress target groups `healthy`, a test volume created and deleted, and `tls-rancher-ingress` synced with the full certificate chain.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`, then refresh Argo CD with `kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite` and run the checks. [tmux windows](../guide.md#tmux-windows): 0 for work, 1 for `make tunnel`.

---

## Step 4 — ingress-nginx

**Goal:** the two load balancers Terraform created find a controller behind their NodePorts.

Create `deploy/argocd/values/ingress-nginx.yaml`:
```yaml
controller:
  # One controller on every node. The load balancers send traffic to all three nodes, and each
  # node's health check passes only if something answers on its NodePort.
  kind: DaemonSet

  service:
    # The cluster has no AWS cloud controller, so a LoadBalancer Service would stay Pending forever.
    # Terraform created the load balancers instead and pointed them at these fixed ports.
    type: NodePort
    nodePorts:
      http: 30080    # public NLB, port 80   (infra/terraform/cluster/loadbalancers.tf)
      https: 30443   # internal NLB, port 443 (infra/terraform/cluster/rancher.tf)
    # Deliver each connection to the controller on the node it arrived at, keeping the caller's real
    # address. With the default ("Cluster"), kube-proxy replaces the source of every such connection
    # with a node's VPC address, and the VPC-only allowlist on the internal UIs (step 9)
    # would let internet traffic through. With one controller per node, every node has one to deliver to.
    externalTrafficPolicy: Local

  extraArgs:
    # The certificate served when an Ingress lists a TLS host without its own Secret: the wildcard
    # *.recruitai.io.vn from step 7. Until it exists, nginx serves a self-signed placeholder.
    default-ssl-certificate: ingress-nginx/wildcard-recruitai-tls

  ingressClassResource:
    name: nginx
    # Ingresses that name no class use this one.
    default: true

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi
```

Create `deploy/argocd/apps/ingress-nginx.yaml`:
```yaml
# ingress-nginx: the single entry point for HTTP(S) traffic into the cluster.
# The project was retired upstream in March 2026 and 4.15.1 is its final release. It stays because the
# NodePorts and Rancher's ingressClassName depend on it; see "Known limits" in README.md.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ingress-nginx
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  sources:
    - repoURL: https://kubernetes.github.io/ingress-nginx
      chart: ingress-nginx
      targetRevision: 4.15.1
      helm:
        releaseName: ingress-nginx
        valueFiles:
          - $values/deploy/argocd/values/ingress-nginx.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ingress-nginx
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Why:**

- **The port numbers are not a choice.** They must match Terraform's target groups exactly. A typo does
  not fail anything; the targets simply stay `unhealthy`.
- **DaemonSet rather than two replicas.** `externalTrafficPolicy: Local` delivers traffic only to a
  controller on the same node, so every node must have one, or its load balancer target fails its health
  check.
- **Why the real source address matters.** The public load balancer keeps the client's internet address;
  the internal one presents its own VPC address. Keeping them unchanged all the way to nginx is what lets
  a later Ingress say "only from `10.10.0.0/16`" and mean "only through the internal path".

**Commit and push** (message `Add ingress-nginx`), then on the workstation `git pull` and refresh ([the loop](../guide.md#the-loop-for-every-step)).

**Check:**
```bash
make apps
```
`ingress-nginx` `Synced` and `Healthy`.

```bash
kubectl -n ingress-nginx get pods -o wide
kubectl -n ingress-nginx get service ingress-nginx-controller
```
Three controller pods, one on each node. The Service shows `80:30080/TCP,443:30443/TCP`.

```bash
kubectl -n ingress-nginx get service ingress-nginx-controller \
  -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
```
`Local`.

Both target groups turn healthy about 20 seconds after the pods start (two checks, ten seconds apart):
```bash
TG_HTTP=$(aws elbv2 describe-target-groups \
  --names medical-rag-ingress-http \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
aws elbv2 describe-target-health \
  --target-group-arn "$TG_HTTP" \
  --query 'TargetHealthDescriptions[].TargetHealth.State'
```
`["healthy", "healthy", "healthy"]`.

```bash
TG_HTTPS=$(aws elbv2 describe-target-groups \
  --names medical-rag-ingress-https \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
aws elbv2 describe-target-health \
  --target-group-arn "$TG_HTTPS" \
  --query 'TargetHealthDescriptions[].TargetHealth.State'
```
`["healthy", "healthy", "healthy"]`.

The public path works end to end:
```bash
NLB=$(terraform -chdir=infra/terraform/cluster output -raw public_nlb_dns)
curl -s -o /dev/null -w '%{http_code}\n' "http://$NLB/"
```
`404`. That is the right answer: the request crossed the load balancer and reached nginx, and no
Ingress exists yet to route it anywhere.

---

## Step 5 — EBS CSI driver and the gp3 StorageClass

**Goal:** a pod that asks for a volume gets an encrypted EBS volume in its own availability zone.

Create `deploy/argocd/values/aws-ebs-csi-driver.yaml`:
```yaml
controller:
  # Set the region directly instead of reading it from instance metadata at start-up.
  region: ap-southeast-1
  # Added to every EBS volume the driver creates. Terraform does not know these volumes, so this tag
  # is how teardown (step 12) and the bill find them.
  extraVolumeTags:
    project: medical-rag

storageClasses:
  - name: gp3
    annotations:
      # PVCs that name no StorageClass get this one.
      storageclass.kubernetes.io/is-default-class: "true"
    # Create the volume only once the pod is scheduled, in that pod's availability zone. An EBS volume
    # can be attached only in its own zone; "Immediate" would pick a zone first and could strand the pod.
    volumeBindingMode: WaitForFirstConsumer
    # Deleting the PVC deletes the EBS volume. Teardown relies on this.
    reclaimPolicy: Delete
    allowVolumeExpansion: true
    parameters:
      type: gp3
      encrypted: "true"
```

Create `deploy/argocd/apps/aws-ebs-csi-driver.yaml`:
```yaml
# The EBS CSI driver creates, attaches and deletes EBS volumes for PersistentVolumeClaims.
# Its AWS permissions come from the node's instance profile (AmazonEBSCSIDriverPolicy, attached by
# Terraform in infra/terraform/cluster/iam.tf); no credential is configured here.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aws-ebs-csi-driver
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  sources:
    - repoURL: https://kubernetes-sigs.github.io/aws-ebs-csi-driver
      chart: aws-ebs-csi-driver
      targetRevision: 2.66.0
      helm:
        releaseName: aws-ebs-csi-driver
        valueFiles:
          - $values/deploy/argocd/values/aws-ebs-csi-driver.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

**Why:**

- **No credentials.** The driver's pods ask the metadata service for the node's role. Terraform set the
  metadata hop limit to 2 on the nodes for exactly this: a pod is one network hop further away than
  the node itself.
- **`kube-system`.** The driver is part of the node's plumbing, like kube-proxy and CoreDNS.

**Commit and push** (message `Add the EBS CSI driver and the gp3 StorageClass`), then on the workstation `git pull` and refresh ([the loop](../guide.md#the-loop-for-every-step)).

**Check:**
```bash
make apps
kubectl get storageclass
```
`aws-ebs-csi-driver` `Synced` and `Healthy`. The StorageClass list shows `gp3 (default)` with
provisioner `ebs.csi.aws.com`, `Delete` and `WaitForFirstConsumer`.

Now prove a volume really works. On the workstation, create a throwaway file **outside the repository**:
```bash
cat > ~/pvc-test.yaml <<'EOF'
# A 1 GiB claim and a pod that writes to it. Deleted at the end of this check.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: pvc-test
  namespace: default
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo ok > /data/probe && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: pvc-test
EOF
```

```bash
kubectl apply -f ~/pvc-test.yaml
kubectl wait --for=condition=Ready pod/pvc-test --timeout=3m
kubectl get pvc pvc-test
```
`STATUS Bound`, `CAPACITY 1Gi`, `STORAGECLASS gp3`.

```bash
kubectl exec pvc-test -- cat /data/probe
```
`ok`: the pod wrote to the volume and read it back.

The volume exists in EC2, encrypted, with the tag from the values file:
```bash
aws ec2 describe-volumes \
  --filters Name=tag:project,Values=medical-rag Name=tag-key,Values=ebs.csi.aws.com/cluster \
  --query 'Volumes[].[VolumeId,Size,State,Encrypted]' \
  --output table
```
One row: `1`, `in-use`, `True`.

Clean up, and prove the volume goes with it:
```bash
kubectl delete -f ~/pvc-test.yaml
kubectl get pv
```
`No resources found` (repeat for up to a minute). Then:
```bash
aws ec2 describe-volumes \
  --filters Name=tag:project,Values=medical-rag Name=tag-key,Values=ebs.csi.aws.com/cluster \
  --query 'Volumes[].VolumeId'
```
`[]`. This is the behaviour teardown depends on.

---

## Step 6 — External Secrets and the platform secrets

**Goal:** the Rancher certificate and password exist as Kubernetes Secrets, copied from Secrets
Manager, without their values ever passing through Git.

This step adds two Applications: the operator (wave -2), and a folder of plain manifests that uses it
(wave -1).

Create `deploy/argocd/values/external-secrets.yaml`:
```yaml
# The chart installs its CRDs (ExternalSecret, ClusterSecretStore, the generators). This is why the
# Application runs one wave before anything that creates those resources.
installCRDs: true

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 256Mi

webhook:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi

certController:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
```

Create `deploy/argocd/apps/external-secrets.yaml`:
```yaml
# External Secrets Operator: copies values from AWS Secrets Manager into Kubernetes Secrets.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  sources:
    - repoURL: https://charts.external-secrets.io
      chart: external-secrets
      targetRevision: 2.10.0
      helm:
        releaseName: external-secrets
        valueFiles:
          - $values/deploy/argocd/values/external-secrets.yaml
    - repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Create `deploy/argocd/apps/platform-secrets.yaml`:
```yaml
# Plain manifests, no chart: the namespaces, the secret store, and the ExternalSecrets the platform
# charts need before they start.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-secrets
  namespace: argocd
  annotations:
    # After external-secrets (its CRDs must exist), before rancher and monitoring (they read these).
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://github.com/biabeogo147/Medical-RAG-Chatbot.git
    targetRevision: main
    path: deploy/argocd/manifests/platform-secrets
  destination:
    server: https://kubernetes.default.svc
    # Every manifest in the folder names its own namespace, so none is set here.
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      # Not strictly needed for these small manifests; kept so every Application follows one rule.
      - ServerSideApply=true
```

Create `deploy/argocd/manifests/platform-secrets/namespaces.yaml`:
```yaml
# Created here, not by the Rancher or monitoring charts, because the Secrets below must exist in these
# namespaces before those charts are installed. Waves inside one Application work like waves between
# Applications: lowest first.
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-system   # the namespace the Rancher chart requires
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

Create `deploy/argocd/manifests/platform-secrets/cluster-secret-store.yaml`:
```yaml
# How External Secrets reaches AWS Secrets Manager, for every namespace.
#
# There is no `auth` block, and that is deliberate: External Secrets then uses the AWS SDK's default
# credential chain, which finds the node's instance profile through the metadata service. The node role
# may read six secrets (llm, github, rancher, rancher-tls, alertmanager, wildcard-tls) and write only
# wildcard-tls: the names are listed in infra/terraform/cluster/main.tf, the permissions in iam.tf.
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-southeast-1
```

Create `deploy/argocd/manifests/platform-secrets/rancher-secrets.yaml`:
```yaml
# The two Secrets Rancher expects, copied from Secrets Manager. Git holds only the secret names.
#
# `dataFrom.extract` turns each JSON key of the secret into a key of the Kubernetes Secret, unchanged:
#   medical-rag/rancher-tls  {"tls.crt": ..., "tls.key": ...}  -> tls.crt, tls.key
#   medical-rag/rancher      {"bootstrapPassword": ...}        -> bootstrapPassword
# (The JSON shapes were set in Terraform guide step 17.)
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
  annotations:
    argocd.argoproj.io/sync-wave: "1"   # after the store and the namespace
spec:
  # A renewed certificate stored with put-secret-value reaches the cluster within an hour.
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: tls-rancher-ingress   # the exact name Rancher's `ingress.tls.source: secret` looks for
    template:
      type: kubernetes.io/tls   # what an Ingress needs for TLS
  dataFrom:
    - extract:
        key: medical-rag/rancher-tls
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: bootstrap-secret
  namespace: cattle-system
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: bootstrap-secret   # read by Rancher through extraEnv (step 11)
  dataFrom:
    - extract:
        key: medical-rag/rancher
```

**Why:**

- **Keys with a dot.** `tls.crt` contains a dot, and the single-key form (`remoteRef.property`) reads a
  dot as "go one level deeper into the JSON". `dataFrom.extract` copies all keys as they are, so the
  problem never comes up.
- **`ClusterSecretStore`, not `SecretStore`.** One store for every namespace; the app and Jenkins will
  use it too. The node role, not the store, limits which secrets can be read.

**Commit and push** (message `Add External Secrets and the platform secrets`), then on the workstation `git pull` and refresh ([the loop](../guide.md#the-loop-for-every-step)).

**Check:**
```bash
make apps
```
`external-secrets` and `platform-secrets`, both `Synced` and `Healthy`. `platform-secrets` may show
`Progressing` for a minute while the operator starts.

```bash
kubectl get clustersecretstore
```
`aws-secrets-manager` with `STATUS Valid` and `READY True`. `False` here almost always means the pod
could not reach the metadata service or the role lacks permission; see [Troubleshooting](troubleshooting.md).

```bash
kubectl -n cattle-system get externalsecret
kubectl -n cattle-system get secret tls-rancher-ingress bootstrap-secret
```
Both ExternalSecrets `SecretSynced` / `True`. The Secrets: `tls-rancher-ingress` type
`kubernetes.io/tls` with `DATA 2`, `bootstrap-secret` type `Opaque` with `DATA 1`. These commands show
counts, not values.

Confirm it is the right certificate. A certificate is public, so printing its subject is fine; the key
is never printed:
```bash
kubectl -n cattle-system get secret tls-rancher-ingress \
  -o jsonpath='{.data.tls\.crt}' > /tmp/rancher-crt.b64
base64 -d /tmp/rancher-crt.b64 > /tmp/rancher.crt
openssl x509 -in /tmp/rancher.crt -noout -subject -issuer -enddate
grep -c 'BEGIN CERTIFICATE' /tmp/rancher.crt
rm /tmp/rancher-crt.b64 /tmp/rancher.crt
```
`subject=CN = rancher.recruitai.io.vn`, an issuer from Sectigo, and the expiry date of your order.
`openssl x509` reads only the first certificate in the file, so the `grep` counts them all: **2 or
more**. `1` means only the server certificate was stored, without the Sectigo intermediates; Rancher's
agents would then reject it. Store the full chain again ([Terraform guide step 17](../../terraform/guide/5-domain-certificate-and-secrets.md#step-17--migrate-dns-and-store-the-keys)).

---

[← Part 1](1-argocd.md) · [Index](../guide.md) · [Part 3 →](3-certificates-and-argocd-ui.md) · [Troubleshooting](troubleshooting.md)
