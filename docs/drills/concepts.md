# Drills — Concepts

Everything this phase uses, explained once. Read a section before the step that needs it; the
[guide](guide.md) names which.

The phase builds three controls and proves each one by making the bad thing happen on purpose:

| Control | The bad thing | What the drill measures |
|---|---|---|
| etcd snapshots to S3 | A namespace is deleted | **RTO** — how long until every Application is `Healthy` again |
| Kyverno `verifyImages` | An unsigned image is deployed to prod | The **admission error** the API server returns |
| `upgrade.yml`, one node at a time | Kubernetes changes version while traffic flows | The **number of failed requests** |

That pairing is the point. The Jenkins phase ended with five checks that had passed while the thing they
guarded was broken, and the lesson written down was that *a check that cannot fail is worse than no check*. A
backup nobody has restored, a policy nobody has tripped, and an upgrade nobody has run under load are all that
same shape. Each step below therefore ends by breaking something.

---

## 1. etcd, and why a snapshot is not a volume backup

**What it is.** etcd is the only place a Kubernetes cluster keeps state. Every object you have ever applied —
Deployments, Secrets, the Argo CD Applications, the ServiceAccounts — is a key in etcd. The API server holds
nothing of its own; restart it and it reads everything back from etcd. Lose etcd and the cluster is an empty
cluster with your nodes still attached.

**How it runs here.** Three members, one per node, started by kubeadm as **static pods** — the kubelet reads
`/etc/kubernetes/manifests/etcd.yaml` off disk and runs what it finds, with no API server involved. That is
what makes recovery possible: the thing that stores the cluster does not need the cluster to start.

The three members elect a leader and replicate. Two of three is a quorum, so **one node can be lost with no
data loss and no downtime** — that is the row in the design's failure table. Two lost and the cluster stops
accepting writes.

**Why a volume snapshot is not enough.** You could take an EBS snapshot of the disk holding `/var/lib/etcd`.
It would be a crash-consistent copy of a database mid-write, taken at three slightly different instants on
three nodes. etcd's own `snapshot save` instead asks a running member for a **consistent point-in-time view**
and writes a single file with a checksum. One file, one instant, verifiable.

**Where it appears here.** A CronJob every six hours writes that file to S3.

**What breaks without it.** Nothing, until the day something deletes objects at scale — a wrong `kubectl
delete`, a bad Argo CD prune, a corrupted member. Then the whole cluster has to be rebuilt from Git, which
this project can do, but everything *not* in Git is gone: Jenkins build history, the Grafana admin password,
anything anyone created by hand.

---

## 2. `snapshot save`, `snapshot status`, `snapshot restore`

Three commands, and the middle one is the one people skip.

**Two binaries, not one.** `snapshot status` and `snapshot restore` moved out of `etcdctl` into `etcdutl`
in etcd 3.5 and were **removed** from `etcdctl` in 3.6. This cluster runs **3.6.8**, so only `save` is an
`etcdctl` command; the other two are `etcdutl`. Both binaries ship in the etcd image kubeadm already runs.

**`etcdctl snapshot save FILE`** connects to a member over TLS on port 2379 and streams a consistent copy.

**`etcdutl snapshot status FILE`** reads the file back and prints its hash, revision, total keys and size. It
is the difference between "the upload succeeded" and "the upload succeeded and the file is a valid snapshot".
A truncated or empty file uploads perfectly happily. This is the step that makes the backup a backup, and the
design names it explicitly: *"`snapshot status` is verified before upload."*

**`etcdutl snapshot restore FILE`** does **not** write into a running member. It expands the snapshot into a
*new* data directory on disk. Restoring is therefore not one command but a procedure:

1. Stop the API server and etcd on every node — by moving their static-pod manifests out of
   `/etc/kubernetes/manifests/`, which makes the kubelet tear them down.
