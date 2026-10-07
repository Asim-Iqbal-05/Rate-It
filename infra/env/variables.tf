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
  description = "Image tag in the Feed Service ECR repo to deploy - always pass explicitly (the pipeline always does). No default on purpose: a stale \"latest\" default previously caused a real incident where a bare `terraform apply` silently reverted Feed Service to an old image (docs/postmortem-phase9-observability.md) - failing loudly here beats that."
  type        = string
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

variable "alarm_email" {
  description = "Where CloudWatch alarm notifications are sent (infra PRD §9). AWS emails a one-time confirmation link that must be clicked before delivery starts."
  type        = string
  default     = "asim.iqbal@cloudelligent.com"
}

variable "waf_rate_limit" {
  description = "Max requests per 5-minute window per auth token (or per IP when unauthenticated) before WAF returns 429. Raised from the original 50 so liking while scrolling doesn't trip it (extension PRD §8.3) - tune from WAF metrics."
  type        = number
  default     = 300
}
