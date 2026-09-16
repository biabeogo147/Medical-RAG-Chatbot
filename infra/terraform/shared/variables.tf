# The inputs of the shared stack. budget_email has no default, so terraform.tfvars must set it.

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

variable "budget_email" {
  description = "Email address that receives the budget alerts."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget. Alerts fire at 50% and 100% of it."
  type        = number
  default     = 100
}
