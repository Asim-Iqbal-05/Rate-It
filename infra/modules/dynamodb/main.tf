# Single-table design per infra PRD §7.1: one `Experiences` table holds
# every post. `experienceId` alone is enough to uniquely address an item,
# so the base table has no range key.
resource "aws_dynamodb_table" "experiences" {
  name         = "${var.project_name}-experiences"
  billing_mode = "PAY_PER_REQUEST" # on-demand: fails safe under a burst
  # instead of throttling (§6) - no
  # capacity planning needed at this scale.

  hash_key = "experienceId"

  attribute {
    name = "experienceId"
    type = "S"
  }

  # GSI attributes. `Type` is a constant "POST" on every item today -
  # this is the documented v1 hot-partition tradeoff (§7.1): all feed
  # reads and writes hit one logical GSI partition, mitigated by the
  # CloudFront cache on GET /api/feed (added in Phase 7). Migration
  # trigger and path (time-bucketed keys) are documented there, not
  # built until actually needed.
  attribute {
    name = "Type"
    type = "S"
  }

  attribute {
    name = "CreatedAt"
    type = "S"
  }

  global_secondary_index {
    name            = "TypeCreatedAtIndex"
    hash_key        = "Type"
    range_key       = "CreatedAt"
    projection_type = "ALL" # feed reads need the full item, not just keys
  }

  point_in_time_recovery {
    enabled = true
  }
}
