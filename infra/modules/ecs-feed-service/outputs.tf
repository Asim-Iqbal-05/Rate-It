output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_listener_arn" {
  value = aws_lb_listener.http.arn
}

output "vpc_link_security_group_id" {
  description = "Attach the API Gateway VPC Link to this SG's source when creating it, or allow it into the ALB SG."
  value       = aws_security_group.alb.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "alb_arn_suffix" {
  description = "For CloudWatch ALB metric dimensions (e.g. RequestCount, TargetResponseTime)."
  value       = aws_lb.this.arn_suffix
}

output "target_group_blue_arn_suffix" {
  value = aws_lb_target_group.blue.arn_suffix
}

output "target_group_green_arn_suffix" {
  value = aws_lb_target_group.green.arn_suffix
}
