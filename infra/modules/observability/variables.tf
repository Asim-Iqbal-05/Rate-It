variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "alarm_sns_topic_arn" {
  type = string
}

variable "alarm_sns_topic_arn_us_east_1" {
  description = "SNS topic in us-east-1, for the WAF alarms - a us-east-1 alarm can't notify a topic in another region (confirmed via direct AWS CLI reproduction, not a Terraform quirk)."
  type        = string
}

variable "media_service_function_name" {
  type = string
}

variable "experience_service_function_name" {
  type = string
}

variable "reactions_service_function_name" {
  type = string
}

variable "moderation_service_function_name" {
  type = string
}

variable "moderation_queue_name" {
  type = string
}

variable "moderation_iterator_age_threshold_ms" {
  description = "Alarm if the moderation stream mapping falls this far behind (default 5 minutes)."
  type        = number
  default     = 300000
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_blue_arn_suffix" {
  type = string
}

variable "target_group_green_arn_suffix" {
  type = string
}

variable "dynamodb_table_name" {
  type = string
}

variable "dynamodb_index_names" {
  description = "Experiences GSIs to alarm on. A throttled GSI also throttles writes to the base table, so the table-level alarm alone isn't enough."
  type        = list(string)
}

variable "dynamodb_reactions_table_name" {
  type = string
}

# WAF is CloudFront-scoped, so its CloudWatch metrics always publish to
# us-east-1 regardless of the app's home region - these alarms need the
# us_east_1 provider alias, same reason ACM/WAF resources themselves do.
variable "waf_web_acl_name" {
  type = string
}

variable "waf_token_rule_metric_name" {
  type = string
}

variable "waf_ip_rule_metric_name" {
  type = string
}

variable "lambda_error_threshold" {
  description = "Alarm if a Lambda has more than this many errors in one 5-minute window."
  type        = number
  default     = 3
}

variable "lambda_duration_threshold_ms" {
  description = "Alarm if average Lambda duration exceeds this many milliseconds - both Lambdas have a default timeout well above this, so it's an early-warning signal, not a timeout proxy."
  type        = number
  default     = 3000
}

variable "dynamodb_throttle_threshold" {
  description = "Alarm if DynamoDB throttles more than this many requests in one 5-minute window."
  type        = number
  default     = 1
}

variable "waf_blocked_request_threshold" {
  description = "Alarm if WAF blocks more than this many requests in one 5-minute window - a real burst of abuse, not routine rate-limit noise."
  type        = number
  default     = 100
}
