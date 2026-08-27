output "connection_arn" {
  value = aws_codestarconnections_connection.github.arn
}

output "pipeline_name" {
  value = aws_codepipeline.this.name
}
