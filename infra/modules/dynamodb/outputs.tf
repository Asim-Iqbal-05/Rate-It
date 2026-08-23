output "table_name" {
  value = aws_dynamodb_table.experiences.name
}

output "table_arn" {
  value = aws_dynamodb_table.experiences.arn
}

output "feed_index_name" {
  value = "TypeCreatedAtIndex"
}
