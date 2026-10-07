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
    sid     = "ReadFeed"
    actions = ["dynamodb:Query"]
    resources = [
      var.table_arn,
      "${var.table_arn}/index/${var.feed_index_name}",
      "${var.table_arn}/index/${var.author_index_name}",
    ]
  }

  # The caller's own like rows and the per-post like counters.
  statement {
    sid       = "ReadLikes"
    actions   = ["dynamodb:BatchGetItem"]
    resources = [var.likes_table_arn, var.like_counters_table_arn]
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

# Two target groups, both wired into the service's native blue/green
# deployment config below (Phase 8) - "blue" is the primary/current
# target group, "green" is where ECS stands up the new task set during
# a deploy before flipping the production listener rule over to it.
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

# ECS's blue/green deployment_configuration needs a *listener rule* ARN
# to flip (production_listener_rule) - the listener's own default_action
# above isn't itself an addressable rule. This catch-all rule takes
# priority over the default_action, so it's what actually serves all
# traffic; the default_action becomes an unreachable fallback.
resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  # ECS overwrites this rule's target group on every blue/green deploy -
  # Terraform's last-applied value would otherwise fight the live state
  # on the next plan.
  lifecycle {
    ignore_changes = [action]
  }
}

# Dedicated infrastructure role so ECS can flip the listener rule above
# between the blue/green target groups on each deploy. Deliberately not
# the ECS service-linked role (AWSServiceRoleForECS) - AWS's own guidance
# is that it isn't authorized for elasticloadbalancing:ModifyRule, so
# blue/green needs this separate role with the dedicated managed policy.
data "aws_iam_policy_document" "ecs_infrastructure_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "${var.project_name}-feed-service-ecs-infra-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_infrastructure_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
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
        { name = "AUTHOR_INDEX_NAME", value = var.author_index_name },
        { name = "LIKES_TABLE_NAME", value = var.likes_table_name },
        { name = "LIKE_COUNTERS_TABLE_NAME", value = var.like_counters_table_name },
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

    advanced_configuration {
      alternate_target_group_arn = aws_lb_target_group.green.arn
      production_listener_rule   = aws_lb_listener_rule.production.arn
      role_arn                   = aws_iam_role.ecs_infrastructure.arn
    }
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_configuration {
    strategy             = "BLUE_GREEN"
    bake_time_in_minutes = var.bake_time_in_minutes
  }

  # Automatic rollback if the green task set fails to stabilize, or
  # (thanks to the alarms block) if it stabilizes but starts erroring
  # during bake time - either way ECS shifts traffic back to blue.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Blue/green temporarily runs both target groups' worth of tasks -
  # 200% max means a full second copy is allowed to stand up alongside
  # the original before the old one is torn down.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # Bake-time gating (infra PRD §9): if either target group's unhealthy
  # host alarm trips while both blue and green are running side by side
  # during bake time, ECS rolls back on its own instead of waiting for
  # someone to notice - the alarm-driven half of the safety net that
  # deployment_circuit_breaker (stabilization failures) doesn't cover.
  alarms {
    alarm_names = [
      aws_cloudwatch_metric_alarm.unhealthy_hosts_blue.alarm_name,
      aws_cloudwatch_metric_alarm.unhealthy_hosts_green.alarm_name,
    ]
    enable   = true
    rollback = true
  }

  # Once Application Auto Scaling (below) is registered, it owns
  # desired_count live - without this, every `terraform apply` would
  # fight it and stomp desiredCount back to var.desired_count.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# --- Autoscaling -----------------------------------------------------------
# Target tracking on CPU: simpler and more common than request-count
# tracking, and this service's own CloudWatch CPU alarm (below) already
# uses the same metric, so the two stay conceptually aligned - the
# alarm is a backstop/notification, the scaling target here is meant
# to react well before CPU ever gets that high.

resource "aws_appautoscaling_target" "feed_service" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min_capacity
  max_capacity       = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_policy" "feed_service_cpu" {
  name               = "${var.project_name}-feed-service-cpu-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.feed_service.service_namespace
  resource_id        = aws_appautoscaling_target.feed_service.resource_id
  scalable_dimension = aws_appautoscaling_target.feed_service.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = var.autoscaling_cpu_target
    # Scale out quickly when load actually shows up; scale back in
    # slowly so a brief dip doesn't immediately tear down a task that
    # real traffic might need again a minute later.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts_blue" {
  alarm_name          = "${var.project_name}-feed-blue-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Feed Service blue target group has unhealthy hosts."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.blue.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts_green" {
  alarm_name          = "${var.project_name}-feed-green-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Feed Service green target group has unhealthy hosts."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.green.arn_suffix
  }
}
