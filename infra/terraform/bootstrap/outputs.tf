output "region" {
  value = var.region
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "workstation_instance_id" {
  value = aws_instance.workstation.id
}