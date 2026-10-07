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

variable "manage_log_group" {
  description = "Create the function's CloudWatch log group in Terraform. Needed for new functions: the account's SCP rejects untagged CreateLogGroup calls, which is what Lambda's automatic creation makes, so without this the function silently has no logs. Leave false for functions whose log group already exists (it would fail with ResourceAlreadyExists)."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "attach_additional_policy" {
  description = "Attach additional_policy_json. A plain flag rather than a null check on the policy itself: a policy built from resources that don't exist yet is unknown at plan time, and Terraform can't size a `count` from an unknown value. Set false for a function that needs nothing beyond CloudWatch Logs."
  type        = bool
  default     = true
}
