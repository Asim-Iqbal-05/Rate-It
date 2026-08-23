data "aws_caller_identity" "current" {}

# Account ID suffix keeps the name globally unique without an extra
# random resource - deterministic, so re-running plan/apply never
# proposes renaming the bucket.
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.project_name}-uploads-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Direct browser-to-S3 presigned POST (app PRD §3.2) needs CORS on the
# bucket, since the request originates from the frontend's own origin,
# not from this AWS account's API.
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_methods = ["POST", "PUT"]
    allowed_origins = var.allowed_origins
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# Tag-based lifecycle (infra PRD §7.2): only objects still tagged
# status=pending after ~48h get expired - genuinely abandoned uploads
# only. Experience Service flips the tag to status=claimed right after
# the DynamoDB write succeeds, so claimed objects are never touched here.
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "expire-pending-uploads"
    status = "Enabled"

    filter {
      tag {
        key   = "status"
        value = "pending"
      }
    }

    expiration {
      days = 2 # ~48h; S3 lifecycle only supports day granularity
    }
  }
}
