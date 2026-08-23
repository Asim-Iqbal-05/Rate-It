terraform {
  backend "s3" {
    bucket       = "rateit-terraform-state-cc5244ae"
    key          = "env/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true # S3 native locking - no DynamoDB table (see infra/bootstrap).
  }
}
