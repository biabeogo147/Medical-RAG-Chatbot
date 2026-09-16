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
