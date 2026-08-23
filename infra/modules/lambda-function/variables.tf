variable "function_name" {
  description = "Lambda function name."
  type        = string
}

variable "source_dir" {
  description = "Directory containing the function's Python source (zipped as-is, no build step)."
  type        = string
}

variable "handler" {
  description = "Handler entrypoint, e.g. \"handler.lambda_handler\"."
  type        = string
}

variable "runtime" {
  description = "Lambda Python runtime."
  type        = string
  default     = "python3.13"
}

variable "memory_size" {
  type    = number
  default = 128
}

variable "timeout" {
  type    = number
  default = 10
}

variable "environment_variables" {
  description = "Environment variables for the function."
  type        = map(string)
  default     = {}
}

variable "additional_policy_json" {
  description = "Extra IAM policy document (JSON) granted to this function's role, beyond basic CloudWatch Logs execution. Null = none."
  type        = string
  default     = null
}
