# Where this stack's state is stored. The bucket name is passed by `make init` with -backend-config,
# because a backend block cannot use variables.
terraform {
  backend "s3" {
    key          = "cluster/terraform.tfstate"
    use_lockfile = true # a .tflock object in S3 stops two applies from running at the same time
    encrypt      = true
  }
}
