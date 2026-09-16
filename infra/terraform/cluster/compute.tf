# The three Kubernetes machines. Terraform only creates them; Ansible turns them into a cluster.

data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "nodes" {
  count = var.node_count # creates nodes[0], nodes[1], nodes[2]

  ami           = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  instance_type = var.node_instance_type # 2 vCPU for kubeadm, 8 GB for Jenkins, Prometheus and the app

  # node 1 to AZ a, node 2 to AZ b, node 3 to AZ c. Losing one AZ leaves 2 of 3 etcd members, which
  # keeps quorum, so the cluster survives. There are always 3 subnets, so a 4th node would wrap onto
  # the first one again.
  subnet_id = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]

  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.nodes.name
  # No public IP and no key pair: the only way in is Session Manager.

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 2 hops, unlike the workstation's 1: pods run in their own network namespace, so External Secrets
    # and the EBS CSI driver need one extra hop to reach the metadata service.
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.node_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-node-${count.index + 1}"
    # Ansible's aws_ec2 inventory selects the nodes by this tag, so no IP address is ever written down.
    k8s-cluster = local.name
  }

  lifecycle {
    # Canonical publishes new images constantly; without this every apply would replace the nodes.
    ignore_changes = [ami]
  }
}

