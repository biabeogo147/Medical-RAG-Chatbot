# Ansible phase — 2026-09-17

Ansible built a highly available kubeadm cluster on the three EC2 nodes created by the Terraform
cluster stack. It ran from the ops workstation over SSM Session Manager, with no SSH and no key pair.
Kubernetes 1.36.4, containerd 2.3.5, Calico v3.32.2 (VXLAN), ecr-credential-provider v1.37.0, collection
`amazon.aws` 10.3.2. Region `ap-southeast-1`.

## Cluster

`kubectl get nodes`, run on the workstation through `make tunnel` (SSM port-forward via node 1 to the
internal API NLB, `server: https://127.0.0.1:6443`, no TLS warning):

| Name | Status | Roles | Version |
|---|---|---|---|
| medical-rag-node-1 | Ready | control-plane | v1.36.4 |
| medical-rag-node-2 | Ready | control-plane | v1.36.4 |
| medical-rag-node-3 | Ready | control-plane | v1.36.4 |

Three stacked control planes, one per Availability Zone. All three nodes also schedule workloads (the
control-plane taint is removed).

`kubectl get pods -A`: every pod `Running` with **0 restarts**.

| Namespace | Pods |
|---|---|
| `kube-system` | `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `kube-proxy` on each of the 3 nodes; 2 × `coredns` |
| `calico-system` | 3 × `calico-node`, 2 × `calico-typha`, 3 × `csi-node-driver`, 1 × `calico-kube-controllers` |
| `tigera-operator` | 1 × `tigera-operator` |

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
| 10 | `time make cluster` on the already-built cluster | **2 m 59 s** (`real 2m58.966s`) |
| 10 | `time make infra-cluster` | **2 m 19 s** (`real 2m19.011s`) |

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

## Still to record

The step 10 record list asks for these; they were not captured in this session:

- `make cluster` on a **fresh** set of nodes (straight after `make infra`). The 2 m 59 s above is a run against the cluster that already existed.
- The `PLAY RECAP` of the second run, showing `changed=0` on every node.
- `kubectl get nodes -o wide`.
- The etcd member table: `make kubectl CMD="exec -n kube-system etcd-medical-rag-node-1 -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list -w table"`.
