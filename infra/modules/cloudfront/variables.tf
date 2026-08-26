variable "project_name" {
  type = string
}

variable "domain_name" {
  description = "Full custom domain, e.g. rateit.internship.cloudelligent-sandbox.com"
  type        = string
}

variable "parent_zone_name" {
  description = "The existing, shared hosted zone this domain is a subdomain of. Never created or modified beyond adding this one record."
  type        = string
}

variable "frontend_bucket_name" {
  type = string
}

variable "frontend_bucket_arn" {
  type = string
}

variable "frontend_bucket_regional_domain_name" {
  type = string
}

variable "uploads_bucket_name" {
  type = string
}

variable "uploads_bucket_arn" {
  type = string
}

variable "uploads_bucket_regional_domain_name" {
  type = string
}

variable "api_gateway_domain" {
  description = "API Gateway hostname only, no scheme (e.g. abc123.execute-api.us-west-2.amazonaws.com)."
  type        = string
}
