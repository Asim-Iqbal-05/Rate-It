variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.30.0.0/16"
}

variable "availability_zones" {
  description = "Exactly 2 AZs, per infra PRD §3."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.30.1.0/24", "10.30.2.0/24"]
}
