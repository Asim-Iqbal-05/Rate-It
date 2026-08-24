variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cognito_user_pool_id" {
  type = string
}

variable "cognito_app_client_id" {
  type = string
}

variable "allowed_origins" {
  description = "Origins allowed to call this API from the browser (frontend dev server + deployed domain)."
  type        = list(string)
}

variable "routes" {
  description = "Map of \"METHOD /path\" => { function_name, invoke_arn } for Lambda-backed routes."
  type = map(object({
    function_name = string
    invoke_arn    = string
  }))
  default = {}
}
