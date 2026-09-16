# Where this stack's state is stored. A backend block cannot use variables, so the bucket name (which
# contains the account ID) is passed by `make shared-init` with -backend-config and stays out of Git.
terraform {
  backend "s3" {
    key = "shared/terraform.tfstate" # each stack has its own key in the same bucket

    # Terraform writes a .tflock object in S3 while it works, so two applies cannot run at once.
    # This replaces the DynamoDB lock table that older setups needed.
    use_lockfile = true
    encrypt      = true
  }
}
