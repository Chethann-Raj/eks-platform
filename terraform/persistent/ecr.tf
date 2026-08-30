resource "aws_ecr_repository" "app" {
  name = var.ecr_repository_name

  # prod.yml promotes an existing SHA-tagged image without rebuilding, so a tag
  # must permanently mean one image. Mutable tags could let a re-run of main.yml
  # silently replace what production is about to promote. Also satisfies
  # Checkov CKV_AWS_51.

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
