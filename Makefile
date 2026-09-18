SHELL := /bin/bash

REGION       ?= ap-southeast-1
PROJECT      ?= medical-rag
ACCOUNT_ID   := $(shell aws sts get-caller-identity --query Account --output text)
BACKEND      := -backend-config="bucket=$(PROJECT)-tfstate-$(ACCOUNT_ID)" -backend-config="region=$(REGION)"
SHARED       := terraform -chdir=infra/terraform/shared
CLUSTER      := terraform -chdir=infra/terraform/cluster

.PHONY: shared-init shared-plan shared init plan infra infra-destroy

# Shared stack: registry, index artifacts, signing key, secrets, budget. Kept across rebuilds.
shared-init:
	$(SHARED) init -input=false $(BACKEND)

shared-plan: shared-init
	$(SHARED) plan

shared: shared-init
	$(SHARED) apply

# Cluster stack: network, nodes, load balancers. Destroyed when idle.
init:
	$(CLUSTER) init -input=false $(BACKEND)

plan: init
	$(CLUSTER) plan

infra: init
	$(CLUSTER) apply

infra-destroy: init
	$(CLUSTER) destroy


# --- Ansible: turn the three nodes into a Kubernetes cluster -----------------------------------
ANSIBLE_DIR  := infra/ansible
# aws_account_id can only come from here. project and aws_region are passed too, so the Makefile and
# group_vars/all.yml can never disagree about which cluster is being built.
ANSIBLE_VARS := -e project=$(PROJECT) -e aws_region=$(REGION) -e aws_account_id=$(ACCOUNT_ID)

# Recursive (=, not :=), so these two only call AWS when a target below actually uses them.
API_ENDPOINT  = $(shell $(CLUSTER) output -raw api_nlb_dns)
NODE_1        = $(shell aws ec2 describe-instances --filters "Name=tag:Name,Values=$(PROJECT)-node-1" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)

.PHONY: ansible-deps ping cluster kubectl tunnel

# Install the pinned collection. Once per workstation.
ansible-deps:
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

# Reach all three nodes through Session Manager. The first check after `make infra`.
ping:
	cd $(ANSIBLE_DIR) && ansible nodes -m ansible.builtin.ping $(ANSIBLE_VARS)

# Build the cluster. Safe to run again: a second run changes nothing. It depends on `init` so that
# `terraform output` below can never come back empty in a fresh working copy.
cluster: init
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml $(ANSIBLE_VARS) -e control_plane_endpoint=$(API_ENDPOINT)

# Run one kubectl command on the first node, for the checks made before the tunnel exists:
#   make kubectl CMD="get nodes"
kubectl:
	@test -n "$(CMD)" || { echo 'usage: make kubectl CMD="get nodes"'; exit 1; }
	cd $(ANSIBLE_DIR) && ansible first_node -b $(ANSIBLE_VARS) -m command -a "kubectl --kubeconfig /etc/kubernetes/admin.conf $(CMD)"

# Forward 127.0.0.1:6443 to the internal API load balancer through node 1, so kubectl works on the
# workstation. Keep the window open; Ctrl-C closes the tunnel.
tunnel:
	aws ssm start-session --target $(NODE_1) --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=$(API_ENDPOINT),portNumber=6443,localPortNumber=6443


# --- GitOps: Argo CD, then everything Argo CD installs from deploy/argocd/ ----------------------
ARGOCD_APP     := deploy/argocd/apps/argocd.yaml
ARGOCD_VALUES  := deploy/argocd/values/argocd.yaml
# The chart version is written once, in the Application Argo CD uses to manage itself. Reading it
# here means the first install and the self-managed one can never disagree.
ARGOCD_VERSION  = $(shell yq '.spec.sources[0].targetRevision' $(ARGOCD_APP))

.PHONY: bootstrap apps

# Install Argo CD and hand it the root Application. Needs `make tunnel` open in another window.
# Safe to run again: same chart, same version, same values.
bootstrap:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	@# Only the first bootstrap installs the chart. Once the argocd Application exists, Argo CD owns
	@# these objects through server-side apply, and a second `helm upgrade` fails on field conflicts.
	@if kubectl -n argocd get application argocd >/dev/null 2>&1; then \
	  echo "Argo CD already manages itself; skipping helm and applying root.yaml only"; \
	else \
	  helm upgrade --install argocd argo/argo-cd \
	    --namespace argocd --create-namespace \
	    --version $(ARGOCD_VERSION) \
	    --values $(ARGOCD_VALUES) \
	    --wait --timeout 10m; \
	fi
	kubectl apply -f deploy/argocd/root.yaml

# Sync and health of everything Argo CD manages.
apps:
	kubectl -n argocd get applications


# The CSI volumes that still exist. Terraform does not know them, so they are found by the tags the
# driver adds (ebs.csi.aws.com/cluster) and the one from values/aws-ebs-csi-driver.yaml (project).
CSI_VOLUMES = aws ec2 describe-volumes --region $(REGION) --query 'length(Volumes)' --output text \
  --filters Name=tag:project,Values=$(PROJECT) Name=tag-key,Values=ebs.csi.aws.com/cluster

# Release the EBS volumes the cluster created, then destroy the cluster stack. Needs `make tunnel`.
# The order matters: the CSI driver must still be running while the volumes are deleted.
down: init
	@# The leading "-" lets make continue when root does not exist, e.g. after a failed bootstrap.
	-kubectl -n argocd patch application root --type merge --patch '{"spec":{"syncPolicy":{"automated":null}}}'
	kubectl -n argocd delete applications --selector medical-rag/volumes=true --timeout=10m
	kubectl delete pvc --all --all-namespaces --timeout=15m
	@for i in $$(seq 30); do \
	  n=$$($(CSI_VOLUMES)) || exit 1; \
	  test "$$n" = 0 && break; \
	  echo "$$n EBS volume(s) still exist, waiting"; \
	  sleep 10; \
	done
	@test "$$($(CSI_VOLUMES))" = 0 || { echo "EBS volumes remain; not destroying the cluster"; exit 1; }
	$(MAKE) infra-destroy
