# Ansible guide — Part 5: Prove it, then open the control-plane metrics (steps 10–11)

[← Part 4](4-network-and-kubectl.md) · [Index](../guide.md) · [Next: GitOps guide →](../../gitops/guide.md) · [Troubleshooting](troubleshooting.md)

**Before you start:** Part 4 done: kubectl works on the workstation.

**Done when:** steps 10–11 — a second run reports `changed=0`, the API survives losing a node, and a pod reads etcd metrics from another node.

**Every step here follows [the loop](../guide.md#the-loop-for-every-step):** edit and push on the laptop; on the workstation `sudo su - ubuntu`, `tmux new -As k8s`, `cd ~/Medical-RAG-Chatbot && git pull`; then the step's `make` targets and checks.

---

## Step 10 — Idempotency, the HA drill, and the evidence

**Goal:** prove the cluster is reproducible and really survives losing a machine.

**Idempotency:**
```bash
cd ~/Medical-RAG-Chatbot
time make cluster
```
Every node must report `changed=0`. Anything that still changes is worth fixing before moving on.

**The HA drill.** It uses `kubectl` on the workstation, so open tmux window 1 (`Ctrl-b c`), run `make tunnel`
there and leave it open for the whole drill. Stop node 2 — never node 1, because the tunnel runs
through it:
```bash
NODE2=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=medical-rag-node-2" \
  "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ec2 stop-instances --instance-ids $NODE2
kubectl get nodes -w          # node 2 turns NotReady once the node-monitor grace period expires
kubectl get pods -A           # the API keeps answering: 2 of 3 etcd members is still a quorum
```
Start it again and watch it come back on its own:
```bash
aws ec2 start-instances --instance-ids $NODE2
kubectl get nodes -w          # Ready again without a playbook run: containerd and the kubelet start
                              # at boot, and the static pod manifests are already on disk
```

**Record** in `docs/evidence/ansible.md`: how long `make cluster` takes on a set of fresh nodes, the
recap line of the second run, `kubectl get nodes -o wide`, the etcd member table, and what happened
during the drill.

**If you stop here** (step 11 continues on a rebuilt cluster, so it can wait for the next session):
```bash
make infra-destroy    # the cluster stack; the shared stack and the workstation are kept
```
Then stop the workstation (EC2 → Instances → Instance state → Stop). Next time, `make infra` followed
by `make cluster` rebuilds everything from these files.

---

## Step 11 — Let Prometheus reach the control-plane metrics

**Goal:** etcd, the scheduler, the controller manager and kube-proxy serve their metrics on the node's
address, so Prometheus (GitOps phase) can collect them.

**Why this is needed.** kubeadm makes these four components listen for metrics on `127.0.0.1` only.
Prometheus runs in a pod, and a pod has its own network namespace: for it, `127.0.0.1` is the pod
itself, not the node. The monitoring chart expects all four, so left as they are they show as four
targets that are always `down`, and the chart's alerts for them (`etcdMembersDown`,
`KubeSchedulerDown`, …) fire all day although nothing is broken. For a cluster you run yourself, etcd is
also the one component whose health you most need to see.

| Component | Port | Protocol | Before | After |
|---|---|---|---|---|
| etcd | 2381 | HTTP, metrics only | `127.0.0.1` | `0.0.0.0` |
| kube-controller-manager | 10257 | HTTPS, needs a token | `127.0.0.1` | `0.0.0.0` |
| kube-scheduler | 10259 | HTTPS, needs a token | `127.0.0.1` | `0.0.0.0` |
| kube-proxy | 10249 | HTTP, metrics only | `127.0.0.1` | `0.0.0.0` |

**Who can reach them afterwards.** The node security group admits these ports only from the other
nodes (`nodes_from_nodes` in `infra/terraform/cluster/security.tf`), which includes every pod. Port 2381
serves metrics only, not etcd's data, which stays on 2379 with client certificates. The controller
manager and the scheduler still require an authorised token on their metrics endpoint.

