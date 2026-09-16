# Lookups and computed values used by the other files of this stack.

data "aws_caller_identity" "current" {}

locals {
  name       = var.project
  account_id = data.aws_caller_identity.current.account_id # part of the globally unique bucket name
}
