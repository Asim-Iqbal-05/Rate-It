terraform {
  # >= 1.10 required for S3 native state locking (`use_lockfile`),
  # used by infra/env instead of a DynamoDB lock table.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # No remote backend here on purpose: this stack creates the remote
  # state backend for everything else. It manages its own state locally
  # (state file should not be committed - see .gitignore).
}

provider "aws" {
  region = var.aws_region
}

# S3 bucket names are globally unique across all AWS accounts - suffix
# with a stable random ID so the default name doesn't collide with
# someone else's bucket.
resource "random_id" "state_bucket_suffix" {
  byte_length = 4
}

# Remote state bucket used by infra/env (and any future stacks).
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.state_bucket_name}-${random_id.state_bucket_suffix.hex}"

  # Personal project, single environment - protect against accidental
  # `terraform destroy` of the bucket holding all other stacks' state.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# No DynamoDB lock table: infra/env's backend config uses S3 native
# locking (`use_lockfile = true`), which writes a `.tflock` object
# alongside the state file in this same bucket - no separate table needed.
