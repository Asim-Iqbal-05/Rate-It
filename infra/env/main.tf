module "cognito" {
  source = "../modules/cognito"

  project_name = var.project_name
}

module "dynamodb" {
  source = "../modules/dynamodb"

  project_name = var.project_name
}

module "s3_uploads" {
  source = "../modules/s3-uploads"

  project_name    = var.project_name
  allowed_origins = var.upload_cors_origins
}

module "s3_frontend" {
  source = "../modules/s3-frontend"

  project_name = var.project_name
}

# --- Phase 3: Lambda services --------------------------------------------

data "aws_iam_policy_document" "media_service" {
  statement {
    sid       = "IssueUploadUrls"
    actions   = ["s3:PutObject", "s3:PutObjectTagging"]
    resources = ["${module.s3_uploads.bucket_arn}/*"]
  }
}

module "media_service" {
  source = "../modules/lambda-function"

  function_name = "${var.project_name}-media-service"
  source_dir    = "${path.module}/../../services/media"
  handler       = "handler.lambda_handler"

  environment_variables = {
    UPLOADS_BUCKET = module.s3_uploads.bucket_name
  }

  additional_policy_json = data.aws_iam_policy_document.media_service.json
}

data "aws_iam_policy_document" "experience_service" {
  statement {
    sid       = "WriteExperiences"
    actions   = ["dynamodb:PutItem"]
    resources = [module.dynamodb.table_arn]
  }

  statement {
    sid       = "ClaimUploadedImage"
    actions   = ["s3:GetObjectTagging", "s3:PutObjectTagging"]
    resources = ["${module.s3_uploads.bucket_arn}/*"]
  }
}

module "experience_service" {
  source = "../modules/lambda-function"

  function_name = "${var.project_name}-experience-service"
  source_dir    = "${path.module}/../../services/experience"
  handler       = "handler.lambda_handler"

  environment_variables = {
    TABLE_NAME     = module.dynamodb.table_name
    UPLOADS_BUCKET = module.s3_uploads.bucket_name
  }

  additional_policy_json = data.aws_iam_policy_document.experience_service.json
}
