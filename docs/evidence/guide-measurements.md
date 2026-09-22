# Measurements for the CV

Five measurements that turn the bracketed placeholders in the CV's Medical RAG entry into numbers. Each one
says what it proves, how it can pass falsely, and where its result is written. The reasoning behind the
etcd drill is in the [drills guide](../drills/guide.md) steps 9–11; this file only makes it runnable.
Results go in [`drills.md`](drills.md).

**Order is fixed.** M0 must happen before 06:00 UTC. M4 must happen before M3, because `make down` deletes
Jenkins's volume and with it every build record M4 reads.

| # | CV placeholder | When | Proves |
|---|---|---|---|
| [M0](#m0--something-to-lose) | — (enables M2) | **before 06:00 UTC** | The snapshot will contain data we can check for |
| [M4](#m4--a-build-the-gate-fails) | Trivy gate "proven by a failing build" | while waiting for 06:00 | The gate can go red, not only pass |
| [M1](#m1--the-first-scheduled-snapshot) | "integrity check before upload" | after 06:00 UTC | A scheduled snapshot exists and `etcdutl` read it |
| [M2](#m2--the-restore-drill) | **[RTO]**, RPO | after M1 | etcd can be restored, and the data comes back |
| [M3](#m3--a-timed-rebuild) | **[T]**, **[17]**, 0 issuances | after M2 | The whole platform comes back from nothing, in a measured time |

**Rules.** Every workstation command carries its own `cd`. Window 0 is for work, window 1 holds `make tunnel`.
On the laptop, `git pull --rebase` before every `git push`: the pipeline's bot commits to `main` after each
push. A step is done when its **Check** output appears, not when the command exits 0.

---

## M0 — Something to lose

**Workstation, window 0.** A namespace that is **not** in Git, so Argo CD cannot recreate it and the restore
is the only thing that can bring it back.
```bash
kubectl create namespace restore-drill
kubectl -n restore-drill create configmap canary --from-literal=written-at="$(date -u +%FT%TZ)"
kubectl -n restore-drill get configmap canary -o jsonpath='{.data.written-at}{"\n"}'
```
**Check.** One timestamp, **earlier than 06:00 UTC**. **Record** it: it is what the restored ConfigMap must show.

---

## M4 — A build the gate fails

Today the gate has only ever passed: every CRITICAL finding in the image has no fix, so it counts 0. A
positive control lowers the bar on a throwaway branch until the gate **must** fail.

**1. Workstation — read what the last `main` build found**, so you know the control will go red:
```bash
R=$(kubectl -n jenkins exec statefulset/jenkins -c jenkins -- sh -c 'find /var/jenkins_home/jobs/medical-rag/branches/main/builds -name trivy-report.json -printf "%T@ %p\n" | sort -n | tail -1 | cut -d" " -f2'); echo "$R"
kubectl -n jenkins exec statefulset/jenkins -c jenkins -- cat "$R" > /tmp/trivy.json
python3 -c 'import json,collections; r=json.load(open("/tmp/trivy.json")); print(dict(collections.Counter(v["Severity"] for x in r.get("Results",[]) for v in x.get("Vulnerabilities") or [] if v.get("FixedVersion"))))'
```
**Check.** `R` is a path ending in `archive/trivy-report.json` (empty means the path is different: run
`find /var/jenkins_home/jobs/medical-rag -name trivy-report.json` inside the pod instead), and the last line is
a count per severity such as `{'MEDIUM': 5, 'LOW': 1}`. **If it prints `{}`, stop**: nothing is fixable at any
severity, and the control cannot go red.

**2. Laptop — a branch whose gate counts fixable findings of every severity.** The name must match
`jenkins/step-*`: Jenkins discovers only `main` and that pattern (`deploy/argocd/values/jenkins.yaml`). In
`Jenkinsfile`, in the
`Scan` stage's gate: delete the line `| select(.Severity == "CRITICAL")` and change the echo text
`CRITICAL with a fix available:` to `Fixable, any severity:`. Nothing else.
```powershell
git switch -c jenkins/step-gate-control
git add Jenkinsfile
git commit -m "Positive control: count fixable findings of any severity (temporary branch, not for main)"
git push -u origin jenkins/step-gate-control
git switch main
```
**3. Jenkins UI (through the VPN)** → `medical-rag` → branch `jenkins/step-gate-control`. Wait for the build.

**Check.** The build is **red at `Scan`**, and its log shows `Fixable, any severity: N` with **N > 0** —
roughly step 1's sum; it can differ, because the branch image is rebuilt against a newer vulnerability
database. No later stage runs, because Scan failed; `SBOM and signature`, `Promote to dev` and
`Prod pull request` are `main`-only in any case.

**Record now**, before the branch goes: the build number, N, and the severities from step 1. The build
pushed a throwaway branch-tagged image into the `medical-rag` ECR repository; it is never signed or promoted,
and the lifecycle policy expires it.

**4. Laptop — remove the branch.**
```powershell
git branch -D jenkins/step-gate-control
git push origin --delete jenkins/step-gate-control
```
Write what you recorded into `drills.md` → *Measured for the CV*.
**Trap:** this proves the gate's **mechanism** fails a build. It does not show a CRITICAL was ever caught. CV
wording: "a Trivy gate verified by a positive-control build that fails it".

---

## M1 — The first scheduled snapshot

**Workstation, window 0**, after 06:00 UTC:
```bash
kubectl -n etcd-backup get cronjob etcd-snapshot
J=$(kubectl -n etcd-backup get jobs --sort-by=.metadata.creationTimestamp -o name | tail -1); echo "$J"
kubectl -n etcd-backup get "$J" -o jsonpath='start={.status.startTime} done={.status.completionTime} ok={.status.succeeded} manual={.metadata.annotations.cronjob\.kubernetes\.io/instantiate}{"\n"}'
kubectl -n etcd-backup logs "$J" --all-containers --prefix
aws s3 ls s3://medical-rag-etcd-backups-242834061265/snapshots/
```
**Check.**
- `ok=1`, `manual=` **empty** (the scheduler made it, not a person), and `start` later than M0's timestamp.
- The `status` container's table shows a hash, a **revision > 0** and **total keys > 0**.
- The `upload` line names the key. The S3 listing shows it at a size in MB, not bytes.

**Record** the duration (done − start), the size, and hash / revision / keys. **If the job failed**, record
why and stop: the next run is 12:00 UTC.

---

## M2 — The restore drill

Read [drills guide step 10](../drills/guide.md#step-10--the-restore-drill) once. The six phases each finish
on **all three nodes** before the next begins; a restored member rejoining a live quorum is the split brain
the guide warns about.

**Workstation, window 0. Set up and pre-check** (nothing is stopped yet):
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible && export A="ansible nodes -b -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=242834061265"
KEY=$(aws s3 ls s3://medical-rag-etcd-backups-242834061265/snapshots/ | sort | tail -1 | awk '{print $4}'); echo "$KEY"
aws s3 cp "s3://medical-rag-etcd-backups-242834061265/snapshots/$KEY" /tmp/snap.db && ls -l /tmp/snap.db
cd ~/Medical-RAG-Chatbot/infra/ansible && $A -m copy -a "src=/tmp/snap.db dest=/tmp/snap.db mode=0600"
cd ~/Medical-RAG-Chatbot/infra/ansible && $A -m shell -a "grep -E -- '--(name|initial-advertise-peer-urls|data-dir)=' /etc/kubernetes/manifests/etcd.yaml; echo 'restore would use: --name {{ inventory_hostname }} --initial-advertise-peer-urls https://{{ private_ip_address }}:2380'; ctr -n k8s.io images ls -q | grep -x 'registry.k8s.io/etcd:3.6.8-0'"
```
**Check.**
- `KEY` is the snapshot from M1.
- On each node, the manifest's `--name` and `--initial-advertise-peer-urls` equal the "restore would use"
  line, `--data-dir=/var/lib/etcd`, and the etcd image is listed. **If any node differs, stop.**

**Start the clock.**
```bash
kubectl -n restore-drill get configmap canary -o jsonpath='{.data.written-at}{"\n"}'
kubectl delete namespace restore-drill
T1=$(date -u +%FT%TZ); echo "t1=$T1"
```

**Phases 1–4.** One command each. **Every phase must print `CHANGED` or `SUCCESS` for all three nodes before
the next one runs**; a failure on one node means stop, not continue.
- Phase 1 stops all four control-plane static pods. The controller manager and the scheduler hold caches
  from after the snapshot, so they restart with etcd.
- Phase 3 adds `--bump-revision` and `--mark-compacted`. The restored revision is hours behind the
  resourceVersions every controller and kubelet already holds, and without the bump new writes would reuse
  revisions they have already seen, so watches could miss events.
```bash
cd ~/Medical-RAG-Chatbot/infra/ansible && $A -m shell -a 'cd /etc/kubernetes/manifests && mv kube-apiserver.yaml etcd.yaml kube-controller-manager.yaml kube-scheduler.yaml /root/ && for i in $(seq 1 36); do ids=$(crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -q --name "^(etcd|kube-apiserver|kube-controller-manager|kube-scheduler)$") || exit 2; [ -z "$ids" ] && exit 0; sleep 5; done; exit 1'
cd ~/Medical-RAG-Chatbot/infra/ansible && $A -m shell -a 'test ! -e /var/lib/etcd.old && mv /var/lib/etcd /var/lib/etcd.old'
cd ~/Medical-RAG-Chatbot/infra/ansible && $A -m shell -a "ctr -n k8s.io run --rm --mount type=bind,src=/var/lib,dst=/var/lib,options=rbind:rw --mount type=bind,src=/tmp/snap.db,dst=/tmp/snap.db,options=rbind:ro registry.k8s.io/etcd:3.6.8-0 restore-{{ inventory_hostname }} /usr/local/bin/etcdutl snapshot restore /tmp/snap.db --data-dir /var/lib/etcd --bump-revision 1000000000 --mark-compacted --name {{ inventory_hostname }} --initial-advertise-peer-urls https://{{ private_ip_address }}:2380 --initial-cluster-token medical-rag-restore --initial-cluster {% for h in groups['nodes'] | sort %}{{ h }}=https://{{ hostvars[h]['private_ip_address'] }}:2380{{ '' if loop.last else ',' }}{% endfor %}"
cd ~/Medical-RAG-Chatbot/infra/ansible && $A -m shell -a 'mv /root/kube-apiserver.yaml /root/etcd.yaml /root/kube-controller-manager.yaml /root/kube-scheduler.yaml /etc/kubernetes/manifests/'
```
**Rollback**, if phase 2 or 3 failed on any node — on all three, then put the manifests back (phase 4):
`$A -m shell -a 'rm -rf /var/lib/etcd && mv /var/lib/etcd.old /var/lib/etcd'`. That returns the cluster to its
state at t1, minus the deleted namespace.

**Phase 5.** Window 1: Ctrl-C the old tunnel, then `cd ~/Medical-RAG-Chatbot && make tunnel`.

**Wait for the end, and do not trust restored status.** The snapshot also restored every object's *status*
as it was at 06:00: Applications Synced and Healthy, nodes Ready, pods Running. A wait on those fields
passes the moment the API answers. So the first loop requires each Application's `reconciledAt` to be later
than t1. The second requires every node's Lease — renewed by its kubelet about every 10 s — to be later than
t1 as well, and no pod outside `Running` or `Completed`. Only then is t2 taken.
```bash
while true; do out=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status} {.status.reconciledAt}{"\n"}{end}' 2>/dev/null); n=$(echo "$out" | grep -c .); bad=$(echo "$out" | awk -v t="$T1" 'NF && ($2!="Synced" || $3!="Healthy" || $4<=t)' | grep -c .); echo "$(date -u +%T) apps=$n pending=$bad"; [ "$n" -ge 17 ] && [ "$bad" -eq 0 ] && break; sleep 15; done
until [ "$(kubectl -n kube-node-lease get lease -o jsonpath='{range .items[*]}{.spec.renewTime}{"\n"}{end}' | awk -v t="$T1" '$1>t' | grep -c .)" -ge 3 ] && [ "$(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | grep -c .)" -eq 0 ]; do echo "$(date -u +%T) waiting for nodes and pods"; sleep 15; done; T2=$(date -u +%FT%TZ); echo "t2=$T2"
kubectl get nodes; kubectl -n restore-drill get configmap canary -o jsonpath='{.data.written-at}{"\n"}'
sleep 60; cd ~/Medical-RAG-Chatbot && make apps
```
**Check.** `t2` printed; three nodes `Ready`; the canary shows **the timestamp from M0**; and one minute
later `make apps` still shows every Application Synced Healthy.

**Expected, not a failure:** pods created after the snapshot are unknown to the restored API, so their
kubelets stop them, and their Calico IP addresses stay allocated until Calico's garbage collection frees
them. RTO also includes up to one Argo CD reconcile period (about 3 minutes by default).

**Record.**
- **RTO = t2 − t1.**
- **RPO** = t1 − the time in the snapshot's key name (`snapshots/<UTC>-<node>.db`). Use the key, not M1's job:
  if M2 runs after 12:00 UTC, `KEY` is the 12:00 snapshot.
- What did not come back: anything created after the snapshot.

Do not delete `/var/lib/etcd.old` until the next rebuild. M3 removes the machines anyway.

---

## M3 — A timed rebuild

Only after M2 and M4. `make down` deletes the cluster; the etcd bucket, ECR and secrets survive in `shared`.

**Workstation, window 0.**
```bash
cd ~/Medical-RAG-Chatbot && make down
```
It ends in Terraform's `yes`.

**The clock.** Run the next block. **Type `yes` as soon as the prompt appears**: the prompt is inside the
measured time, on purpose — it is part of a real rebuild.
```bash
cd ~/Medical-RAG-Chatbot && T0=$(date -u +%FT%TZ) && echo "t0=$T0" && make infra
cd ~/Medical-RAG-Chatbot && until make ping 2>&1 | grep -c SUCCESS | grep -qx 3; do echo "waiting for SSM"; sleep 20; done; echo "ping ok $(date -u +%T)"
cd ~/Medical-RAG-Chatbot && make cluster
```
Window 1: `cd ~/Medical-RAG-Chatbot && make tunnel` (the old one targets a dead instance).
```bash
cd ~/Medical-RAG-Chatbot && make bootstrap
while true; do out=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null); n=$(echo "$out" | grep -c .); bad=$(echo "$out" | awk 'NF && ($2!="Synced" || $3!="Healthy")' | grep -c .); echo "$(date -u +%T) apps=$n pending=$bad"; [ "$n" -ge 17 ] && [ "$bad" -eq 0 ] && break; sleep 15; done; TE=$(date -u +%FT%TZ); echo "t0=$T0 end=$TE"
sleep 60; cd ~/Medical-RAG-Chatbot && make apps
kubectl -n ingress-nginx get certificaterequests
cd ~/Medical-RAG-Chatbot && make oidc-check
```
**Check.**
- The loop ends with **apps=17 pending=0**, and a minute later `make apps` still shows all 17 Synced Healthy.
- `No resources found` for certificate requests: the wildcard was restored, not re-issued.
- Two `same` lines from `oidc-check`.

**Record.**
- **T = end − t0**, as one wall-clock figure. Do not sum the commands' own times.
- The number of Applications.
- Whether a CertificateRequest appeared.

A rebuild moves the VPN's public address; re-activate the WireGuard client before using any internal UI.

---

## What each result changes in the CV

| Result | Edit in `cv_projects.tex` |
|---|---|
| M1 fails | Remove the snapshot-check clause until a run passes |
| M1 passes | Keep "checked with `etcdutl snapshot status` before upload". The automatic check refuses a file it cannot read; revision and key count are read by you, in M1 |
| M2 | Replace **[RTO]** with t2 − t1 in minutes; keep "RPO ≤ 6 h by schedule" |
| M2 canary not back | Do not write "restoring … a namespace"; write only what came back |
| M3 | Replace **[T]** and **[17]**. Keep "0 Let's Encrypt issuances" only if no CertificateRequest appeared |
| M4 | Replace the bracket with "verified by a positive-control build that fails it" |
