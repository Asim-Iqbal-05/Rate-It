variable "project_name" {
  type = string
}

variable "rate_limit" {
  description = "Max requests per 5-minute evaluation window per key (per token, or per IP for unauthenticated requests) before blocking with 429. Infra PRD §6 example: 50."
  type        = number
  default     = 50
}
