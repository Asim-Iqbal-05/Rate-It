variable "aws_region" {
  description = "AWS region for all rateit infrastructure (single-environment project)."
  type        = string
  default     = "us-west-2" # Oregon
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform remote state."
  type        = string
  default     = "rateit-terraform-state"
}
