output "web_acl_arn" {
  value = aws_wafv2_web_acl.api.arn
}

output "web_acl_name" {
  value = aws_wafv2_web_acl.api.name
}

output "token_rule_metric_name" {
  value = "${var.project_name}-rate-limit-by-token"
}

output "ip_rule_metric_name" {
  value = "${var.project_name}-rate-limit-by-ip"
}
