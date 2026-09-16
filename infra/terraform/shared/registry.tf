# The container registry for the app image. It lives in the shared stack because destroying the
# cluster must not delete images or the signatures that were made for them.
resource "aws_ecr_repository" "app" {
  name = local.name

  # A release tag (the git SHA) can never be overwritten, so what was scanned and signed is what runs.
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  # Two exceptions, because cosign and BuildKit must be able to overwrite these tags: legacy cosign
  # signature tags (sha256-*) and the BuildKit cache tag.
  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  image_tag_mutability_exclusion_filter {
    filter      = "buildcache*"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true # a free vulnerability scan of every pushed image
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  # Counts tagged images only. Cosign v3 stores signatures and SBOM attestations as untagged OCI
  # referrers, so a rule with tagStatus "any" would count them and could delete the signature of an
  # image that is still running.
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 tagged images"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["*"]
        countType      = "imageCountMoreThan"
        countNumber    = 20
      }
      action = { type = "expire" }
    }]
  })
}
