output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_app_client_id" {
  value = module.cognito.app_client_id
}

output "experiences_table_name" {
  value = module.dynamodb.table_name
}

output "experiences_table_feed_index_name" {
  value = module.dynamodb.feed_index_name
}

output "uploads_bucket_name" {
  value = module.s3_uploads.bucket_name
}

output "frontend_bucket_name" {
  value = module.s3_frontend.bucket_name
}
