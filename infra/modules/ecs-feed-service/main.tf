resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project_name}-feed-service"
  retention_in_days = 14
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pulls the image, writes logs. Standard managed policy.
resource "aws_iam_role" "execution" {
  name               = "${var.project_name}-feed-service-execution-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: what the running application itself can do - least
# privilege scoped to exactly the table/GSI and bucket it reads from.
resource "aws_iam_role" "task" {
  name               = "${var.project_name}-feed-service-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
}

data "aws_iam_policy_document" "task_permissions" {
  statement {
    sid       = "ReadFeed"
    actions   = ["dynamodb:Query"]
    resources = [var.table_arn, "${var.table_arn}/index/${var.feed_index_name}"]
  }

  # No S3 permissions: since Phase 6, image URLs are constructed as
  # plain CloudFront links (PUBLIC_IMAGE_BASE_URL), not presigned -
  # the task itself never calls S3 directly anymore.
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.project_name}-feed-service-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_permissions.json
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-feed-alb-"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from within the VPC - the VPC Link is the only path in"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

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

resource "aws_security_group" "service" {
  name_prefix = "${var.project_name}-feed-service-"
  vpc_id      = var.vpc_id

  ingress {
    description     = "From the ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

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

resource "aws_lb" "this" {
  name               = "${var.project_name}-feed-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

# Two target groups exist now even though only "blue" is wired to the
# service today (standard rolling deploys) - infra PRD §8.1 notes this
# is structurally required for blue/green, not incidental cost. Native
# ECS blue/green wiring (deployment_configuration.strategy) isn't in
# the installed provider's schema (v5.100) - deferred to Phase 8
# (CI/CD automation), which already owns that scope per the PRD.
resource "aws_lb_target_group" "blue" {
  name        = "${var.project_name}-feed-blue"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.project_name}-feed-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.project_name}-feed-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "feed-service"
      image     = "${var.ecr_repository_url}:${var.container_image_tag}"
      essential = true
      portMappings = [
        { containerPort = var.container_port, protocol = "tcp" }
      ]
      environment = [
        { name = "TABLE_NAME", value = var.table_name },
        { name = "FEED_INDEX_NAME", value = var.feed_index_name },
        { name = "PUBLIC_IMAGE_BASE_URL", value = var.public_image_base_url },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "feed-service"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = "${var.project_name}-feed-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "feed-service"
    container_port   = var.container_port
  }

  deployment_controller {
    type = "ECS"
  }

  # Automatic rollback if a new task set fails to stabilize - the
  # available safety net today, ahead of full blue/green in Phase 8.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
