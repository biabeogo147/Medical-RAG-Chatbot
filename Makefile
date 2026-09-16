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
