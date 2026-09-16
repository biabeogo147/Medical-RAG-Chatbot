# Which region to call and which credentials to use. No key is configured: in CloudShell the provider
# uses the console session, and on the ops workstation it uses the EC2 instance role.
provider "aws" {
  region = var.region # var.<name> reads a variable declared in variables.tf

  # Tags added automatically to every resource created through this provider.
  default_tags {
    tags = {
      project    = var.project # the tag the AWS budget filters on, to separate this project's spend
      owner      = var.owner
      stack      = "bootstrap" # says in the console which stack created a resource
      managed-by = "terraform" # a warning not to edit the resource by hand
    }
  }
}
