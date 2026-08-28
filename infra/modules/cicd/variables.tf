variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "github_repo" {
  description = "GitHub repo in \"owner/name\" form that the pipeline builds from."
  type        = string
}

variable "github_branch" {
  description = "Branch that triggers a pipeline run on push."
  type        = string
  default     = "main"
}

variable "state_bucket_name" {
  description = "The infra/env Terraform backend's S3 bucket - both CodeBuild roles need access to it to run init/plan/apply."
  type        = string
}

variable "ecr_repository_arn" {
  description = "Feed Service ECR repo ARN - the build stage needs push access scoped to just this repo."
  type        = string
}

variable "terraform_version" {
  type    = string
  default = "1.15.9"
}

variable "frontend_bucket_name" {
  type = string
}

variable "frontend_bucket_arn" {
  type = string
}

variable "cloudfront_distribution_id" {
  type = string
}

variable "cloudfront_distribution_arn" {
  type = string
}
