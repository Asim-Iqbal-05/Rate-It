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
