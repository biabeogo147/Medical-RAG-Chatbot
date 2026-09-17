# Ansible phase — 2026-09-17

Ansible built a highly available kubeadm cluster on the three EC2 nodes created by the Terraform
cluster stack. It ran from the ops workstation over SSM Session Manager, with no SSH and no key pair.
Kubernetes 1.36.4, containerd 2.3.5, Calico v3.32.2 (VXLAN), ecr-credential-provider v1.37.0, collection
`amazon.aws` 10.3.2. Region `ap-southeast-1`.

## Cluster

`kubectl get nodes -o wide`, run on the workstation through `make tunnel` (SSM port-forward via node 1 to
the internal API NLB, `server: https://127.0.0.1:6443`, no TLS warning). Captured after the rebuild from
nothing below:

| Name | Status | Roles | Age | Version | Internal IP | OS image | Kernel | Runtime |
|---|---|---|---|---|---|---|---|---|
| medical-rag-node-1 | Ready | control-plane | 7m26s | v1.36.4 | 10.10.1.185 | Ubuntu 24.04.4 LTS | 7.0.0-1012-aws | containerd://2.3.5 |
| medical-rag-node-2 | Ready | control-plane | 6m21s | v1.36.4 | 10.10.2.208 | Ubuntu 24.04.4 LTS | 7.0.0-1012-aws | containerd://2.3.5 |
| medical-rag-node-3 | Ready | control-plane | 5m36s | v1.36.4 | 10.10.3.249 | Ubuntu 24.04.4 LTS | 7.0.0-1012-aws | containerd://2.3.5 |

Three stacked control planes, one per Availability Zone (`10.10.1.x`, `10.10.2.x`, `10.10.3.x`), no
external IP. All three nodes also schedule workloads (the control-plane taint is removed). The ages
are consistent with the join play running `serial: 1`: node 2 registered about 65 s after node 1, and
node 3 about 45 s after node 2.

`kubectl get pods -A`: all 27 pods `Running` with **0 restarts**.

