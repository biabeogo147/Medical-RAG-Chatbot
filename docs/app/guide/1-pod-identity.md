# App guide — Part 1: An AWS identity for the app's own pods (steps 1–9)

[Index](../guide.md) · [Next: Part 2 →](2-image-and-index.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** the GitOps phase is finished: after a rebuild every Application is `Synced` and
`Healthy`. The laptop has Git; everything else runs on the ops workstation.

**Done when:** a pod running as ServiceAccount `medical-rag` in `medical-rag-dev` gets the role
`medical-rag-app-dev`. It can read `faiss/*` in the artifacts bucket and nothing else. The same pod cannot
reach the instance metadata service. The node role can no longer read the artifacts bucket at all.

**Every step follows [the loop](../guide.md#the-loop-for-every-step).** Push only the files a step lists,
and run its **check before** first.

---

Today every pod on a node uses the node's IAM role. It gets that role from the instance metadata
service (IMDS) at `169.254.169.254`. That role reads six secrets, including the wildcard certificate's
private key. It changes a DNS record, writes and deletes in S3, pushes to ECR, and signs with the cosign
key. The chatbot is the only pod that takes traffic from the internet. If it were taken over, all of
that would go with it.

A NetworkPolicy can cut a pod off from IMDS. But the app has to download its index from S3 when it
starts, and a NetworkPolicy applies to a whole pod: it cannot block the app container and still let the
init container through. So the pod needs AWS credentials that do not come from the node.

This part gives the app's pods their own IAM roles, the way EKS does it with IRSA ("IAM roles for
service accounts"). Four pieces are built in order:

1. **A signing key that does not change.** The API server signs every service-account token with it. The
   key is kept in Secrets Manager, so every rebuild uses the same one.
2. **A public issuer.** The API server writes the issuer URL into each token. The public half of the
   key is published at that URL in an S3 bucket, where AWS can fetch it.
3. **An OIDC provider in IAM, and roles that trust it.** Each role accepts a token only for one named
   ServiceAccount in one named namespace.
4. **A pod that asks for such a token.** The pod mounts a token meant for AWS (`audience:
   sts.amazonaws.com`), and four environment variables tell the AWS SDK to exchange it for the role.

EKS adds a webhook that injects piece 4 into every pod. This project does not. Only our own chart needs
it, and the chart can write the same volume and variables itself. The webhook would add a component that can
block the creation of every pod in the cluster when it is down.

**Assumption until step 7.** Nothing in this part is proven until the pod in step 7 prints the right role
ARN. Parts 3 and 4 are written only after that.

---

## Step 1 — Read-only checks before anything is created

**Goal:** know that the public bucket can exist before any code depends on it.

Nothing is written in this step. On the workstation:
```bash
ACC=$(aws sts get-caller-identity --query Account --output text)
aws s3control get-public-access-block --account-id "$ACC"
```
One of two answers:

- `An error occurred (NoSuchPublicAccessBlockConfiguration)`: nothing is blocked at account level.
  Continue.
- A JSON block. Continue only if `BlockPublicPolicy` and `RestrictPublicBuckets` are both `false`.

If either one is `true`, **stop here.** Do not switch it off: that setting protects every bucket in the
account. The issuer would then have to sit behind CloudFront instead of S3, which this guide does not
cover yet.

```bash
aws s3api head-bucket --bucket "medical-rag-oidc-$ACC"
```
Expected: `An error occurred (404) when calling the HeadBucket operation: Not Found`. The name is free.
A `403` means another account owns that name. Stop.

```bash
aws iam list-open-id-connect-providers
```
Expected: `"OpenIDConnectProviderList": []`, or a list without any `medical-rag-oidc` entry.

**Record** the three answers in `docs/evidence/app.md` (a new file; one line each is enough).

---

## Step 2 — The signing key

**Goal:** one RSA key pair that every rebuild of the cluster uses. The private key is in Secrets Manager
and nowhere else.

| File | Change |
|---|---|
| `infra/terraform/shared/secrets.tf` | A new empty secret, `medical-rag/sa-signer` |

**Laptop.** Add to the end of `infra/terraform/shared/secrets.tf`:
```hcl
# The private key the API server signs service-account tokens with (app guide step 2). Every rebuild
# uses the same key, so the public key set AWS trusts never changes. It is set once with
# put-secret-value, so Terraform never sees the value.
#
# Deliberately NOT in the node role's list (cluster/main.tf). Whoever holds this key can mint a token for
# any service account, and so take every role that trusts this cluster. Only the workstation reads it,
# while Ansible builds the cluster.
resource "aws_secretsmanager_secret" "sa_signer" {
  name                    = "${var.project}/sa-signer"
  recovery_window_in_days = 7
}
```

**Why:**

- **kubeadm makes a new key on every `kubeadm init`.** Each rebuild would then publish a different
  public key, and the roles would reject tokens until someone published the new one. A key that is
  already on disk is reused instead: kubeadm prints `[certs] Using the existing "sa" key`.
- **The other two control planes get the same key without extra work.** `kubeadm join
  --control-plane` copies it from the Secret that `--upload-certs` fills.
- **Not in `secret_names` either.** That output lists what the cluster reads. This secret is read only
  by the workstation.

**Check before:** `git status --short` shows only ` M infra/terraform/shared/secrets.tf`.

**Commit and push** (`git add infra/terraform/shared/secrets.tf`, message
`Add the service-account signing key secret`). Then on the workstation, after `git pull`:
```bash
make shared
```
Expect **1 to add, 0 to change, 0 to destroy**, then type `yes`. Anything else: type `no` and stop.

> **Shared state from here.** Overwriting this key later breaks every role until the new public key is
> published. So first check that the secret has no value yet:
> ```bash
> aws secretsmanager describe-secret \
>   --secret-id medical-rag/sa-signer \
>   --query VersionIdsToStages
> ```
> Expected: `null`. Anything else means a key is already stored. **Stop.** Do not run the rest of this
> step.

Create the key in memory-backed `/dev/shm`, so it never touches the disk. `umask 077` keeps it
readable by you only:
```bash
umask 077
cd /dev/shm
openssl genrsa -out sa.key 2048
openssl rsa -in sa.key -pubout -out sa.pub
sha256sum sa.pub
```
Keep the `sha256sum` line; step 4 compares against it. Store the private key:
```bash
aws secretsmanager put-secret-value \
  --secret-id medical-rag/sa-signer \
  --secret-string file://sa.key
```
Expected: JSON with a `VersionId` and `"VersionStages": ["AWSCURRENT"]`.

**Check:** read the key back and derive its public half. It must equal the file:
```bash
aws secretsmanager get-secret-value \
  --secret-id medical-rag/sa-signer \
  --query SecretString \
  --output text \
  | openssl rsa -pubout 2>/dev/null \
  | diff - sa.pub && echo MATCH
```
Expected: `MATCH`. Only then remove the local copies:
```bash
shred -u sa.key sa.pub
umask 022
cd ~/Medical-RAG-Chatbot
```
Also check that the node role cannot read the key:
```bash
grep -n sa-signer infra/terraform/cluster/main.tf
```
Expected: no output.

**Record** the `sha256sum` of `sa.pub`. It is public and safe to write down.

---

## Step 3 — The issuer bucket

**Goal:** a bucket whose URL becomes the issuer, able to serve exactly two public files.

| File | Change |
|---|---|
| `infra/terraform/shared/oidc.tf` | New file: the bucket, its public-access settings, encryption, versioning, policy, and the issuer URL |

**Laptop.** Create `infra/terraform/shared/oidc.tf`:
```hcl
# The public half of workload identity. Pods of the app prove who they are with a token the API server
# signs. AWS checks the signature against the key set published here (app guide steps 3 and 5).
#
# The bucket holds two objects, both public by design: a discovery document and the public key set.
# Nothing secret is ever stored here. The private key is in Secrets Manager (medical-rag/sa-signer).

resource "aws_s3_bucket" "oidc" {
  bucket = "${local.name}-oidc-${local.account_id}"

  lifecycle {
    # Every role the app's pods use trusts this exact URL. If the bucket were deleted, anyone could create
    # one with the same name, publish their own key, and have their tokens accepted.
    prevent_destroy = true
  }
}

locals {
  # The issuer URL. The API server writes it into every token (Ansible group_vars/all.yml builds the
  # same string), and IAM trusts it (irsa.tf). No dots in the bucket name, so S3's certificate covers it.
  oidc_host       = "${aws_s3_bucket.oidc.bucket}.s3.${var.region}.amazonaws.com"
  oidc_issuer_url = "https://${local.oidc_host}"

  # The two paths AWS fetches: the discovery document, then the key set it points to.
  oidc_documents = [".well-known/openid-configuration", "openid/v1/jwks"]
}

# ACLs stay blocked. Only a bucket policy may make objects public, and the one below names two keys.
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A key set overwritten by mistake can be restored from the previous version.
resource "aws_s3_bucket_versioning" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "oidc" {
  # Anyone may read the two documents. That is how OIDC works: AWS fetches them without credentials.
  statement {
    sid       = "PublicIssuerDocuments"
    actions   = ["s3:GetObject"]
    resources = [for key in local.oidc_documents : "${aws_s3_bucket.oidc.arn}/${key}"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  # The same TLS-only rule as every other bucket in the project.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.oidc.arn, "${aws_s3_bucket.oidc.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  policy = data.aws_iam_policy_document.oidc.json

  # With public policies still blocked, S3 would refuse this one.
  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

output "oidc_issuer_url" {
  value = local.oidc_issuer_url
}
```

**Why:**

- **A bucket of its own, in the shared stack.** The issuer URL can never change: the roles, the API
  server flags and every token name it. The cluster stack is destroyed daily and the shared stack is
  not, so the bucket lives in shared. It is also separate from the artifacts bucket, which must never
  become public.
- **`prevent_destroy`, and no `force_destroy`.** S3 bucket names are global. A deleted issuer bucket
  is a name someone else can claim.
- **No `--acl public-read`,** unlike the upstream instructions. New buckets have ACLs disabled, so the
  policy is what grants public read.

**Check before:** `git status --short` shows only `?? infra/terraform/shared/oidc.tf`.

**Commit and push** (`git add infra/terraform/shared/oidc.tf`, message `Add the OIDC issuer bucket`),
`git pull`, then:
```bash
make shared
```
Expect **5 to add, 0 to change, 0 to destroy**, and `oidc_issuer_url` among the outputs. The word
`replace` must not appear anywhere in the plan. Then type `yes`. Anything else: type `no` and stop.

**Check:**
```bash
ACC=$(aws sts get-caller-identity --query Account --output text)
ISSUER=$(terraform -chdir=infra/terraform/shared output -raw oidc_issuer_url)
echo "$ISSUER"
aws s3api get-bucket-policy-status --bucket "medical-rag-oidc-$ACC"
curl -s -o /dev/null -w '%{http_code}\n' "$ISSUER/.well-known/openid-configuration"
```
- The URL is `https://medical-rag-oidc-<account>.s3.ap-southeast-1.amazonaws.com`.
- The policy status is `"IsPublic": true`.
- The HTTP code is `403`: the object does not exist yet, and an anonymous caller may not list the bucket.
  Step 5 turns it into `200`.

---

## Step 4 — Build the cluster with the stable key and the public issuer

**Goal:** the API server signs tokens with the key from step 2, names the bucket as their issuer, and
advertises the key set's public URL.

> **This step rebuilds the cluster.** The issuer and the key are chosen when `kubeadm init` runs, and
> `kubeadm init` runs only on a new cluster. If the cluster is running, take it down first:
> `make down`, as in GitOps guide step 12. Nothing else in the project needs to change: the certificate
> comes back from its backup as usual.

| File | Change |
|---|---|
| `infra/ansible/inventory/group_vars/all.yml` | `oidc_issuer_url` |
| `infra/ansible/roles/kubeadm_init/tasks/main.yml` | Put the key in place before `kubeadm init`; refuse a cluster built with a different key; validate the configuration |
| `infra/ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2` | Four API server flags |

**Laptop.** Add to the end of `infra/ansible/inventory/group_vars/all.yml`:
```yaml

# --- workload identity (app guide part 1) -----------------------------------------------------------
# The issuer written into every service-account token, and trusted by AWS. It must be exactly the URL of
# the bucket in infra/terraform/shared/oidc.tf, or AWS rejects every token.
oidc_issuer_url: "https://{{ project }}-oidc-{{ aws_account_id }}.s3.{{ aws_region }}.amazonaws.com"
```

In `infra/ansible/roles/kubeadm_init/tasks/main.yml`, insert these tasks **between** `Check whether
this node is already a control plane` and `Write the kubeadm configuration`:
```yaml
- name: Read the service-account signing key from Secrets Manager
  # Read on the workstation, whose role may read it; the node role may not. Every rebuild uses the same
  # key, so the key set published for AWS (app guide step 5) stays valid.
  ansible.builtin.command: >-
    aws secretsmanager get-secret-value
    --region {{ aws_region }}
    --secret-id {{ project }}/sa-signer
    --query SecretString
    --output text
  delegate_to: localhost
  become: false
  register: sa_signer
  changed_when: false
  no_log: true

- name: Make sure the certificate directory exists
  ansible.builtin.file:
    path: /etc/kubernetes/pki
    state: directory
    mode: '0755'

- name: Look at the signing key of an existing cluster
  ansible.builtin.stat:
    path: /etc/kubernetes/pki/sa.key
    checksum_algorithm: sha256
  register: sa_key_file

- name: Refuse to go on with a cluster built with a different key
  # Tokens from such a cluster would be rejected by AWS. Swapping the key under a running API server is
  # not the fix: the issuer and the key are chosen at kubeadm init, so the fix is a rebuild.
  ansible.builtin.assert:
    that:
      - sa_key_file.stat.exists
      - sa_key_file.stat.checksum == ((sa_signer.stdout + '\n') | hash('sha256'))
    fail_msg: >-
      /etc/kubernetes/pki/sa.key is not the key in {{ project }}/sa-signer. Rebuild the cluster:
      make down, make infra, make cluster (app guide step 4).
  when: kubeadm_admin_conf.stat.exists

- name: Put the signing key in place before kubeadm init
  # kubeadm reuses a key it finds here instead of generating one. The copy travels through the SSM transfer
  # bucket (objects expire within a day). It happens during make cluster, before Argo CD or any workload
  # is installed, so no pod exists yet that could read it through the node role.
  ansible.builtin.copy:
    content: "{{ sa_signer.stdout }}\n"
    dest: /etc/kubernetes/pki/sa.key
    owner: root
    group: root
    mode: '0600'
  when: not kubeadm_admin_conf.stat.exists
  no_log: true

- name: Derive the public half next to it
  # kubeadm does not write sa.pub when it reuses sa.key, and the API server needs both.
  ansible.builtin.command: openssl rsa -in /etc/kubernetes/pki/sa.key -pubout -out /etc/kubernetes/pki/sa.pub
  when: not kubeadm_admin_conf.stat.exists
  changed_when: true
```
In the same file, insert this task **between** `Write the kubeadm configuration` and `Initialise the
control plane`:
```yaml
- name: Validate the kubeadm configuration
  # A wrong field or bad indentation stops the play here, before kubeadm init changes anything. kubeadm
  # does not check extraArgs names or values: a misspelt flag shows up later, as kubeadm init timing out
  # while it waits for the control plane.
  ansible.builtin.command: kubeadm config validate --config /etc/kubernetes/kubeadm-config.yaml
  changed_when: false
```

In `infra/ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2`, add an `extraArgs` list under
`apiServer:`, after `certSANs`, at the same indentation:
```yaml
  # Workload identity (app guide part 1). Tokens are signed for the public issuer that AWS trusts. The
  # in-cluster issuer stays in the list, so a token that names it is still accepted. v1beta4 takes a list,
  # which is what lets a flag appear twice.
  extraArgs:
    - name: service-account-issuer
      value: "{{ oidc_issuer_url }}"
    - name: service-account-issuer
      value: "https://kubernetes.default.svc.cluster.local"
    # Without this, the discovery document would point AWS at the private API address for the key set.
    - name: service-account-jwks-uri
      value: "{{ oidc_issuer_url }}/openid/v1/jwks"
    # Set explicitly. Unset, it would default to the first issuer alone, and a client asking for the old
    # audience would be refused. sts.amazonaws.com is deliberately absent: a token minted for AWS must not
    # also work against this API server.
    - name: api-audiences
      value: "{{ oidc_issuer_url }},https://kubernetes.default.svc.cluster.local"
```

**Why:**

- **The key is read on the workstation, not on the node.** The node role cannot read `sa-signer`
  (step 2). If it could, so could every pod through IMDS.
- **The joining control planes need nothing new.** `kubeadm_join` re-uploads the control-plane
  certificates before each join, `sa.key` and `sa.pub` included, and the joins read the same
  ClusterConfiguration, so they get the same flags.
- **The assert protects a running cluster.** On an existing cluster, `make cluster` changes nothing here,
  unless the cluster was built with another key. Then it stops and says to rebuild.

**Commit and push** (`git add infra/ansible/inventory/group_vars/all.yml
infra/ansible/roles/kubeadm_init/tasks/main.yml infra/ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2`,
message `Build the cluster with a stable service-account key and a public issuer`). Before the push,
`git status --short` on the laptop lists exactly those three files. Nothing runs from `infra/ansible` until you run `make cluster`, so the push itself changes
nothing.

**Check before the rebuild**, on the workstation after `git pull`:
```bash
cd infra/ansible
ansible-playbook site.yml --syntax-check
cd ~/Medical-RAG-Chatbot
```
Expected: the last line is `playbook: site.yml`. With the cluster down, warnings such as `provided hosts
list is empty` come first; they are expected. The configuration file itself is validated by the new task
on node 1, before `kubeadm init`.

**Rebuild:**
```bash
make infra
make cluster
```
`make cluster` now shows `Validate the kubeadm configuration` as `ok` on node 1, before `Initialise
the control plane`. Then, in window 1, stop the old tunnel with `Ctrl-C` (it points at a node that no
longer exists) and run `make tunnel` again. Back in window 0:
```bash
make bootstrap
kubectl -n argocd wait applications.argoproj.io/root \
  --for=jsonpath='{.status.health.status}'=Healthy \
  --timeout=30m
```

**Check:**

1. The API server advertises the new issuer:
   ```bash
   kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer, .jwks_uri'
   ```
   Expected, two lines: `https://medical-rag-oidc-<account>.s3.ap-southeast-1.amazonaws.com` and the
   same URL followed by `/openid/v1/jwks`.
2. All three nodes hold the key from step 2:
   ```bash
   ACC=$(aws sts get-caller-identity --query Account --output text)
   cd infra/ansible
   ansible nodes -b -m ansible.builtin.command \
     -a "sha256sum /etc/kubernetes/pki/sa.pub" \
     -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id="$ACC"
   cd ~/Medical-RAG-Chatbot
   ```
   Expected: for each node, a `| CHANGED | rc=0 >>` line and then a hash line. The three hash lines are
   identical, and equal to the one recorded in step 2.
3. The flags are in the running API server on every node:
   ```bash
   kubectl -n kube-system get pods -l component=kube-apiserver -o json \
     | jq -r '.items[] | .metadata.name as $n | .spec.containers[0].command[]
         | select(test("service-account-(issuer|jwks-uri)|api-audiences")) | "\($n) \(.)"'
   ```
   Expected: 12 lines, four per `kube-apiserver-*` pod. Each pod has two `--service-account-issuer=` lines,
   the S3 URL first, then `https://kubernetes.default.svc.cluster.local`. Then one
   `--service-account-jwks-uri=` line and one `--api-audiences=` line. The order matters: the first issuer
   is the one that signs. Check 1 already showed it.
4. `root` turned `Healthy`, and `kubectl -n argocd get applications.argoproj.io` shows every Application
   `Synced` and `Healthy`. The audience change broke none of them.
5. The guard on a running cluster passes:
   ```bash
   make cluster
   ```
   Expected: `Refuse to go on with a cluster built with a different key` shows `ok` for node 1.
   `Put the signing key in place…` and `Derive the public half…` are `skipping`. The recap shows
   `changed=0` for every node.

**Record** the issuer line and the three hashes.

---

## Step 5 — Publish the issuer documents

**Goal:** AWS can fetch the discovery document and the key set from the issuer URL, and they are exactly
what the API server serves.

| File | Change |
|---|---|
| `infra/scripts/oidc.sh` | New file, in a new folder `infra/scripts/`: publish the two documents, or check them |
| `Makefile` | `oidc-publish` and `oidc-check` |

**Why a script, and not Terraform objects.** The documents come from the running cluster: the API
server generates them from the key. The pattern is the same as the secrets: Terraform creates the empty
container, a command puts the value in. The script refuses to overwrite a document that differs, because
a difference means the key changed. Overwriting it would quietly move every role to the new key.

**Laptop.** Create `infra/scripts/oidc.sh`:
```bash
#!/usr/bin/env bash
# The two issuer documents AWS reads, compared with what the API server serves (app guide step 5).
#   bash infra/scripts/oidc.sh publish <bucket> <issuer-url>   upload whichever is missing
#   bash infra/scripts/oidc.sh check   <bucket> <issuer-url>   only compare
# kubectl goes through `make tunnel`. The bucket's policy lets anyone read exactly these two keys.
set -euo pipefail

mode=$1
bucket=$2
issuer=$3
keys=(".well-known/openid-configuration" "openid/v1/jwks")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# What the API server serves, with the keys sorted so that two copies compare equal.
kubectl get --raw /.well-known/openid-configuration | jq -S . > "$work/0.json"
kubectl get --raw /openid/v1/jwks | jq -S . > "$work/1.json"

served=$(jq -r .issuer "$work/0.json")
if [ "$served" != "$issuer" ]; then
  echo "The API server's issuer is $served, expected $issuer. The cluster needs app guide step 4." >&2
  exit 1
fi

status=0
for i in 0 1; do
  key=${keys[$i]}
  if published=$(curl -fsS "$issuer/$key" 2>/dev/null); then
    if diff <(jq -S . <<<"$published") "$work/$i.json" >/dev/null; then
      echo "same       $key"
    else
      # The key changed. Publishing would move every role to the new key: find out why first.
      echo "DIFFERENT  $key" >&2
      status=1
    fi
  elif [ "$mode" = publish ]; then
    # --if-none-match: refuse to overwrite, even if the object appeared since the check above.
    aws s3api put-object \
      --bucket "$bucket" \
      --key "$key" \
      --body "$work/$i.json" \
      --content-type application/json \
      --if-none-match '*' >/dev/null
    echo "published  $key"
  else
    echo "MISSING    $key" >&2
    status=1
  fi
done
exit "$status"
```

In `Makefile`, add at the end:
```make


# --- Workload identity: the issuer documents AWS reads (app guide step 5) -----------------------
OIDC_BUCKET = $(PROJECT)-oidc-$(ACCOUNT_ID)
OIDC_ISSUER = https://$(OIDC_BUCKET).s3.$(REGION).amazonaws.com

.PHONY: oidc-publish oidc-check

# Upload the discovery document and the key set if they are missing. Needs `make tunnel`.
oidc-publish:
	bash infra/scripts/oidc.sh publish $(OIDC_BUCKET) $(OIDC_ISSUER)

# After every rebuild: the published key set must still be the one the cluster signs with.
oidc-check:
	bash infra/scripts/oidc.sh check $(OIDC_BUCKET) $(OIDC_ISSUER)
```
The recipe lines start with a **tab**, like every other target in the file.

**Check before**, on the laptop: `git status --short` shows exactly ` M Makefile` and `?? infra/scripts/`.
Git lists a new folder, not the file inside it.

**Commit and push** (`git add infra/scripts/oidc.sh Makefile`, message `Publish the service-account
issuer documents`). Then on the workstation, after `git pull`:
```bash
bash -n infra/scripts/oidc.sh && echo syntax-ok
make -n oidc-publish
```
`syntax-ok`, then one line that starts with `bash infra/scripts/oidc.sh publish medical-rag-oidc-` and
ends with the issuer URL.

> **Shared state.** Publishing makes these documents what AWS trusts. First confirm there is nothing
> published yet:
> ```bash
> make oidc-check
> ```
> Expected: `MISSING` twice, then make's `Error 1`. If `same` appears, the documents are already there:
> skip `make oidc-publish` and go to the check. If `DIFFERENT` appears, **stop**: see troubleshooting.

```bash
make oidc-publish
```
Expected:
```
published  .well-known/openid-configuration
published  openid/v1/jwks
```

**Check:**
```bash
ISSUER=$(terraform -chdir=infra/terraform/shared output -raw oidc_issuer_url)
make oidc-check
curl -s "$ISSUER/.well-known/openid-configuration" | jq -r .issuer
make oidc-publish
```
1. `make oidc-check` prints two `same` lines and ends without an error.
2. The public URL returns the issuer itself.
3. A second `make oidc-publish` prints two `same` lines: it is safe to run again.

---

## Step 6 — The OIDC provider and three roles

**Goal:** IAM trusts the issuer. Three roles each accept a token only from their own ServiceAccount.

**The cluster from step 4 stays up until step 9 is done**: steps 6, 7 and 9 use kubectl, and steps 8 and 9
change the running cluster stack. If it was taken down in between, rebuild first (`make infra`,
`make cluster`, `make bootstrap`). Then `make oidc-check` must print two `same` lines.

| Role | Assumed by | May |
|---|---|---|
| `medical-rag-app-dev` | `medical-rag-dev:medical-rag` | list and read `faiss/*` |
| `medical-rag-app-prod` | `medical-rag-prod:medical-rag` | list and read `faiss/*` |
| `medical-rag-index-builder` | `medical-rag-{dev,prod}:medical-rag-index-builder` | read `corpus/*` and `faiss/*`, write `faiss/*`; never delete |

| File | Change |
|---|---|
| `infra/terraform/shared/irsa.tf` | New file: the provider, the roles and their permissions |

**Laptop.** Create `infra/terraform/shared/irsa.tf`:
```hcl
# IAM roles for the app's own pods (app guide step 6). IAM trusts tokens from the cluster's issuer
# (oidc.tf). Each role accepts a token only for one named ServiceAccount in one named namespace, and only
# when the token is meant for AWS (audience sts.amazonaws.com).

# No thumbprint: IAM checks the issuer's TLS certificate, from S3, against its own trusted CAs. IAM
# contacts the issuer host here, and STS fetches the published documents (step 5) on every token exchange.
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = local.oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # Role name suffix => the ServiceAccounts ("namespace:name") allowed to assume it.
  irsa_roles = {
    app-dev       = ["medical-rag-dev:medical-rag"]
    app-prod      = ["medical-rag-prod:medical-rag"]
    index-builder = ["medical-rag-dev:medical-rag-index-builder", "medical-rag-prod:medical-rag-index-builder"]
  }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Only tokens minted for AWS, not the ordinary tokens pods use against the API server.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only these ServiceAccounts. A pod in another namespace, or with another ServiceAccount, is refused.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for sa in each.value : "system:serviceaccount:${sa}"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = local.irsa_roles

  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json
}

# Serving pods: download an index version, nothing else.
data "aws_iam_policy_document" "index_read" {
  statement {
    sid       = "ListIndexVersions"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["faiss/*"]
    }
  }

  statement {
    sid       = "ReadIndexVersions"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/*"]
  }
}

# The index build Job: read the corpus and the existing versions, write a new version. No delete, so a
# bad build can add objects but never remove one (and the bucket keeps old versions anyway).
data "aws_iam_policy_document" "index_build" {
  statement {
    sid       = "ListCorpusAndIndex"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["faiss/*", "corpus/*"]
    }
  }

  statement {
    sid       = "ReadCorpusAndIndex"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/*", "${aws_s3_bucket.artifacts.arn}/corpus/*"]
  }

  # index.faiss is large enough for a multipart upload; Abort lets a failed upload clean up its parts.
  statement {
    sid       = "WriteIndexVersions"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/*"]
  }

  # The cluster pins every version and never moves the LATEST pointer. This makes that a rule IAM enforces,
  # not only a setting (INDEX_UPDATE_LATEST=false).
  statement {
    sid       = "NeverMoveLatest"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/faiss/LATEST"]
  }
}

resource "aws_iam_role_policy" "irsa" {
  for_each = local.irsa_roles

  name   = "${local.name}-${each.key}"
  role   = aws_iam_role.irsa[each.key].id
  policy = each.key == "index-builder" ? data.aws_iam_policy_document.index_build.json : data.aws_iam_policy_document.index_read.json
}

output "irsa_role_arns" {
  value = { for k, r in aws_iam_role.irsa : k => r.arn }
}
```

**Why:**

- **`s3:ListBucket` with a prefix condition.** The app looks for `faiss/<version>/` by listing that
  prefix. The condition keeps the listing inside `faiss/`.
- **Two roles for serving, one for building.** A serving pod takes internet traffic, so it can only
  read. Writing to the bucket is left to the short-lived Job.
- **The roles live in the shared stack.** They reference only the long-lived provider and the artifacts
  bucket, and they must survive `make down`.

**Check before:** on the laptop, `git status --short` shows only `?? infra/terraform/shared/irsa.tf`. On
the workstation, `make oidc-check` prints two `same` lines.

**Commit and push** (`git add infra/terraform/shared/irsa.tf`, message `Add the OIDC provider and the
app's IAM roles`), `git pull`, then:
```bash
make shared
```
Expect **7 to add, 0 to change, 0 to destroy**: one provider, three roles, three inline policies. Then
type `yes`. Anything else: type `no` and stop.

**Check:**
```bash
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text
aws iam get-role \
  --role-name medical-rag-app-dev \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' \
  --output json
```
1. One provider ARN ending in `oidc-provider/medical-rag-oidc-<account>.s3.ap-southeast-1.amazonaws.com`.
2. A `StringEquals` block with two keys:
   - `medical-rag-oidc-<account>.s3.ap-southeast-1.amazonaws.com:aud` = `sts.amazonaws.com`
   - `…:sub` = `system:serviceaccount:medical-rag-dev:medical-rag`

---

## Step 7 — Prove it with a pod

**Goal:** show, on the real cluster, that the whole chain works and that each boundary holds. Parts 3 and
4 are built on this, so they are not written until every check here passes. Steps 8 and 9 go on only
after it passes too.

Nothing is committed in this step. Everything is created with kubectl and deleted at the end.

**Set up.** The aws-cli image is the same version as the CLI on the workstation, so the tag is known to
exist:
```bash
ACC=$(aws sts get-caller-identity --query Account --output text)
ARTIFACTS=medical-rag-artifacts-$ACC
AWSCLI=$(aws --version | cut -d' ' -f1 | cut -d/ -f2)
echo "$AWSCLI"
kubectl create namespace medical-rag-dev
kubectl -n medical-rag-dev create serviceaccount medical-rag
kubectl -n medical-rag-dev create serviceaccount other
```

Write two pods into a file and apply it. The first runs as `medical-rag`, the second as `other`. Both
carry exactly what the chart will add later: a token for AWS, and three variables pointing the SDK at it.
```bash
cat > /tmp/irsa-proof.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: irsa-proof
  namespace: medical-rag-dev
  labels:
    app: irsa-proof
spec:
  serviceAccountName: medical-rag
  restartPolicy: Never
  securityContext:
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
  containers:
    - name: aws
      image: public.ecr.aws/aws-cli/aws-cli:${AWSCLI}
      command: ["sleep", "1800"]
      env:
        - name: AWS_ROLE_ARN
          value: arn:aws:iam::${ACC}:role/medical-rag-app-dev
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/aws/token
        - name: AWS_REGION
          value: ap-southeast-1
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
        - name: HOME
          value: /tmp
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
---
apiVersion: v1
kind: Pod
metadata:
  name: irsa-proof-other
  namespace: medical-rag-dev
  labels:
    app: irsa-proof
spec:
  serviceAccountName: other
  restartPolicy: Never
  securityContext:
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
  containers:
    - name: aws
      image: public.ecr.aws/aws-cli/aws-cli:${AWSCLI}
      command: ["sleep", "1800"]
      env:
        - name: AWS_ROLE_ARN
          value: arn:aws:iam::${ACC}:role/medical-rag-app-dev
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/aws/token
        - name: AWS_REGION
          value: ap-southeast-1
        - name: AWS_STS_REGIONAL_ENDPOINTS
          value: regional
        - name: HOME
          value: /tmp
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
EOF
kubectl apply -f /tmp/irsa-proof.yaml
kubectl -n medical-rag-dev wait pod/irsa-proof pod/irsa-proof-other --for=condition=Ready --timeout=3m
```
Expected: `pod/irsa-proof condition met` and `pod/irsa-proof-other condition met`.

Save typing with a function. `E` runs a command in the first pod:
```bash
E() { kubectl -n medical-rag-dev exec irsa-proof -- "$@"; }
```

**7.1 — The pod gets the app role:**
```bash
E aws sts get-caller-identity --query Arn --output text
```
Expected: `arn:aws:sts::<account>:assumed-role/medical-rag-app-dev/botocore-session-<digits>`.

If the ARN contains `medical-rag-nodes`, the SDK ignored the token and fell back to the node role through
IMDS. **Stop**: that is the failure this part exists to remove. See troubleshooting.

**7.2 — It can list the index prefix:**
```bash
E aws s3api list-objects-v2 --bucket "$ARTIFACTS" --prefix faiss/ --max-items 5 --query 'Contents[].Key'
```
Expected: no error. It prints `null` if `faiss/` is still empty, or a list of keys.

**7.3 — It cannot list anything else:**
```bash
E aws s3api list-objects-v2 --bucket "$ARTIFACTS" --prefix corpus/ --max-items 5
```
Expected: `An error occurred (AccessDenied) when calling the ListObjectsV2 operation`. The message names
`assumed-role/medical-rag-app-dev`.

**7.4 — It cannot write:**
```bash
E aws s3api put-object --bucket "$ARTIFACTS" --key faiss/irsa-proof --body /etc/hostname
```
Expected: `An error occurred (AccessDenied) when calling the PutObject operation`, naming the same role.

**7.5 — Another ServiceAccount is refused:**
```bash
kubectl -n medical-rag-dev exec irsa-proof-other -- aws sts get-caller-identity
```
Expected: `An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation: Not
authorized to perform sts:AssumeRoleWithWebIdentity`. The `sub` condition works.

**7.6 — IMDS is reachable now, and a NetworkPolicy closes it:**
```bash
E timeout 3 bash -c 'echo > /dev/tcp/169.254.169.254/80'; echo "exit=$?"
```
Expected: `exit=0`. Any pod can reach the node's metadata service today.

Apply the egress policy the chart will carry, selecting the proof pods only. It allows DNS to CoreDNS,
and TCP 443 anywhere except IMDS:
```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: irsa-proof-egress
  namespace: medical-rag-dev
spec:
  podSelector:
    matchLabels:
      app: irsa-proof
  policyTypes:
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
EOF
E timeout 3 bash -c 'echo > /dev/tcp/169.254.169.254/80'; echo "exit=$?"
E aws sts get-caller-identity --query Arn --output text
```
Expected: `exit=124` (the connection timed out), then the same `medical-rag-app-dev` ARN as in 7.1. The
ARN may come from credentials the CLI cached before the policy, so repeat 7.2 as well: it must still list
without an error. That is a fresh request to S3, made with IMDS closed.

**Clean up:**
```bash
kubectl delete namespace medical-rag-dev
rm /tmp/irsa-proof.yaml
```
The namespace comes back in Part 3, created by Argo CD.

**Record** the output of 7.1 to 7.6.

**Still to prove, at the next rebuild.** You do not need an extra rebuild for this. The next time the
cluster is rebuilt for any reason, run `make oidc-check` after `make bootstrap`. Expected: two `same`
lines. That proves a new cluster signs with the same key, so nothing has to be published again.

---

## Step 8 — One secret per environment for the app

**Goal:** dev and prod read their API keys and their Flask session key from separate secrets, so either
can be replaced without touching the other.

| File | Change |
|---|---|
| `infra/terraform/shared/secrets.tf` | `medical-rag/app-dev` and `medical-rag/app-prod` |
| `infra/terraform/cluster/main.tf` | The nodes may read the two (External Secrets copies them into each namespace) |
| `infra/terraform/cluster/iam.tf` | One comment: the count of read-only secrets |

**Laptop.** In `infra/terraform/shared/secrets.tf`, **replace** the `for_each` line of
`resource "aws_secretsmanager_secret" "app"`, including its trailing `# medical-rag/llm: …` comment, with:
```hcl
  # medical-rag/llm: Gemini + HF keys. medical-rag/github: bot token.
  # medical-rag/app-dev and medical-rag/app-prod: GOOGLE_API_KEY, HUGGINGFACEHUB_API_TOKEN and
  # FLASK_SECRET_KEY for each environment, replaced independently (app guide step 8).
  for_each = toset(["llm", "github", "app-dev", "app-prod"])
```
In `infra/terraform/cluster/main.tf`, **replace** the block `data "aws_secretsmanager_secret" "app"`:
```hcl
data "aws_secretsmanager_secret" "app" {
  for_each = toset(["llm", "github", "rancher", "rancher-tls", "alertmanager", "wildcard-tls", "app-dev", "app-prod"])
  name     = "${var.project}/${each.key}"
}
```

In `infra/terraform/cluster/iam.tf`, in the comment above `BackupWildcardCertificate`, change `the other
five stay read-only` to `the others stay read-only`.

**Why the node role, when the rest of this part moves away from it.** External Secrets still runs with
the node role, like every platform component. The app's pods never call Secrets Manager: they get a
Kubernetes Secret, and IMDS is closed to them. Giving External Secrets its own role is a later
improvement (see the [README](../README.md#what-still-uses-the-node-role)).

**Check before:** `git status --short` shows exactly the three files.

**Commit and push** (`git add infra/terraform/shared/secrets.tf infra/terraform/cluster/main.tf
infra/terraform/cluster/iam.tf`, message `Add one app secret per environment`), `git pull`, then, in
this order, because the cluster looks the secrets up by name:
```bash
make shared
make infra
```
- `make shared`: **2 to add, 0 to change, 0 to destroy**.
- `make infra`: **0 to add, 1 to change, 0 to destroy**. The change is the nodes' inline policy. If it
  plans dozens of additions, the cluster is down: type `no` and see the note at the top of step 6.

For either plan, anything else: type `no` and stop.

> **Shared state.** Fill each secret only if it is still empty:
> ```bash
> aws secretsmanager describe-secret --secret-id medical-rag/app-dev --query VersionIdsToStages
> aws secretsmanager describe-secret --secret-id medical-rag/app-prod --query VersionIdsToStages
> ```
> Expected: `null` twice. Otherwise **stop**. A value is already there, and this step would overwrite it.

Both start with the keys you already stored in `medical-rag/llm`. Replace them per environment
later: the Flask key above all, so a session cookie from one environment is useless in the other.
```bash
umask 077
aws secretsmanager get-secret-value \
  --secret-id medical-rag/llm \
  --query SecretString \
  --output text > /dev/shm/app.json
jq -c 'keys' /dev/shm/app.json
```
Expected: `["FLASK_SECRET_KEY","GOOGLE_API_KEY","HUGGINGFACEHUB_API_TOKEN"]`. If a key is missing, add
it to `medical-rag/llm` first ([runbook](../../runbook.md) §3), then repeat.
```bash
aws secretsmanager put-secret-value --secret-id medical-rag/app-dev --secret-string file:///dev/shm/app.json
aws secretsmanager put-secret-value --secret-id medical-rag/app-prod --secret-string file:///dev/shm/app.json
shred -u /dev/shm/app.json
umask 022
```

**Check:**
```bash
aws secretsmanager get-secret-value --secret-id medical-rag/app-dev --query SecretString --output text | jq -c keys
aws secretsmanager get-secret-value --secret-id medical-rag/app-prod --query SecretString --output text | jq -c keys
```
Each `put-secret-value` printed JSON with a `VersionId` and `"VersionStages": ["AWSCURRENT"]`. The same
three key names, twice. New baselines: 34 managed resources in `shared`, 88 in `cluster`
(`terraform -chdir=infra/terraform/shared state list | wc -l` prints `34`).

---

## Step 9 — Take the artifacts bucket away from the node role

**Goal:** the payoff. The only pods that can read the index are the ones with a role for it, and no pod
on the node can write to the bucket through IMDS.

| File | Change |
|---|---|
| `infra/terraform/cluster/iam.tf` | The two S3 statements cover the cluster's own buckets only |
| `infra/terraform/cluster/main.tf` | The lookup of the artifacts bucket goes: nothing uses it any more |

**Laptop.** In `infra/terraform/cluster/iam.tf`, **replace** everything from the comment line
`# Listing a bucket and reading its objects are different permissions…` down to the closing `}` of
`S3ReadWriteObjects` with:
```hcl
  # The cluster's own buckets: etcd snapshots and the Ansible transfer bucket. The artifacts bucket is not
  # here: the app's pods reach it through their own roles (shared/irsa.tf, app guide step 6).
  statement {
    sid       = "S3ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [for b in aws_s3_bucket.this : b.arn]
  }

  statement {
    sid       = "S3ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for b in aws_s3_bucket.this : "${b.arn}/*"]
  }
```
In `infra/terraform/cluster/main.tf`, delete the block `data "aws_s3_bucket" "artifacts" { … }` (three
lines).

**Check before**, on the laptop in Git Bash:
```bash
git status --short
grep -rn 'aws_s3_bucket.artifacts' infra/terraform/cluster/
```
Two modified files, and the `grep` prints nothing.

**Commit and push** (`git add infra/terraform/cluster/iam.tf infra/terraform/cluster/main.tf`, message
`Remove the artifacts bucket from the node role`), `git pull`, then:
```bash
make infra
```
Expect **0 to add, 1 to change, 0 to destroy**, and only S3 ARNs change inside the inline policy. Then
type `yes`. Anything else: type `no` and stop.

**Check:** a pod without any role of its own now gets nothing from the bucket. In a new shell, set the
variables first:
```bash
ACC=$(aws sts get-caller-identity --query Account --output text)
ARTIFACTS=medical-rag-artifacts-$ACC
AWSCLI=$(aws --version | cut -d' ' -f1 | cut -d/ -f2)
kubectl run node-role-check \
  --rm -i \
  --restart=Never \
  --image="public.ecr.aws/aws-cli/aws-cli:$AWSCLI" \
  -- s3api list-objects-v2 --region ap-southeast-1 --bucket "$ARTIFACTS" --prefix faiss/ --max-items 1
```
Expected: `AccessDenied`, and the message names `assumed-role/medical-rag-nodes/`. Then repeat
step 7 up to 7.2, and delete the namespace again. The app role still reads `faiss/`. Node role and app
role have now separated.

---

[Index](../guide.md) · [Next: Part 2 →](2-image-and-index.md) · [Troubleshooting](troubleshooting.md)