**Laptop.** In `infra/ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2` (created in [step 6](3-control-plane.md#step-6--the-kubeadm_init-role)), add this at the end
of the `ClusterConfiguration` document, after `networking:`:
```yaml

# Metrics on the node's address instead of 127.0.0.1, so Prometheus in a pod can scrape them. The joining
# control planes read this same ClusterConfiguration, so all three nodes get it.
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
etcd:
  local:
    extraArgs:
      # Only the metrics listener moves; client traffic stays on 2379 with TLS.
      - name: listen-metrics-urls
        value: "http://0.0.0.0:2381"
```
Then add a third document at the very end of the file:
```yaml
---
# kube-proxy runs as a DaemonSet with one shared configuration, which kubeadm creates from this.
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: "0.0.0.0:10249"
```

**Why:**

- **`extraArgs` is a list of `name`/`value` pairs** in kubeadm v1beta4. The older map form
  (`bind-address: "0.0.0.0"`) belongs to v1beta3 and is rejected.
- **kubeadm reads this file only during `kubeadm init`.** A running cluster keeps its old settings, and
  the role skips `init` once `admin.conf` exists. The change takes effect on the next rebuild, which is
  how this project changes a cluster anyway.

**Commit and push** (`git add infra/ansible`, message `Expose control-plane metrics`), `git pull` on the workstation.

**Run** a rebuild (the tunnel window must be closed first, since node 1 is replaced):
```bash
make infra-destroy
make infra
make cluster
```
Open the tunnel again in tmux window 1 (`Ctrl-b 1` if it exists, otherwise `Ctrl-b c`) with `make tunnel`.

**Verify** in window 0 (`Ctrl-b 0`). Each command prints one line per node, with the command line the
component was started with. First the scheduler:
```bash
CMDS='{range .items[*]}{.spec.nodeName}{"  "}{.spec.containers[0].command}{"\n"}{end}'
kubectl -n kube-system get pods -l component=kube-scheduler -o jsonpath="$CMDS"
```
Three lines, each containing `"--bind-address=0.0.0.0"`. The controller manager:
```bash
kubectl -n kube-system get pods -l component=kube-controller-manager -o jsonpath="$CMDS"
```
The same. And etcd:
```bash
kubectl -n kube-system get pods -l component=etcd -o jsonpath="$CMDS"
```
Three lines, each containing `"--listen-metrics-urls=http://0.0.0.0:2381"`.

kube-proxy:
```bash
kubectl -n kube-system get configmap kube-proxy \
  -o jsonpath='{.data.config\.conf}' > /tmp/kube-proxy.conf
grep metricsBindAddress /tmp/kube-proxy.conf
```
`metricsBindAddress: 0.0.0.0:10249`.

Finally, from inside the cluster, the way Prometheus will ask. A throwaway pod fetches etcd's metrics
from node 2's address:
```bash
NODE2_IP=$(kubectl get node medical-rag-node-2 \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
kubectl run metricscheck \
  --rm -i --restart=Never \
  --image=busybox:1.36 \
  -- wget -qO- "http://$NODE2_IP:2381/metrics" > /tmp/etcd-metrics.txt
grep -c '^etcd_server_has_leader' /tmp/etcd-metrics.txt
```
**1 or more.** Any number above `0` means the pod reached etcd's metrics on another node, which is the
whole point of this check. Two normal surprises:

- **`warning: couldn't attach to pod/metricscheck, falling back to streaming logs`.** The container ran
  `wget` and exited before kubectl could attach, so kubectl read its log instead. Harmless, but it can
  write the output twice, which is the usual reason the count is `2`.
- Look at the lines themselves if you want to know which it was:
  ```bash
  grep '^etcd_server_has_leader' /tmp/etcd-metrics.txt
  ```
  `etcd_server_has_leader 1` means that member can see a leader. Two identical lines mean the output was
  written twice.

A `0`, or a command that hangs and then fails, means this cluster was built before the template change:
rebuild it.

A second `make cluster` still reports `changed=0` on every node.

**End of the session:** `make infra-destroy`, then stop the workstation.

---

[← Part 4](4-network-and-kubectl.md) · [Index](../guide.md) · [Next: GitOps guide →](../../gitops/guide.md) · [Troubleshooting](troubleshooting.md)
