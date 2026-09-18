# Ansible guide

A step-by-step guide that turns the three EC2 machines Terraform created into a highly available
Kubernetes cluster. Every file is commented, so the code you copy explains itself; the architecture
overview is in [`README.md`](README.md) next to this file. Follow the steps in order: each one ends
with a check, and the next step assumes it passed.

## How this guide works

**Start here when Terraform guide steps 1–15 are done:** `make infra` applied, and all three nodes
`Online` in SSM (step 13 of the [Terraform guide](../terraform/guide.md)). Steps 16–19 of that
guide are needed before `make bootstrap`, not before Ansible.

**Where commands run.** No ops tool is installed on your laptop, and CloudShell is not used in this
phase.

| Where | What you do there |
|---|---|
| **Laptop:** editor + **Git Bash** | Write the files shown in each step, commit, push to GitHub |
| **Ops workstation:** EC2 Ubuntu, opened with Session Manager | `git pull`, `make`, checks |

**Who does what.** Each tool owns one layer and never reaches into another:

| Tool | Owns |
|---|---|
| Terraform | The AWS resources: network, machines, load balancers, IAM, buckets |
| **Ansible** | **What is installed and configured on those machines, and `kubeadm` itself** |
| Argo CD (next phase) | Everything running inside the cluster |

**No SSH.** Ansible reaches the nodes over Session Manager, exactly like your own shell does. There
is no key pair, no bastion, and no rule that lets anyone reach a node from outside the VPC. Ansible
uploads the files a task needs to the `ssm-transfer` bucket, and the node fetches them with `curl`
from a presigned URL.

**Every step has the same shape:** goal → files → why → run → verify → commit.

**Versions:** Kubernetes 1.36.4, containerd 2.3.5, Calico v3.32.2, ecr-credential-provider v1.37.0,
collection `amazon.aws` 10.3.2.
Region `ap-southeast-1`.

## Roadmap

| Part | Step | Result | Done when |
|---|---|---|---|
| [1](guide/1-connection.md) | [1](guide/1-connection.md#step-1--inventory-connection-and-the-make-targets) | Inventory, SSM connection, make targets | `make ping` → 3 hosts `SUCCESS` |
| [1](guide/1-connection.md) | [2](guide/1-connection.md#step-2--the-common-role-and-the-first-playbook) | Role `common` + the first `site.yml` | `make cluster` twice → second run `changed=0` |
| [2](guide/2-runtime.md) | [3](guide/2-runtime.md#step-3--the-containerd-role) | Role `containerd` | `ctr version` answers, systemd cgroup driver confirmed |
| [2](guide/2-runtime.md) | [4](guide/2-runtime.md#step-4--the-kubernetes_packages-role) | Role `kubernetes_packages` | `kubeadm version` → 1.36.4, packages held |
| [2](guide/2-runtime.md) | [5](guide/2-runtime.md#step-5--the-ecr_credential_provider-role) | Role `ecr_credential_provider` | Binary checksum verified, kubelet flags in place |
| [3](guide/3-control-plane.md) | [6](guide/3-control-plane.md#step-6--the-kubeadm_init-role) | Role `kubeadm_init` | Node 1 is a control plane, NLB target `healthy` |
| [3](guide/3-control-plane.md) | [7](guide/3-control-plane.md#step-7--the-kubeadm_join-role) | Role `kubeadm_join` | 3 control planes, etcd has 3 members |
| [4](guide/4-network-and-kubectl.md) | [8](guide/4-network-and-kubectl.md#step-8--the-cni_calico-and-untaint_control_plane-roles) | Roles `cni_calico` + `untaint_control_plane` | 3 nodes `Ready`, a test pod runs |
| [4](guide/4-network-and-kubectl.md) | [9](guide/4-network-and-kubectl.md#step-9--kubectl-on-the-workstation) | Kubeconfig on the workstation, `make tunnel` | `kubectl get nodes` works from the workstation |
| [5](guide/5-prove-and-extend.md) | [10](guide/5-prove-and-extend.md#step-10--idempotency-the-ha-drill-and-the-evidence) | Idempotency, HA drill, evidence | `changed=0`; the API survives losing a node |
| [5](guide/5-prove-and-extend.md) | [11](guide/5-prove-and-extend.md#step-11--let-prometheus-reach-the-control-plane-metrics) | Control-plane metrics on the node address (for the GitOps phase) | A pod reads etcd metrics from another node |

**Parts:** [1. Inventory, SSM connection and the first role](guide/1-connection.md) · [2. Container runtime, Kubernetes packages, ECR login](guide/2-runtime.md) · [3. The control plane: kubeadm init and join](guide/3-control-plane.md) · [4. Pod network and kubectl on the workstation](guide/4-network-and-kubectl.md) · [5. Prove it, then open the control-plane metrics](guide/5-prove-and-extend.md) · [Troubleshooting](guide/troubleshooting.md)

---

## The loop for every step

1. **Laptop:** create or edit the files, commit, push.
2. **Workstation:** open Session Manager ([Terraform guide step 5](../terraform/guide/1-bootstrap.md#step-5--connect-to-the-workstation-session-manager)), then:
   ```bash
   sudo su - ubuntu
   tmux new -As k8s                       # re-attaches if the session already exists
   cd ~/Medical-RAG-Chatbot && git pull
   ```
3. **Workstation:** run the `make` targets of the step, then its checks.

Session Manager disconnects after about 20 idle minutes and shell variables are lost with it, so
each check in the steps sets what it needs.

**End of every session:** `make infra-destroy`, then stop the workstation (EC2 → Instances → Instance state → Stop). Next time, `make infra` and `make cluster` rebuild everything.

---

Start with [Part 1: Inventory, SSM connection and the first role](guide/1-connection.md).
