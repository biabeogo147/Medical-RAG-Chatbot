# Added after the first apply (step 6). bucket and region are passed with -backend-config.
terraform {
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
