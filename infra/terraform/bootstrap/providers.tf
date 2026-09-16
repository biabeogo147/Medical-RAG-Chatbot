provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      owner      = var.owner
      stack      = "bootstrap"
      managed-by = "terraform"
    }
  }
}