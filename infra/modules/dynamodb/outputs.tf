output "table_name" {
  value = aws_dynamodb_table.experiences.name
}

output "table_arn" {
  value = aws_dynamodb_table.experiences.arn
}

output "feed_index_name" {
  value = "TypeCreatedAtIndex"
}

output "stream_arn" {
  value = aws_dynamodb_table.experiences.stream_arn
}

output "author_index_name" {
  value = "userId-CreatedAt-index"
}

output "reactions_table_name" {
  value = aws_dynamodb_table.reactions.name
}

output "reactions_table_arn" {
  value = aws_dynamodb_table.reactions.arn
}
