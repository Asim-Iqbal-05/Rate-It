# This VPC exists only to host Feed Service (infra PRD §3). Private
# subnets only - no public subnets, no Internet Gateway, no NAT Gateway,
# since nothing inside ever needs to initiate an outbound internet
# connection. Everything it needs (ECR, CloudWatch Logs, DynamoDB, S3)
# is reached via VPC endpoints instead.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.project_name}-private-${var.availability_zones[count.index]}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-private" }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security group shared by all VPC interface endpoints: HTTPS from
# inside the VPC only.
resource "aws_security_group" "endpoints" {
  name_prefix = "${var.project_name}-vpce-"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Interface endpoints: let Fargate pull manifests, authenticate to the
# registry, and ship logs with no internet path (infra PRD §3).
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["ecr.api", "ecr.dkr", "logs"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

# Gateway endpoints (free): DynamoDB keeps Feed Service reads off the
# public internet; S3 is a hard functional dependency because ECR
# stores image layers in S3, not in ECR itself - without this, Fargate
# task launches fail at the image-pull step (infra PRD §3).
resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(["dynamodb", "s3"])

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
