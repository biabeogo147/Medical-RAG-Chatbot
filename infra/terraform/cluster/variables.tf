# The inputs of the cluster stack. All have defaults, so no terraform.tfvars file is needed here.
# Override one for a single run with: terraform apply -var node_instance_type=c7i-flex.large

variable "region" {
  description = "AWS region for every resource in this project."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project name, used as the resource name prefix and the project tag."
  type        = string
  default     = "medical-rag"
}

variable "owner" {
  description = "Value of the owner tag."
  type        = string
  default     = "devops-lab-user"
}

variable "vpc_cidr" {
  description = "CIDR of the cluster VPC. Must not overlap the Calico pod CIDR."
  type        = string
  default     = "10.10.0.0/16" # must not overlap the ops VPC (10.20.0.0/24) or the Calico pod CIDR
}

variable "node_count" {
  description = "Number of Kubernetes nodes. Each one is a control-plane node that also runs workloads."
  type        = number
  default     = 3
}

variable "node_instance_type" {
  description = "EC2 instance type of the Kubernetes nodes."
  type        = string
  # kubeadm needs at least 2 vCPU and 2 GB. m7i-flex.large gives 2 vCPU and 8 GB and, unlike
  # t3.large, may be launched by an AWS Free plan account.
  default = "m7i-flex.large"
}

variable "node_volume_gb" {
  description = "Root volume size of each node, in GB."
  type        = number
  default     = 40
}

variable "api_port" {
  description = "Kubernetes API server port."
  type        = number
  default     = 6443
}

variable "ingress_http_nodeport" {
  description = "NodePort of ingress-nginx for HTTP, targeted by the public NLB."
  type        = number
  default     = 30080 # ingress-nginx will listen here on every node
}
