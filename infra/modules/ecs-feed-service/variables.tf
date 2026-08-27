variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "table_name" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "feed_index_name" {
  type = string
}

variable "public_image_base_url" {
  description = "Public base URL images are served from (CloudFront custom domain) - the task constructs /images/{key} links from this, no S3 access needed."
  type        = string
}

variable "ecr_repository_url" {
  type = string
}

variable "container_image_tag" {
  type    = string
  default = "latest"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "task_cpu" {
  type    = string
  default = "256"
}

variable "task_memory" {
  type    = string
  default = "512"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "bake_time_in_minutes" {
  description = "How long blue and green both run after traffic shifts to green, before blue is torn down - the window to notice a bad deploy and roll back."
  type        = number
  default     = 5
}
