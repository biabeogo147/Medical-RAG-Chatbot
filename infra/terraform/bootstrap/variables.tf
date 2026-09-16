# The inputs of this stack. Everything else refers to them as var.<name>, so no name, size or region
# is hard-coded further down. Override one without editing the code:
#   terraform apply -var workstation_instance_type=c7i-flex.large
#   a terraform.tfvars file, or the environment variable TF_VAR_workstation_instance_type
#
# `description` shows up in `terraform plan`; `type` makes Terraform reject a wrong value early;
# `default` makes the variable optional (a variable without one must be supplied).

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

variable "ops_vpc_cidr" {
  description = "CIDR of the small VPC that hosts the ops workstation."
  type        = string
  default     = "10.20.0.0/24" # must not overlap the cluster VPC (10.10.0.0/16)
}

variable "workstation_instance_type" {
  description = "EC2 instance type of the ops workstation."
  type        = string
  # t3.small (2 vCPU, 2 GB) is enough for Terraform, Ansible and kubectl, and it is one of the
  # types an AWS Free plan account may launch.
  default = "t3.small"
}

variable "workstation_volume_gb" {
  description = "Root volume size of the ops workstation, in GB."
  type        = number
  default     = 30
}