2. Move the old `/var/lib/etcd` aside on all three.
3. Run `etcdutl snapshot restore` on each node, each with **its own** `--name` and
   `--initial-advertise-peer-urls`, the same `--initial-cluster` list and the same `--initial-cluster-token`,
   and an explicit `--data-dir` — you are recreating a three-member cluster, not copying one member's disk.
   Without `--data-dir` it writes `./<name>.etcd` and the kubelet then starts etcd on an empty directory.
4. Move the manifests back. The kubelet starts etcd, the members find each other, the API server comes up.

**Why all three, not one.** The members would otherwise disagree about history. A member restored from the
snapshot and two members still holding the newer state cannot form one cluster; etcd either refuses or one
side wins and you have silently lost data. Restoring all three from the same file makes them agree by
construction.

**The certificates.** All of this needs `/etc/kubernetes/pki/etcd/ca.crt`, `server.crt` and `server.key`.
Client traffic to etcd is TLS on **2379** and stays that way; only the metrics listener was moved to plain
HTTP on 2381, which is a separate, deliberate choice recorded as a limit in the GitOps phase.

---

## 3. RTO and RPO

Two numbers, often confused, and the drill measures one of them.

**RPO — recovery point objective** — how much data you are willing to lose, measured backwards from the
failure. It is set by how often you take a snapshot. Every six hours means **up to six hours of cluster state**
can be lost: any object created after the last snapshot is not in it.

**RTO — recovery time objective** — how long the recovery takes, measured forwards from the decision to
restore. This is what criterion #12 asks for, and it is measured to the moment **every Argo CD Application is
`Healthy` again**, not to the moment etcd starts. A cluster whose etcd is up but whose workloads have not
reconciled is not recovered.

Writing both down matters more than either number being small. "We lose at most six hours and take N minutes
to come back" is an operational statement; "we have backups" is not.

---

## 4. Admission control, and where Kyverno sits

Every request to the API server — `kubectl apply`, an Argo CD sync, a Deployment creating a Pod — passes
through the same path:

```
authentication  →  authorisation (RBAC)  →  mutating admission  →  schema validation  →  validating admission  →  etcd
```

**Authorisation answers "may this identity do this at all?"** RBAC cannot see *inside* the object. It can say
"Argo CD may create Deployments in `medical-rag-prod`"; it cannot say "but only if the image is signed".

**Admission controllers answer "is this particular object acceptable?"** They receive the whole object and
return allow or deny. Two kinds:

- **Mutating** ones may change the object — this is how a sidecar gets injected.
- **Validating** ones may only accept or refuse.

Kyverno registers as both. This phase uses only the validating half.

**What this project already has.** A `ValidatingAdmissionPolicy` in `deploy/argocd/manifests/jenkins/` — built
into Kubernetes, nothing installed — which refuses host paths and privileged containers in the build
namespace. It shows the mechanism but not the reach: expressing "verify this image's signature against a
public key" needs more than CEL.

**What breaks without Kyverno.** The pipeline signs every image built on `main` with a KMS key, and **nothing
reads the signature**. The Jenkins README says so in its own limits table. A signature nobody verifies buys
almost nothing: it proves an image *could* be checked, not that any image *was*.

There is a sharper version of that gap worth holding in mind. The skip guard ends any build whose commit
touched only `deploy/`. A digest hand-edited into `deploy/envs/prod/values.yaml` is therefore never built,
never scanned, never signed — and today nothing downstream objects. The whole pipeline can be walked around
with one file edit. Admission control is what closes it.

---

## 5. Verifying a signature: by key, or by log

Cosign can prove an image's provenance two ways, and this project deliberately uses only one.

**By key.** The signer holds a private key; the verifier holds the matching public key. Here the private half
is an asymmetric KMS key (`ECC_NIST_P256`, `SIGN_VERIFY`) that never leaves AWS — the pipeline asks KMS to
sign and KMS returns a signature. Verification needs only the **public** half, which is not secret and can sit
in Git.

