terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# No build step: these services have zero third-party dependencies
# (boto3 ships with the Lambda Python runtime), so the source directory
# is zipped as-is.
locals {
  # Compiled caches that appear locally after running a service's tests
  # (and never in a fresh CI checkout) are not part of the package.
  ignored_files = [
    for f in fileset(var.source_dir, "**") : f
    if strcontains(f, "__pycache__") || endswith(f, ".pyc")
  ]

  package_files = sort([
    for f in fileset(var.source_dir, "**") : f
    if !contains(local.ignored_files, f)
  ])

  # Hash of the file CONTENTS, not of the zip. The zip's bytes also depend
  # on file modification times (and permissions), which differ between a
  # local checkout and CodeBuild's fresh `git checkout` - so hashing the zip
  # made every plan show every Lambda as "changed" even when no code had.
  # A content hash only changes when the code does.
  source_hash = base64sha256(join("\n", [
    for f in local.package_files : "${f}:${filesha256("${var.source_dir}/${f}")}"
  ]))
}

data "archive_file" "package" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/dist/${var.function_name}.zip"
  excludes    = local.ignored_files
}

resource "aws_iam_role" "this" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs only - least privilege beyond this is supplied per
# service via var.additional_policy_json (e.g. the one DynamoDB table
# and S3 bucket it actually needs, nothing broader).
resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "additional" {
  count  = var.attach_additional_policy ? 1 : 0
  name   = "${var.function_name}-additional"
  role   = aws_iam_role.this.id
  policy = var.additional_policy_json
}

resource "aws_cloudwatch_log_group" "this" {
  count             = var.manage_log_group ? 1 : 0
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  role          = aws_iam_role.this.arn

  filename         = data.archive_file.package.output_path
  source_code_hash = local.source_hash

  handler = var.handler
  runtime = var.runtime

  memory_size = var.memory_size
  timeout     = var.timeout

  # Publishing a numbered version on every deploy + a stable alias
  # pointing at it is the versioned-alias deploy strategy from infra
  # PRD §8.2 - Terraform naturally does this when the zip hash changes.
  publish = true

  depends_on = [aws_cloudwatch_log_group.this]

  dynamic "environment" {
    for_each = length(var.environment_variables) > 0 ? [1] : []
    content {
      variables = var.environment_variables
    }
  }
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version
}
