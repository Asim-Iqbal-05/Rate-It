terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# --- Lambda: error rate + duration (infra PRD §9) ------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = {
    media_service      = var.media_service_function_name
    experience_service = var.experience_service_function_name
    reactions_service  = var.reactions_service_function_name
    moderation_service = var.moderation_service_function_name
  }

  alarm_name          = "${var.project_name}-${replace(each.key, "_", "-")}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = var.lambda_error_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "${each.value} had more than ${var.lambda_error_threshold} errors in 5 minutes."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    FunctionName = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each = {
    media_service      = var.media_service_function_name
    experience_service = var.experience_service_function_name
    reactions_service  = var.reactions_service_function_name
  }

  alarm_name          = "${var.project_name}-${replace(each.key, "_", "-")}-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = var.lambda_duration_threshold_ms
  treat_missing_data  = "notBreaching"
  alarm_description   = "${each.value}'s average duration exceeded ${var.lambda_duration_threshold_ms}ms - early warning, not a timeout."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    FunctionName = each.value
  }
}

# --- ECS: task-level health (CPU is a free, always-on metric - no
# Container Insights needed - as a lightweight signal alongside the
# ALB target-group health alarms that live in ecs-feed-service, closer
# to the target groups they actually gate blue/green rollback on) -----

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.project_name}-feed-service-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_description   = "Feed Service CPU utilization sustained above 80%."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }
}

# --- DynamoDB: throttled requests -----------------------------------------

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${var.project_name}-experiences-table-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.dynamodb_throttle_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "DynamoDB throttled requests on the experiences table - on-demand billing shouldn't throttle at this project's traffic; investigate if this fires."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    TableName = var.dynamodb_table_name
  }
}

resource "aws_cloudwatch_metric_alarm" "reactions_table_throttles" {
  alarm_name          = "${var.project_name}-reactions-table-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.dynamodb_throttle_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "DynamoDB throttled requests on the reactions table."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    TableName = var.dynamodb_reactions_table_name
  }
}

# Per-index throttling on the Experiences table. Index-level metrics
# aren't included in the table-level ThrottledRequests alarm above.
resource "aws_cloudwatch_metric_alarm" "experiences_index_throttles" {
  for_each = toset(var.dynamodb_index_names)

  alarm_name          = "${var.project_name}-experiences-${each.value}-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.dynamodb_throttle_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "Throttle events on Experiences index ${each.value} - a throttled index also throttles writes to the base table."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  metric_query {
    id          = "total"
    expression  = "reads + writes"
    label       = "Throttle events"
    return_data = true
  }

  metric_query {
    id = "reads"
    metric {
      metric_name = "ReadThrottleEvents"
      namespace   = "AWS/DynamoDB"
      period      = 300
      stat        = "Sum"
      dimensions = {
        TableName                = var.dynamodb_table_name
        GlobalSecondaryIndexName = each.value
      }
    }
  }

  metric_query {
    id = "writes"
    metric {
      metric_name = "WriteThrottleEvents"
      namespace   = "AWS/DynamoDB"
      period      = 300
      stat        = "Sum"
      dimensions = {
        TableName                = var.dynamodb_table_name
        GlobalSecondaryIndexName = each.value
      }
    }
  }
}

# --- Moderation: queue backlog and stream lag (extension PRD §9) --------

# Any message at all means a post couldn't be moderated and is waiting
# for a person (the system fails open, so it stays visible meanwhile).
resource "aws_cloudwatch_metric_alarm" "moderation_queue_not_empty" {
  alarm_name          = "${var.project_name}-moderation-queue-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Posts are waiting in the moderation dead-letter queue - see the redrive runbook in the README."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    QueueName = var.moderation_queue_name
  }
}

resource "aws_cloudwatch_metric_alarm" "moderation_iterator_age" {
  alarm_name          = "${var.project_name}-moderation-falling-behind"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "IteratorAge"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Maximum"
  threshold           = var.moderation_iterator_age_threshold_ms
  treat_missing_data  = "notBreaching"
  alarm_description   = "Moderation is more than 5 minutes behind the Experiences stream."
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    FunctionName = var.moderation_service_function_name
  }
}

# --- WAF: blocked-request rate -------------------------------------------
# CloudFront-scoped WAF metrics always publish to us-east-1 in
# CloudWatch, regardless of the app's home region (same reason the Web
# ACL itself and ACM certs for CloudFront do) - hence `region =
# "us-east-1"` on both alarms below, not var.aws_region. AWS also
# rejects a us-east-1 alarm whose alarm_actions/ok_actions point at an
# SNS topic in a different region (confirmed by reproducing the exact
# "Invalid region us-west-2 specified" error via the AWS CLI directly,
# with no Terraform involved, before ruling out a provider bug) - so
# these two use a dedicated us-east-1 topic, not the main one.

resource "aws_cloudwatch_metric_alarm" "waf_blocked_by_token" {
  region = "us-east-1"

  alarm_name          = "${var.project_name}-waf-blocked-by-token"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.waf_blocked_request_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "WAF blocked an unusually high number of per-token rate-limited requests - a real abuse burst, not routine noise."
  alarm_actions       = [var.alarm_sns_topic_arn_us_east_1]
  ok_actions          = [var.alarm_sns_topic_arn_us_east_1]

  dimensions = {
    WebACL = var.waf_web_acl_name
    Region = "CloudFront"
    Rule   = var.waf_token_rule_metric_name
  }
}

resource "aws_cloudwatch_metric_alarm" "waf_blocked_by_ip" {
  region = "us-east-1"

  alarm_name          = "${var.project_name}-waf-blocked-by-ip"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.waf_blocked_request_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "WAF blocked an unusually high number of per-IP rate-limited (unauthenticated) requests - a real abuse burst, not routine noise."
  alarm_actions       = [var.alarm_sns_topic_arn_us_east_1]
  ok_actions          = [var.alarm_sns_topic_arn_us_east_1]

  dimensions = {
    WebACL = var.waf_web_acl_name
    Region = "CloudFront"
    Rule   = var.waf_ip_rule_metric_name
  }
}

# --- Dashboard -------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.project_name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Lambda errors"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.media_service_function_name, { stat = "Sum", label = "media-service" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.experience_service_function_name, { stat = "Sum", label = "experience-service" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Lambda duration (avg ms)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.media_service_function_name, { stat = "Average", label = "media-service" }],
            ["AWS/Lambda", "Duration", "FunctionName", var.experience_service_function_name, { stat = "Average", label = "experience-service" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Feed Service: CPU + ALB target health"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { stat = "Average", label = "CPU %" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_blue_arn_suffix, { stat = "Maximum", label = "blue unhealthy hosts" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_green_arn_suffix, { stat = "Maximum", label = "green unhealthy hosts" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "DynamoDB throttled requests"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", var.dynamodb_table_name, { stat = "Sum" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 24, height = 6
        properties = {
          title   = "WAF blocked requests"
          region  = "us-east-1"
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", "CloudFront", "Rule", var.waf_token_rule_metric_name, { stat = "Sum", label = "blocked by token" }],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_web_acl_name, "Region", "CloudFront", "Rule", var.waf_ip_rule_metric_name, { stat = "Sum", label = "blocked by IP" }],
          ]
        }
      },
    ]
  })
}
