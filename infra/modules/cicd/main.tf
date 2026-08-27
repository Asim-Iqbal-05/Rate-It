data "aws_caller_identity" "current" {}

# --- Source connection ------------------------------------------------
# Terraform can create this, but AWS deliberately requires a human to
# click "Authorize" in the console (Developer Tools > Settings >
# Connections) before it can actually read the GitHub repo - there's no
# API for that consent step. Status stays PENDING until that happens.
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.project_name}-github"
  provider_type = "GitHub"
}

# --- Artifacts bucket ---------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project_name}-cicd-artifacts-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CodePipeline needs versioning on its artifact bucket - each stage
# transition reads/writes a new object version.
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# --- IAM: CodePipeline itself --------------------------------------------

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.project_name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}

data "aws_iam_policy_document" "codepipeline" {
  statement {
    sid       = "ArtifactBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "UseGithubConnection"
    actions   = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.github.arn]
  }

  statement {
    sid       = "RunCodeBuildProjects"
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.plan.arn, aws_codebuild_project.apply.arn]
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "${var.project_name}-codepipeline-policy"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}

# --- IAM: CodeBuild "plan" stage (builds+pushes the image, runs
# terraform plan - read-only against real infra, write-only against
# ECR/the artifact bucket/the state bucket's lock file) -----------------

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_plan" {
  name               = "${var.project_name}-codebuild-plan-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild_plan" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*"]
  }

  statement {
    sid       = "ArtifactBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  # terraform init/plan against the real backend: reads state, and
  # writes/deletes the native S3 lock file for the duration of the plan.
  statement {
    sid       = "TerraformStateBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}", "arn:aws:s3:::${var.state_bucket_name}/*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushFeedServiceOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "codebuild_plan" {
  name   = "${var.project_name}-codebuild-plan-policy"
  role   = aws_iam_role.codebuild_plan.id
  policy = data.aws_iam_policy_document.codebuild_plan.json
}

# `terraform plan` reads across every service the stack touches (VPC,
# ECS, Lambda, API Gateway, CloudFront, WAF, Route 53, ACM, DynamoDB,
# S3, IAM) - a read-only managed policy is the practical way to cover
# that breadth without hand-listing every describe/get/list action.
resource "aws_iam_role_policy_attachment" "codebuild_plan_readonly" {
  role       = aws_iam_role.codebuild_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- IAM: CodeBuild "apply" stage (actually creates/changes/destroys
# real infra - this is the same breadth of access the user's own CLI
# credentials already exercise every time they run `terraform apply`
# by hand; moving that command into the pipeline doesn't reduce what it
# needs to be able to touch) ----------------------------------------

resource "aws_iam_role" "codebuild_apply" {
  name               = "${var.project_name}-codebuild-apply-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild_apply" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*"]
  }

  statement {
    sid       = "ArtifactBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "TerraformStateBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}", "arn:aws:s3:::${var.state_bucket_name}/*"]
  }

  # PowerUserAccess (below) explicitly excludes IAM management, but
  # Terraform's own resources include a handful of IAM roles (Lambda
  # execution/task roles, the ECS execution/task/infra roles) - scoped
  # here to only role names this project actually creates, never IAM
  # broadly (no user/group management, no roles outside this prefix).
  statement {
    sid = "ManageProjectIamRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_apply" {
  name   = "${var.project_name}-codebuild-apply-policy"
  role   = aws_iam_role.codebuild_apply.id
  policy = data.aws_iam_policy_document.codebuild_apply.json
}

resource "aws_iam_role_policy_attachment" "codebuild_apply_poweruser" {
  role       = aws_iam_role.codebuild_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# --- CodeBuild projects --------------------------------------------------

locals {
  # Builds the feed-service image, pushes it under the commit SHA,
  # then runs `terraform plan` against that new tag and prints the
  # human-readable plan straight into the build log - the reviewer
  # checks this log before approving, since CodePipeline's manual
  # approval action can't embed the plan text itself.
  plan_buildspec = <<-EOT
  version: 0.2
  env:
    variables:
      TF_VERSION: "${var.terraform_version}"
  phases:
    install:
      commands:
        - curl -sL -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/$TF_VERSION/terraform_$${TF_VERSION}_linux_amd64.zip
        - unzip -o /tmp/terraform.zip -d /usr/local/bin
    pre_build:
      commands:
        - aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
        - IMAGE_TAG=$(echo "$CODEBUILD_RESOLVED_SOURCE_VERSION" | cut -c1-12)
        - echo "$IMAGE_TAG" > image_tag.txt
    build:
      commands:
        - ECR_REPO_URL=$(echo "${var.ecr_repository_arn}" | cut -d'/' -f2)
        - ECR_REPO_URL="${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/$ECR_REPO_URL"
        - docker build -t "$ECR_REPO_URL:$IMAGE_TAG" services/feed
        - docker push "$ECR_REPO_URL:$IMAGE_TAG"
        - cd infra/env
        - terraform init -input=false
        - terraform plan -input=false -var "feed_service_image_tag=$IMAGE_TAG" -out=tfplan
        - terraform show -no-color tfplan | tee tfplan.txt
        - echo "===== Review the plan above, then approve or reject in the CodePipeline console ====="
  artifacts:
    files:
      - '**/*'
    base-directory: '.'
  EOT

  apply_buildspec = <<-EOT
  version: 0.2
  env:
    variables:
      TF_VERSION: "${var.terraform_version}"
  phases:
    install:
      commands:
        - curl -sL -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/$TF_VERSION/terraform_$${TF_VERSION}_linux_amd64.zip
        - unzip -o /tmp/terraform.zip -d /usr/local/bin
    build:
      commands:
        - cd infra/env
        - terraform init -input=false
        - terraform apply -input=false -auto-approve tfplan
  EOT
}

resource "aws_codebuild_project" "plan" {
  name         = "${var.project_name}-plan"
  service_role = aws_iam_role.codebuild_plan.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # needed to run `docker build` inside CodeBuild

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = local.plan_buildspec
  }
}

resource "aws_codebuild_project" "apply" {
  name         = "${var.project_name}-apply"
  service_role = aws_iam_role.codebuild_apply.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = local.apply_buildspec
  }
}

# --- Pipeline -------------------------------------------------------------

resource "aws_codepipeline" "this" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repo
        BranchName       = var.github_branch
      }
    }
  }

  stage {
    name = "Plan"
    action {
      name             = "BuildAndPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  # Pauses here so a human reviews the `terraform plan` output (printed
  # in the Plan stage's CodeBuild log) before anything is actually
  # applied - keeps the existing "review every apply" habit, just moves
  # the apply command itself into the pipeline instead of the terminal.
  stage {
    name = "Approve"
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "Review the terraform plan in the Plan stage's CodeBuild log before approving."
      }
    }
  }

  stage {
    name = "Apply"
    action {
      name            = "TerraformApply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.apply.name
      }
    }
  }
}
