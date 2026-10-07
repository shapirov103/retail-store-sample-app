# Private ECR repository for catalog images built by the CD workflow.
resource "aws_ecr_repository" "catalog" {
  name                 = "${var.environment_name}/catalog"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo stack: allow terraform destroy with images present

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "catalog" {
  repository = aws_ecr_repository.catalog.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}
