# HTTP API: the single public entry point for every backend call, and
# the one place auth is enforced (infra PRD §5) - this is deliberate,
# not a default. Feed Service's VPC-Link route (Phase 5) attaches to
# this same API later, same authorizer.
resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  # Browser calls come directly from the frontend's own origin, not
  # from inside AWS - needs explicit CORS, same origins as the uploads
  # bucket's CORS config.
  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

# A bad or expired token never reaches Lambda or ECS (infra PRD §5) -
# validated here, once, for every route on this API.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "${var.project_name}-cognito-authorizer"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [var.cognito_app_client_id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

# One Lambda proxy integration + JWT-authorized route + invoke
# permission per entry in var.routes. Each integration targets the
# function's "live" alias (Phase 3), never $LATEST, so a route always
# points at the last successfully published version.
resource "aws_apigatewayv2_integration" "this" {
  for_each = var.routes

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  for_each = var.routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.key].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "this" {
  for_each = var.routes

  # Lambda statement IDs only allow [A-Za-z0-9_-], so path-parameter
  # braces in a route key ("{experienceId}") have to go too.
  statement_id  = "AllowInvokeFrom-${replace(replace(replace(replace(each.key, " ", "-"), "/", "-"), "{", ""), "}", "")}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  qualifier     = "live"
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
