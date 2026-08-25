resource "aws_ecr_repository" "this" {
  name = "${var.project_name}-feed-service"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Untagged images (superseded by a later push under the same tag,
# usually "latest") are just build waste - expire them instead of
# paying to store them indefinitely.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
