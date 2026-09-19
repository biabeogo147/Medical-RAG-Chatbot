# App guide — Part 1: An AWS identity for the app's own pods (steps 1–9)

[Index](../guide.md) · [Concepts](0-concepts.md) · [Next: Part 2 →](2-image-and-index.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** the GitOps phase is finished: after a rebuild every Application is `Synced` and
`Healthy`. The laptop has Git; everything else runs on the ops workstation.

**Done when:** a pod running as ServiceAccount `medical-rag` in `medical-rag-dev` gets the role
`medical-rag-app-dev`. It can read `faiss/*` in the artifacts bucket and nothing else. The same pod cannot
reach the instance metadata service. The node role can no longer read the artifacts bucket at all.

**Every step follows [the loop](../guide.md#the-loop-for-every-step).** Push only the files a step lists,
and run its **check before** first.

---

New terms in this part are explained in [Concepts](0-concepts.md). **Before step 1, read [the big picture](0-concepts.md#the-big-picture) and
concepts sections 1, 2 and 10** (about 10 minutes). The table at the end of this introduction says what to read
before each later step.

**The problem.** Today, AWS sees every pod on a node as the node itself. Any pod can ask the instance
metadata service (IMDS, the address `169.254.169.254`) for the node role's credentials ([concepts §1](0-concepts.md#1-iam-roles-and-temporary-credentials), [concepts §2](0-concepts.md#2-imds-and-the-hop-limit)). That role:

- reads the platform's secrets, including the wildcard certificate's private key;
- changes a DNS record;
- reads, writes and deletes in S3 buckets, including the one that holds the index;
- pushes to ECR, and signs with the cosign key.

The chatbot is the only pod that takes traffic from the internet. If an attacker took it over, they would
get all of that.

**Why a firewall rule alone does not fix it.** A NetworkPolicy can cut a pod off from IMDS ([concepts §11](0-concepts.md#11-networkpolicy-egress)). But the
app has to download its index from S3 when it starts, and IMDS is its only source of AWS credentials today.
Block IMDS, and the app cannot start. A NetworkPolicy also applies to a whole pod, so it cannot block the
app container and still let the init container through. The pod needs AWS credentials that do not come from
the node.

**The idea.** Give the app's pods their own IAM roles, the way Amazon EKS does with IRSA (IAM roles for
service accounts, [concepts §10](0-concepts.md#10-irsa-and-what-this-project-does-differently)). A pod proves who it is with a token that Kubernetes signs, and AWS exchanges that
token for a role made just for that pod. Four pieces make this work:

1. **A signing key that does not change.** The API server signs every ServiceAccount token with it ([concepts §4](0-concepts.md#4-serviceaccounts-and-their-tokens)).
   We store it in Secrets Manager, and Ansible installs it on every rebuild.
2. **A public issuer.** The issuer is the web address that says who made the token; the API server writes
   it into each token. We make it an S3 bucket AWS can read, and publish the public key there ([concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc)).
3. **An OIDC provider in IAM, and roles that trust it.** Each role accepts a token only for one named
   ServiceAccount in one named namespace ([concepts §8](0-concepts.md#8-the-iam-oidc-provider-and-trust-policies)).
4. **A pod that uses such a token.** The pod mounts a token meant for AWS ([concepts §7](0-concepts.md#7-projected-tokens-and-audiences)). Four `AWS_*` environment
   variables tell the AWS SDK to exchange it for the role ([concepts §3](0-concepts.md#3-how-the-aws-sdk-finds-credentials)).

**What Part 1 does, and what comes later.** Part 1 builds these four pieces and proves them with a test
pod. The app's permanent NetworkPolicy, which closes IMDS for real, comes with the chart in Part 3. That is
safe only because Part 1 gave the pod its own role first.

**No webhook.** On EKS, a webhook adds piece 4 to every pod. Upstream configures it to be skipped when it
is down: the pod then starts without the token, and quietly falls back to the node role. Only our own
chart needs piece 4, so the chart writes it itself ([concepts §10](0-concepts.md#10-irsa-and-what-this-project-does-differently)).

**How the nine steps build it:**

| Step | Builds | Read first |
|---|---|---|
| 1 | Nothing yet: checks that the public bucket can exist | [the big picture](0-concepts.md#the-big-picture), [concepts §1](0-concepts.md#1-iam-roles-and-temporary-credentials), [concepts §2](0-concepts.md#2-imds-and-the-hop-limit), [concepts §10](0-concepts.md#10-irsa-and-what-this-project-does-differently) |
| 2 | Piece 1: the stable key, stored in Secrets Manager | [concepts §4](0-concepts.md#4-serviceaccounts-and-their-tokens), [concepts §5](0-concepts.md#5-the-signing-key-pair) |
| 3 | Piece 2: the issuer's address, an S3 bucket | [concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc) |
| 4 | Pieces 1 and 2 inside the cluster: tokens carry the new issuer and the stable key | [concepts §7](0-concepts.md#7-projected-tokens-and-audiences) |
| 5 | Piece 2: the two issuer documents AWS reads | [concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc) |
| 6 | Piece 3: the OIDC provider and the three pod roles | [concepts §8](0-concepts.md#8-the-iam-oidc-provider-and-trust-policies), [concepts §9](0-concepts.md#9-sts-assumerolewithwebidentity-the-exchange), [concepts §12](0-concepts.md#12-scoping-s3-permissions) |
| 7 | Piece 4, by hand: a test pod proves the whole chain | [concepts §3](0-concepts.md#3-how-the-aws-sdk-finds-credentials), [concepts §11](0-concepts.md#11-networkpolicy-egress) |
| 8 | One app secret per environment | [concepts §13](0-concepts.md#13-secrets-manager-and-external-secrets) |
| 9 | The node role loses the artifacts bucket | [concepts §12](0-concepts.md#12-scoping-s3-permissions) | [concepts §12](0-concepts.md#12-scoping-s3-permissions) |

**Assumption until step 7.** Nothing in this part is proven until the pod in step 7 prints the right role
ARN. Parts 3 and 4 are written only after that.

---

## Step 1 — Read-only checks before anything is created

**Problem now.** Part 1 needs an S3 bucket that anyone on the internet can read ([concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc)). Two things outside this repository could make that impossible. S3 Block Public Access, a switch for the whole account, can forbid public bucket policies (a bucket policy is the JSON rule saying who may read a bucket). And the bucket's name could already be taken, because S3 names are global. If we skip this check, we only find out when `terraform apply` fails in step 3.

**Why it matters.** If public policies are blocked for the account, the design has to change: the issuer would have to sit behind CloudFront, AWS's content delivery network. That is much cheaper to learn before anything depends on the bucket.

**This step.** Three read-only AWS calls. Nothing is created.

**After this step.**
- Works: you know the bucket can be created. Nothing new exists yet.
- Proven by: `NoSuchPublicAccessBlockConfiguration` (or both flags `false`), `404` for the bucket name, and no `medical-rag-oidc` OIDC provider.
- Still missing: everything. The signing key comes first → step 2.

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

**Problem now.** The API server signs every ServiceAccount token ([concepts §4](0-concepts.md#4-serviceaccounts-and-their-tokens)) with a private key ([concepts §5](0-concepts.md#5-the-signing-key-pair)). kubeadm makes that key during `kubeadm init`, so every rebuild of the cluster makes a new one. AWS will check tokens against a public key that we publish once ([concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc)). After the next rebuild, tokens would be signed with a key AWS has never seen, and every role would refuse them.

**Why it matters.** With one key that never changes, the public key is published once and stays valid. That private key is also the most sensitive thing in this part: whoever holds it can write a token for any ServiceAccount, and so assume every role that trusts the cluster. It needs a home that only the workstation can read.

**This step.** Create an empty secret `medical-rag/sa-signer` with Terraform. Generate an RSA key pair in memory, store the private key in the secret, and check that it reads back.

**After this step.**
- Works: the key is stored, and the node role is not allowed to read it.
- Proven by: the round-trip prints `MATCH`, and `grep -n sa-signer infra/terraform/cluster/main.tf` prints nothing.
- Still missing: the running cluster still signs with kubeadm's own key (step 4), and there is no public place for the public key yet → step 3.

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
  already on disk is reused instead. kubeadm's output says `[certs] Using the existing "sa" key`, but
  Ansible shows a successful command's output only with `-v`.
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

**Problem now.** AWS checks a token like this: it reads the issuer address written in the token, then downloads two small files from that address ([concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc)). It does not log in to do this, so the address must be public on the internet. Today the issuer is `https://kubernetes.default.svc.cluster.local`, an address that exists only inside the cluster. AWS could never reach it.

**Why it matters.** The issuer address is permanent. It is written into every token, into an API server setting, and into every role's trust policy. So it needs a public HTTPS address that never disappears and that nobody else can take over ([concepts §5](0-concepts.md#5-the-signing-key-pair)).

**This step.** Create an S3 bucket whose web address becomes the issuer. Its policy lets anyone read exactly two files. It lives in the shared stack (`infra/terraform/shared`, which `make down` never destroys), and Terraform refuses to delete it.

**After this step.**
- Works: the address exists, and the bucket policy is public.
- Proven by: `"IsPublic": true`, and the address answers `403`. S3 answers `403`, not `404`, for a missing file when the caller may not list the bucket.
- Still missing: the two issuer documents (step 5), and the API server still writes the old issuer into its tokens → step 4.

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

**Problem now.** The key and the bucket exist, but the running API server knows neither. It signs with the key kubeadm made. It writes `iss: https://kubernetes.default.svc.cluster.local` into every token. And it tells callers to fetch the public keys from an address that exists only inside the cluster.

**Why it matters.** For AWS to trust a token, the token's `iss` must be the bucket's address, and its signature must come from the stable key ([concepts §5](0-concepts.md#5-the-signing-key-pair), [concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc)). This project sets both only at `kubeadm init`, and a guard refuses to swap the key under a running API server. So the change is a rebuild.

**This step.** Ansible copies the stored key to node 1 before `kubeadm init`. It also adds four API server settings:

- the bucket's address becomes the issuer written into new tokens (it is listed first);
- the old in-cluster issuer is still accepted, so a token that names it stays valid;
- the address of the key set points to the bucket;
- the list of audiences the API server accepts is written out in full ([concepts §7](0-concepts.md#7-projected-tokens-and-audiences)).

A guard stops `make cluster` if the running cluster uses a different key. Then the cluster is rebuilt.

**After this step.**
- Works: new tokens carry the S3 issuer and are signed with the stable key.
- Proven by:
  - the discovery document's `issuer` is the S3 address;
  - `sa.pub` has the same hash on all three nodes, equal to step 2's;
  - every Application is `Synced` and `Healthy`;
  - a second `make cluster` prints `All assertions passed` for the guard and `changed=0` for every node.
- Still missing: the bucket is still empty, so AWS cannot check a signature yet → step 5.

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
`make cluster` now shows `Validate the kubeadm configuration` as `ok` on node 1, followed by `Initialise
the control plane` as `changed`. Then, in window 1, stop the old tunnel with `Ctrl-C` (it points at a node that no
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
5. The guard on a running cluster passes. The output is long, so keep it in a file and look for the one
   task that matters:
   ```bash
   set -o pipefail
   make cluster 2>&1 | tee /tmp/cluster-2.log
   grep -A3 "Refuse to go on" /tmp/cluster-2.log
   grep -A5 "PLAY RECAP" /tmp/cluster-2.log
   ```
   `set -o pipefail` keeps make's exit status through `tee`: a failure before Ansible even starts (for
   example `terraform output`) then still shows as an error.
   Expected:
   - `grep` prints `ok: [medical-rag-node-1]` with `"msg": "All assertions passed"`.
   - The recap shows `failed=0` and `changed=0` for every node.

   `Put the signing key in place…` and `Derive the public half…` do not appear at all. They are skipped
   on a cluster that already exists, and `infra/ansible/ansible.cfg` hides skipped tasks
   (`display_skipped_hosts = False`). If `grep` prints nothing, the guard did not run: either node 1 has no
   `/etc/kubernetes/admin.conf`, or the play stopped before `kubeadm_init` (the recap shows `failed` or
   `unreachable` above 0). Stop and look at `/tmp/cluster-2.log`.

**Record** the issuer line and the three hashes.

---

## Step 5 — Publish the issuer documents

**Problem now.** Tokens now name the bucket as their issuer, but the bucket is empty. AWS would ask it for the discovery document, get `403`, and reject every token.

**Why it matters.** The two issuer documents are what lets a stranger check a token ([concepts §6](0-concepts.md#6-issuer-discovery-document-and-jwks-oidc)). They must be exactly what the API server serves. A copy made with the wrong key would make AWS reject every token, or trust the wrong key.

**This step.** A script copies the two issuer documents from the API server into the bucket. It refuses to overwrite a document that differs. `make oidc-check` compares them again after every rebuild.

**After this step.**
- Works: anyone, AWS included, can download the key set.
- Proven by: two `published` lines; then `make oidc-check` prints two `same` lines, and the public address returns the issuer.
- Still missing: IAM does not trust this issuer yet, and no role exists → step 6.

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

**Problem now.** AWS can now check a token's signature, but checking is not trusting. IAM accepts these tokens only from an issuer registered as an OIDC provider, and only for a role whose trust policy names that provider ([concepts §8](0-concepts.md#8-the-iam-oidc-provider-and-trust-policies)). Neither exists yet.

**Why it matters.** The trust policy decides which pod may use which role. A token for the ServiceAccount `medical-rag` in `medical-rag-dev` gets `medical-rag-app-dev` and nothing else. The app pods that answer users may only read. Only the Job that builds the index (Part 3) may write ([concepts §12](0-concepts.md#12-scoping-s3-permissions)).

**This step.** Terraform registers the OIDC provider for the issuer, with the audience `sts.amazonaws.com`. It creates the three pod roles (two app roles, one index-builder role), each with `aud` and `sub` conditions in its trust policy and a narrow permissions policy.

**After this step.**
- Works: a pod with the right token can, in principle, exchange it for its role ([concepts §9](0-concepts.md#9-sts-assumerolewithwebidentity-the-exchange)).
- Proven by: the provider's ARN is listed, and the trust policy of `medical-rag-app-dev` shows both conditions.
- Still missing: nothing has tried the exchange from a real pod → step 7.

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

**Problem now.** Steps 2–6 built every piece, but each was checked on its own. Nothing has yet run the whole chain from a real pod. The dangerous failure is silent. If the pod's `AWS_*` variables are missing or misspelt, the SDK quietly falls back to the node role through IMDS ([concepts §3](0-concepts.md#3-how-the-aws-sdk-finds-credentials)). The pod still reads S3 and everything looks fine, except that the ARN says `medical-rag-nodes`.

**Why it matters.** Parts 3 and 4 put every app pod on this chain. A silent fallback would leave the internet-facing pod with the node's permissions: the exact risk Part 1 prepares to remove ([concepts §2](0-concepts.md#2-imds-and-the-hop-limit), [concepts §11](0-concepts.md#11-networkpolicy-egress)).

**This step.** Two throwaway pods, one with the right ServiceAccount and one with a wrong one, and one NetworkPolicy. Then six checks. Nothing is committed. Parts 3 and 4 are written only after every check here passes.

**After this step.**
- Works: the pod gets the app role, can list `faiss/`, cannot list `corpus/`, cannot write, and another ServiceAccount is refused.
- Proven by:
  - 7.1 prints the `medical-rag-app-dev` ARN;
  - 7.2 lists `faiss/` without an error;
  - 7.3 and 7.4 print `AccessDenied`, naming that role;
  - 7.5 is refused (`AccessDenied` on `AssumeRoleWithWebIdentity`);
  - 7.6: with the NetworkPolicy, IMDS times out (`exit=124`, the exit code of `timeout`) while the S3 listing of 7.2 still works.
- Still missing: per-environment secrets (step 8), and the node role can still use the artifacts bucket → step 9.

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
carry exactly what the chart will add later: a token for AWS, and four `AWS_*` variables pointing the SDK
at it (plus `HOME`, so the CLI has a writable cache).
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

**Problem now.** The app's keys (Gemini, Hugging Face, and the Flask session key) sit in one secret, `medical-rag/llm`. Dev and prod would share them. Replacing a key for one environment would replace it for both, and a session cookie signed in dev would be accepted by prod.

**Why it matters.** Each environment should be replaceable on its own. Note that this step gives the node role *more* access, not less. That is fine: only External Secrets uses it to copy the values into the cluster ([concepts §13](0-concepts.md#13-secrets-manager-and-external-secrets)), and the app pods never see Secrets Manager.

**This step.** Two new secrets, `medical-rag/app-dev` and `medical-rag/app-prod`, in the shared stack. The node role may read them. Both start with the values of `medical-rag/llm`, and you replace them per environment later.

**After this step.**
- Works: each environment has its own secret.
- Proven by: each secret lists the same three key names.
- Still missing: both still hold the same values until you replace them. The node role can still read and write the artifacts bucket → step 9.

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

**Problem now.** The three pod roles give the app's pods new rights, but take nothing away from the node role. Any pod on a node can still read, overwrite and delete the index through IMDS. That includes the chatbot, until Part 3 adds its permanent NetworkPolicy ([concepts §2](0-concepts.md#2-imds-and-the-hop-limit)).

**Why it matters.** Once the node role loses the bucket, only pods with a role for it can touch the index, and only the index-builder role can write. Until then, a compromised pod can still read, overwrite and delete the index. The node role keeps its other permissions ([concepts §1](0-concepts.md#1-iam-roles-and-temporary-credentials)); those belong to the platform components.

**This step.** Remove the artifacts bucket from the node role's policy, and drop the `data` block that looked the bucket up, which nothing uses any more.

**After this step.**
- Works: the node role now reaches only the etcd-snapshot bucket and the Ansible transfer bucket.
- Proven by: a pod without a role of its own gets `AccessDenied` naming `medical-rag-nodes`, while the app role still lists `faiss/`.
- Still missing: nothing more in Part 1. The app has no image and no corpus in S3 → Part 2, step 10.

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