| Namespace | Pods |
|---|---|
| `kube-system` | `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `kube-proxy` on each of the 3 nodes; 2 × `coredns` |
| `calico-system` | 3 × `calico-node`, 2 × `calico-typha`, 3 × `csi-node-driver`, 1 × `calico-kube-controllers` |
| `tigera-operator` | 1 × `tigera-operator` |

### etcd

`etcdctl member list -w table`, run inside `etcd-medical-rag-node-1` through `make kubectl`:

| ID | Status | Name | Peer address | Client address | Is learner |
|---|---|---|---|---|---|
| 274a9f32df54e724 | started | medical-rag-node-2 | https://10.10.2.208:2380 | https://10.10.2.208:2379 | false |
| 6a86524ac3570cf0 | started | medical-rag-node-3 | https://10.10.3.249:2380 | https://10.10.3.249:2379 | false |
| 854dc9f1fe46149d | started | medical-rag-node-1 | https://10.10.1.185:2380 | https://10.10.1.185:2379 | false |

`etcdctl endpoint status --cluster -w table` (selected columns):

| Endpoint | Version | DB size | Is leader | Is learner | Raft term | Raft index | Applied index | Errors |
|---|---|---|---|---|---|---|---|---|
| https://10.10.2.208:2379 | 3.6.8 | 9.7 MB | false | false | 2 | 3083 | 3083 | none |
| https://10.10.3.249:2379 | 3.6.8 | 9.7 MB | false | false | 2 | 3083 | 3083 | none |
| https://10.10.1.185:2379 | 3.6.8 | 9.7 MB | **true** | false | 2 | 3083 | 3083 | none |

Three voting members, none left as a learner after the joins, exactly one leader, and every member at the
same raft and applied index: the cluster is in sync.

## Checks

| Step | Check | Result |
|---|---|---|
| 1 | `make ping` | 3 × `SUCCESS` over SSM (after the node 2 incident below) |
| 4 | `kubeadm version -o short` | `v1.36.4` on all three nodes |
| 4 | `apt-mark showhold` | `containerd.io`, `kubeadm`, `kubectl`, `kubelet` held on all three nodes |
| 8 | Test pod `busybox:1.36` | `Running` on `medical-rag-node-1` with pod IP `192.168.152.130`, inside the Calico pod CIDR `192.168.0.0/16` |
| 8 | `nslookup kubernetes.default.svc.cluster.local` from the pod | Answered by `10.96.0.10` (CoreDNS): `Address: 10.96.0.1`, the API Service address in `10.96.0.0/12` |
| 8 | `/etc/resolv.conf` in the pod | `nameserver 10.96.0.10`, `search default.svc.cluster.local svc.cluster.local cluster.local ap-southeast-1.compute.internal`, `options ndots:5` |
| 9 | `kubectl get nodes` on the workstation | 3 nodes `Ready`, no `--kubeconfig` flag, no certificate warning |
| 10 | `time make cluster` against a cluster that already existed (first session) | **2 m 59 s** (`real 2m58.966s`) |

## Rebuild from nothing

Measured on 2026-09-17 after destroying the cluster stack: new instances, new disks, no state on any
node. `terraform apply` ran with `TF_CLI_ARGS_apply=-auto-approve`, so no time was spent waiting at the
confirmation prompt. Raw logs stay on the workstation under `~/evidence/2026-09-17/`, outside Git.

| Step | Command | Result |
|---|---|---|
| 1 | `time make infra` | `Apply complete! Resources: 84 added, 0 changed, 0 destroyed.` in **3 m 47 s** (`real 3m47.101s`) |
| 2 | `make plan` after; `state list \| wc -l` | `No changes. Your infrastructure matches the configuration.`; **101** state entries |
| 3 | `make ping` | 3 × `SUCCESS` (`"ping": "pong"`) |
| 4 | `time make cluster` on the fresh nodes | **6 m 10 s** (`real 6m10.428s`) |
| 5 | `time make cluster` again | **`changed=0` on every host** in **2 m 56 s** (`real 2m55.927s`); recap below |
| 6 | `kubectl get nodes -o wide`, `get pods -A` | See [Cluster](#cluster) |
| 7 | `etcdctl member list`, `endpoint status` | See [etcd](#etcd) |
| 8 | `time make infra-destroy` | `Destroy complete! Resources: 84 destroyed.` in **2 m 15 s** (`real 2m15.500s`) |

`PLAY RECAP` of the second run:

```
localhost                  : ok=1    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
medical-rag-node-1         : ok=50   changed=0    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0
medical-rag-node-2         : ok=34   changed=0    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
medical-rag-node-3         : ok=34   changed=0    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```

From an empty cluster stack to three `Ready` control-plane nodes: **9 m 57 s** of measured command time
(3 m 47 s `make infra` + 6 m 10 s `make cluster`). The wait for the SSM agents to register before
`make ping` was not timed. A second `make cluster` run changed nothing on any host and took 2 m 56 s, less than half the first run.

## HA drill

The tunnel ran through node 1, so node 2 was the one stopped.

| Action | Observed |
|---|---|
| `aws ec2 stop-instances` on node 2 (`i-0510a727d68f7a930`) | Instance went `running` → `stopping` |
| `kubectl get nodes -w` | `medical-rag-node-2` turned `NotReady`; nodes 1 and 3 stayed `Ready` |
| `kubectl get pods -A` while node 2 was down | **The API kept answering** through the internal NLB: 2 of 3 etcd members is still a quorum |
| `aws ec2 start-instances` on node 2 | Instance went `stopped` → `pending` |
| `kubectl get nodes -w` | `medical-rag-node-2` returned to `Ready` **without running the playbook**: containerd and the kubelet start at boot, and the static pod manifests are already on disk |

## Problems found and fixed during this phase

| Problem | Root cause | Fix |
|---|---|---|
| `make ping`: node 2 `TargetNotConnected`, nodes 1 and 3 `SUCCESS` | Node 2 was `running` with status checks `ok`, but SSM had no record of it: the agent had never registered. Its console output showed `SSM Agent unable to acquire credentials: no valid credentials could be retrieved for ec2 identity`, then a fallback to Default Host Management that failed with `AccessDeniedException`. The instance profile `medical-rag-nodes` was attached. **Most likely** the agent started before the role's credentials were available in instance metadata; not proven, because nodes 1 and 3 launched at the same time with the same role and registered normally | `aws ec2 reboot-instances` on node 2; the agent registered on the next boot. Proposed prevention: a node boot script that waits for instance-role credentials in IMDS, then restarts the agent |
| Step 4 check: `crictl: not found` on all three nodes | The guide assumed `crictl` comes with `kubeadm`. `dpkg -s kubeadm` shows no `Depends` line, and `apt-cache policy cri-tools` showed `Installed: (none)`, candidate `1.36.0-1.1` | The `kubernetes_packages` role installs `cri-tools=1.36.0-1.1` explicitly (`cri_tools_apt_version` in `group_vars/all.yml`) |
| Step 8 check: `nslookup kubernetes.default` returned `NXDOMAIN` | Not a DNS fault. busybox's `nslookup` ignores the `search` list, so it asked for the literal short name. The answer came from `10.96.0.10`, which already proved the pod reached CoreDNS | The guide uses the full name `kubernetes.default.svc.cluster.local`, which resolves to `10.96.0.1` |
