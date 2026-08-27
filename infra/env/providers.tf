terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# CloudFront requires ACM certs to be issued in us-east-1, regardless
# of which region everything else runs in.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
