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

output "likes_table_name" {
  value = aws_dynamodb_table.likes.name
}

output "likes_table_arn" {
  value = aws_dynamodb_table.likes.arn
}

output "likes_stream_arn" {
  value = aws_dynamodb_table.likes.stream_arn
}

output "like_counters_table_name" {
  value = aws_dynamodb_table.like_counters.name
}

output "like_counters_table_arn" {
  value = aws_dynamodb_table.like_counters.arn
}
