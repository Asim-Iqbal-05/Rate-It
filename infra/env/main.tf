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

# --- Phase 4: API Gateway + write path -----------------------------------

module "api_gateway" {
  source = "../modules/api-gateway"

  project_name          = var.project_name
  aws_region            = var.aws_region
  cognito_user_pool_id  = module.cognito.user_pool_id
  cognito_app_client_id = module.cognito.app_client_id
  allowed_origins       = var.upload_cors_origins

  routes = {
    "GET /api/media/upload-url" = {
      function_name = module.media_service.function_name
      invoke_arn    = module.media_service.alias_invoke_arn
    }
    "POST /api/experiences" = {
      function_name = module.experience_service.function_name
      invoke_arn    = module.experience_service.alias_invoke_arn
    }
  }
}

# --- Phase 5: Feed Service (ECS Fargate) ----------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "../modules/vpc"

  project_name       = var.project_name
  aws_region         = var.aws_region
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "ecr" {
  source = "../modules/ecr"

  project_name = var.project_name
}

module "ecs_feed_service" {
  source = "../modules/ecs-feed-service"

  project_name       = var.project_name
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids

  table_name      = module.dynamodb.table_name
  table_arn       = module.dynamodb.table_arn
  feed_index_name = module.dynamodb.feed_index_name

  uploads_bucket_name = module.s3_uploads.bucket_name
  uploads_bucket_arn  = module.s3_uploads.bucket_arn

  ecr_repository_url  = module.ecr.repository_url
  container_image_tag = var.feed_service_image_tag
}

# VPC Link is the only path from API Gateway into the VPC (infra PRD
# §3) - its ENIs land in the private subnets, so they're already
# covered by the ALB security group's VPC-CIDR ingress rule.
resource "aws_security_group" "vpc_link" {
  name_prefix = "${var.project_name}-vpclink-"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_vpc_link" "feed" {
  name               = "${var.project_name}-feed-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = module.vpc.private_subnet_ids
}

resource "aws_apigatewayv2_integration" "feed" {
  api_id                 = module.api_gateway.api_id
  integration_type       = "HTTP_PROXY"
  integration_uri        = module.ecs_feed_service.alb_listener_arn
  integration_method     = "GET"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.feed.id
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "feed" {
  api_id             = module.api_gateway.api_id
  route_key          = "GET /api/feed"
  target             = "integrations/${aws_apigatewayv2_integration.feed.id}"
  authorization_type = "JWT"
  authorizer_id      = module.api_gateway.authorizer_id
}
