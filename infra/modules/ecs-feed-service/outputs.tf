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