**By transparency log.** Cosign can also upload a record to Rekor, a public append-only log, so anyone can see
that a given digest was signed at a given time. Useful for public artifacts; wrong here. These images are
private, so their digests, repository name and account id have no business in a public log, and the pipeline
creates a signing config that names no services at all.

**What this means for Kyverno.** The policy must use a **static public key** attestor and must have
transparency-log verification turned off, because there is no log entry to find. Two shapes exist for getting
that key to the cluster:

- a PEM checked into Git and read by the policy — no AWS call at admission time, and the key is public, so
  Git is the right place for it;
- a `kms:` attestor where Kyverno itself calls `kms:GetPublicKey` — which would need an IAM grant that **no
  identity in this cluster currently has**, because the Jenkins phase removed KMS from the node role
  entirely.

This phase takes the first. It is fewer moving parts and it keeps admission working even if AWS is
unreachable.

---

## 6. `kubeadm upgrade apply` and `kubeadm upgrade node`

A kubeadm cluster is upgraded in two different ways depending on which node you are standing on.

**`kubeadm upgrade apply vX.Y.Z`** runs on the **first** control plane. It upgrades the cluster-wide pieces:
it writes new static-pod manifests for the API server, controller manager, scheduler and etcd, renews
certificates if needed, and records the new version in the cluster. It is the only command that decides what
the cluster's version *is*.

**`kubeadm upgrade node`** runs on **every other** control plane. It reads the decision the first node already
made and brings that node's static pods in line. It does not choose a version.

Neither touches the kubelet. The kubelet is an apt package and is upgraded separately, then restarted.

**Why the packages are held.** The Ansible role marks `kubelet`, `kubeadm` and `kubectl` as `hold` in dpkg, so
a routine `apt upgrade` can never move them. An upgrade playbook has to ask for the exception deliberately.
The role's own comment says why: *"Upgrades are done deliberately, one node at a time."*

**A trap worth knowing.** `kubeadm_init` re-templates `/etc/kubernetes/kubeadm-config.yaml` on every run, and
that file carries `kubernetesVersion`. Changing the pinned version and re-running `site.yml` will therefore
rewrite that file **and upgrade nothing** — the cluster keeps running the old binaries while a config file on
disk claims otherwise. Only `kubeadm upgrade` changes what actually runs.

---

## 7. cordon, drain, and the disruption budget

**`cordon`** marks a node unschedulable. Nothing new lands there; what is already running stays.

**`drain`** cordons *and* evicts. Eviction is not deletion: it goes through the API server, which consults
each Pod's **PodDisruptionBudget** before allowing it. A PDB says "at least N of these must stay available",
and the API server will **block** an eviction that would violate it — the drain waits rather than breaking the
service.

This is what makes a rolling upgrade safe, and it is why the drill is worth running under load: the prod
Deployment has two replicas spread across nodes and a PDB allowing one disruption. If the spread or the PDB
were wrong, a drain would take both replicas at once and the `curl` loop would count the failures. That is the
measurement.

**`uncordon`** puts the node back in the pool. Forgetting it is the classic way to end an upgrade with a
healthy cluster that is quietly running on two nodes.

---

## 8. Why each control is paired with a drill

Three claims this phase could have made without proving any of them: *we back up etcd*, *we verify image
signatures*, *we can upgrade safely*. All three would be true in the sense that the machinery exists, and all
three would be untested.

The distinction is not pedantry. Each of the three has a specific way of being silently broken:

- A snapshot that uploads but cannot be restored — wrong certificates, a truncated file, a restore procedure
  that never rebuilt all three members.
- A policy that matches nothing — one wrong character in an image pattern and every image passes, with no
  error anywhere, because a policy that matches nothing also denies nothing.
- An upgrade playbook that works when nothing is running and takes the service down when something is.

Each is invisible until the day it matters. The drill is the only thing that turns *built* into *proven*, and
it is what every criterion in the design's §6 actually asks for.

---

[Guide](guide.md) · [Evidence](../evidence/drills.md) · [Design §4.6](../selfmanaged-k8s-ops-design.md)
