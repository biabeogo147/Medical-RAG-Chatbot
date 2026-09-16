# Printed after `apply`, and readable later with `terraform output -raw <name>`.
# These three are what the rest of the project needs from this stack.

output "region" {
  value = var.region
}

# The backend of the shared and cluster stacks: `make init` passes it with -backend-config.
output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

# Used to find the machine in the console, and for `aws ssm start-session --target <id>`.
output "workstation_instance_id" {
  value = aws_instance.workstation.id
}
