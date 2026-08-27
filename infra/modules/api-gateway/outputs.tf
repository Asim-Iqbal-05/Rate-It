output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "execution_arn" {
  value = aws_apigatewayv2_api.this.execution_arn
}

output "authorizer_id" {
  value = aws_apigatewayv2_authorizer.cognito.id
}

output "stage_arn" {
  value = aws_apigatewayv2_stage.default.arn
}
