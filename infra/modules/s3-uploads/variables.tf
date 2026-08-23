variable "project_name" {
  description = "Short project name used as a prefix for resource names."
  type        = string
}

variable "allowed_origins" {
  description = "Origins allowed to POST/PUT directly to this bucket (frontend dev server + deployed domain)."
  type        = list(string)
}
