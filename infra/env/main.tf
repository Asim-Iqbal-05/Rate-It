data "aws_caller_identity" "current" {}

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

# --- Extension: Reactions Service (likes) ---------------------------------

data "aws_iam_policy_document" "reactions_service" {
  statement {
    sid       = "WriteReactions"
    actions   = ["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem"]
    resources = [module.dynamodb.reactions_table_arn]
  }

  # Read-only existence check on the post inside the like transaction -
  # no write access to Experiences (extension PRD §4, invariant 1).
  statement {
    sid       = "CheckPostExists"
    actions   = ["dynamodb:ConditionCheckItem"]
    resources = [module.dynamodb.table_arn]
  }
}

module "reactions_service" {
  source = "../modules/lambda-function"

  function_name    = "${var.project_name}-reactions-service"
  manage_log_group = true
  source_dir       = "${path.module}/../../services/reactions"
  handler          = "handler.lambda_handler"
  memory_size      = 256
  timeout          = 5

  environment_variables = {
    REACTIONS_TABLE   = module.dynamodb.reactions_table_name
    EXPERIENCES_TABLE = module.dynamodb.table_name
  }

  additional_policy_json = data.aws_iam_policy_document.reactions_service.json
}

# --- Extension: Moderation Service ----------------------------------------

# Holds posts that couldn't be moderated (Rekognition down, unreadable
# image, ...) until someone works the queue. Also the stream mapping's
# on-failure destination. Extension PRD §7.3.
locals {
  moderation_queue_name = "${var.project_name}-moderation-dlq"
  moderation_queue_arn  = "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${local.moderation_queue_name}"
}

resource "aws_sqs_queue" "moderation_dlq" {
  name                       = local.moderation_queue_name
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 360     # 6x the function timeout
  sqs_managed_sse_enabled    = true
}

data "aws_iam_policy_document" "moderation_service" {
  statement {
    sid       = "ReadExperiencesStream"
    actions   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator"]
    resources = [module.dynamodb.stream_arn]
  }

  # ListStreams can't be scoped to a stream ARN.
  statement {
    sid       = "ListStreams"
    actions   = ["dynamodb:ListStreams"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAndTakeDownPosts"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [module.dynamodb.table_arn]
  }

  # Rekognition reads the image with this role's own S3 permission, so
  # this one grant covers both the magic-byte check and DetectModerationLabels.
  statement {
    sid       = "ReadUploads"
    actions   = ["s3:GetObject"]
    resources = ["${module.s3_uploads.bucket_arn}/*"]
  }

  statement {
    sid       = "Moderate"
    actions   = ["rekognition:DetectModerationLabels"]
    resources = ["*"]
  }

  statement {
    sid = "ModerationQueue"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    # Built from the name rather than aws_sqs_queue.arn: the lambda-function
    # module branches on whether this policy exists, which Terraform can't
    # do with a value only known after apply.
    resources = [local.moderation_queue_arn]
  }
}

module "moderation_service" {
  source = "../modules/lambda-function"

  function_name    = "${var.project_name}-moderation-service"
  manage_log_group = true
  source_dir       = "${path.module}/../../services/moderation"
  handler          = "handler.lambda_handler"
  memory_size      = 512
  timeout          = 60

  environment_variables = {
    UPLOADS_BUCKET     = module.s3_uploads.bucket_name
    EXPERIENCES_TABLE  = module.dynamodb.table_name
    QUEUE_URL          = aws_sqs_queue.moderation_dlq.url
    MIN_CONFIDENCE     = tostring(var.moderation_min_confidence)
    BLOCKED_CATEGORIES = join(",", var.moderation_blocked_categories)
  }

  additional_policy_json = data.aws_iam_policy_document.moderation_service.json
}

# New posts only: INSERT, never the takedown (MODIFY) or a delete
# (REMOVE). Targets the alias, not $LATEST. depends_on the whole module
# so the role's stream permissions exist before Lambda validates them.
resource "aws_lambda_event_source_mapping" "moderation_stream" {
  event_source_arn  = module.dynamodb.stream_arn
  function_name     = module.moderation_service.alias_arn
  starting_position = "LATEST"

  batch_size                     = 10
  maximum_retry_attempts         = 3 # the default retries until the record expires and blocks the shard
  bisect_batch_on_function_error = true
  maximum_record_age_in_seconds  = 3600
  function_response_types        = ["ReportBatchItemFailures"]

  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["INSERT"] })
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.moderation_dlq.arn
    }
  }

  depends_on = [module.moderation_service]
}

# Redrive: created DISABLED on purpose - a post that can never succeed
# would otherwise loop forever. An operator enables it to drain the
# queue after fixing the cause (README runbook), then disables it
# again; a later apply resetting it to disabled is the intended
# behaviour, so `enabled` is deliberately not in ignore_changes.
resource "aws_lambda_event_source_mapping" "moderation_redrive" {
  event_source_arn        = aws_sqs_queue.moderation_dlq.arn
  function_name           = module.moderation_service.alias_arn
  enabled                 = false
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  depends_on = [module.moderation_service]
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
    "PUT /api/experiences/{experienceId}/like" = {
      function_name = module.reactions_service.function_name
      invoke_arn    = module.reactions_service.alias_invoke_arn
    }
    "DELETE /api/experiences/{experienceId}/like" = {
      function_name = module.reactions_service.function_name
      invoke_arn    = module.reactions_service.alias_invoke_arn
    }
  }
}

