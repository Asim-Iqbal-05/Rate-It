variable "aws_region" {
  description = "AWS region for all rateit infrastructure (single-environment project)."
  type        = string
  default     = "us-west-2" # Oregon
}

variable "project_name" {
  description = "Short project name, used as a prefix for resource names."
  type        = string
  default     = "rateit"
}

variable "upload_cors_origins" {
  description = "Origins allowed to POST/PUT directly to the uploads bucket."
  type        = list(string)
  default = [
    "http://localhost:5173", # Vite dev server
    "https://rateit.internship.cloudelligent-sandbox.com",
  ]
}

variable "feed_service_image_tag" {
  description = "Image tag in the Feed Service ECR repo to deploy. Build and push it before applying, or the ECS service will fail to pull on first launch."
  type        = string
  default     = "latest"
}

variable "custom_domain_name" {
  description = "The app's real domain, a subdomain of the shared internship zone."
  type        = string
  default     = "rateit.internship.cloudelligent-sandbox.com"
}

variable "parent_dns_zone_name" {
  description = "The existing, shared Route 53 hosted zone - looked up, never created."
  type        = string
  default     = "internship.cloudelligent-sandbox.com"
}
