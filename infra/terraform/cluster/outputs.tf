output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "node_instance_ids" {
  value = aws_instance.nodes[*].id
}

output "node_private_ips" {
  value = aws_instance.nodes[*].private_ip
}

output "api_nlb_dns" {
  description = "kubeadm controlPlaneEndpoint (port 6443)"
  value       = aws_lb.api.dns_name
}

output "public_nlb_dns" {
  description = "Public HTTP entry point of the app"
  value       = aws_lb.ingress.dns_name
}

output "buckets" {
  value = { for k, b in aws_s3_bucket.this : k => b.bucket }
}