# --- Phase 9: Observability (SNS topic declared early - both the Feed
# Service's bake-time alarm gating and the broader observability module
# need its ARN) -------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# CloudWatch alarms on CloudFront-scoped WAF metrics must themselves
# live in us-east-1 (confirmed - not just the alarm resource, AWS
# genuinely rejects the PutMetricAlarm call with "Invalid region
# us-west-2 specified" even though the alarm itself is correctly
# created in us-east-1). Less obviously, AWS *also* rejects that same
# alarm if its alarm_actions/ok_actions point at an SNS topic in a
# different region - cross-region alarm notification isn't allowed
# here, confirmed by reproducing the exact error via the AWS CLI
# directly (no Terraform involved) before concluding it wasn't a
# provider bug. Hence a second, us-east-1-only topic just for these.
resource "aws_sns_topic" "alerts_us_east_1" {
  provider = aws.us_east_1
  name     = "${var.project_name}-alerts-us-east-1"
}

resource "aws_sns_topic_subscription" "alerts_us_east_1_email" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alerts_us_east_1.arn
  protocol  = "email"
  endpoint  = var.alarm_email
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

  author_index_name    = module.dynamodb.author_index_name
  reactions_table_name = module.dynamodb.reactions_table_name
  reactions_table_arn  = module.dynamodb.reactions_table_arn

  public_image_base_url = "https://${var.custom_domain_name}"

  ecr_repository_url  = module.ecr.repository_url
  container_image_tag = var.feed_service_image_tag

  alarm_sns_topic_arn = aws_sns_topic.alerts.arn
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

  # Tell Feed Service who is calling. "overwrite" replaces any header the
  # client sent with the same name, so the caller can't forge it; the
  # value comes from the already-verified JWT (extension PRD §7.6).
  request_parameters = {
    "overwrite:header.x-user-sub" = "$context.authorizer.claims.sub"
  }
}

resource "aws_apigatewayv2_route" "feed" {
  api_id             = module.api_gateway.api_id
  route_key          = "GET /api/feed"
  target             = "integrations/${aws_apigatewayv2_integration.feed.id}"
  authorization_type = "JWT"
  authorizer_id      = module.api_gateway.authorizer_id
}

# --- Phase 7: Abuse hardening (declared before Phase 6's CloudFront so
# the web ACL exists to attach - AWS WAF can't attach directly to an
# HTTP API stage at all, only to CloudFront/ALB/REST APIs/etc, so this
# attaches at CloudFront instead) -------------------------------------

module "waf" {
  source = "../modules/waf"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.project_name
  rate_limit   = var.waf_rate_limit
}

# --- Phase 6: Edge delivery ------------------------------------------------

module "cloudfront" {
  source = "../modules/cloudfront"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name     = var.project_name
  domain_name      = var.custom_domain_name
  parent_zone_name = var.parent_dns_zone_name

  frontend_bucket_name                 = module.s3_frontend.bucket_name
  frontend_bucket_arn                  = module.s3_frontend.bucket_arn
  frontend_bucket_regional_domain_name = module.s3_frontend.bucket_regional_domain_name

  uploads_bucket_name                 = module.s3_uploads.bucket_name
  uploads_bucket_arn                  = module.s3_uploads.bucket_arn
  uploads_bucket_regional_domain_name = module.s3_uploads.bucket_regional_domain_name

  api_gateway_domain = trimprefix(module.api_gateway.api_endpoint, "https://")

  web_acl_arn = module.waf.web_acl_arn
}

# --- Phase 8b: CI/CD automation -------------------------------------------

module "cicd" {
  source = "../modules/cicd"

  project_name       = var.project_name
  aws_region         = var.aws_region
  github_repo        = "Asim-Iqbal-05/Rate-It"
  state_bucket_name  = "rateit-terraform-state-cc5244ae"
  ecr_repository_arn = module.ecr.repository_arn

  frontend_bucket_name = module.s3_frontend.bucket_name
  frontend_bucket_arn  = module.s3_frontend.bucket_arn

  cloudfront_distribution_id  = module.cloudfront.distribution_id
  cloudfront_distribution_arn = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${module.cloudfront.distribution_id}"
}

# --- Phase 9: Observability (alarms + dashboard) --------------------------

module "observability" {
  source = "../modules/observability"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.project_name
  aws_region   = var.aws_region

  alarm_sns_topic_arn           = aws_sns_topic.alerts.arn
  alarm_sns_topic_arn_us_east_1 = aws_sns_topic.alerts_us_east_1.arn

  media_service_function_name      = module.media_service.function_name
  experience_service_function_name = module.experience_service.function_name
  reactions_service_function_name  = module.reactions_service.function_name
  moderation_service_function_name = module.moderation_service.function_name
  moderation_queue_name            = aws_sqs_queue.moderation_dlq.name

  ecs_cluster_name              = module.ecs_feed_service.cluster_name
  ecs_service_name              = module.ecs_feed_service.service_name
  alb_arn_suffix                = module.ecs_feed_service.alb_arn_suffix
  target_group_blue_arn_suffix  = module.ecs_feed_service.target_group_blue_arn_suffix
  target_group_green_arn_suffix = module.ecs_feed_service.target_group_green_arn_suffix

  dynamodb_table_name           = module.dynamodb.table_name
  dynamodb_index_names          = [module.dynamodb.feed_index_name, module.dynamodb.author_index_name]
  dynamodb_reactions_table_name = module.dynamodb.reactions_table_name

  waf_web_acl_name           = module.waf.web_acl_name
  waf_token_rule_metric_name = module.waf.token_rule_metric_name
  waf_ip_rule_metric_name    = module.waf.ip_rule_metric_name
}
