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
  default     = "10.20.0.0/24"
}

variable "workstation_instance_type" {
  description = "EC2 instance type of the ops workstation."
  type        = string
  default     = "t3.medium"
}

variable "workstation_volume_gb" {
  description = "Root volume size of the ops workstation, in GB."
  type        = number
  default     = 30
}