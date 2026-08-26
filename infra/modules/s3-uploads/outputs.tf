output "bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.uploads.arn
}

output "bucket_regional_domain_name" {
  value = aws_s3_bucket.uploads.bucket_regional_domain_name
}
