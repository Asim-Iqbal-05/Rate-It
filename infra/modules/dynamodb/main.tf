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

  # GSI attributes. `Type` is a monthly "POST#YYYY-MM" bucket on every item -
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

  # Author lookups for "My posts" (extension PRD §5.2). Keeps taken-down
  # posts reachable by their author - they have no `Type`, so they are
  # absent from the feed GSI above but still carry `userId`.
  attribute {
    name = "userId"
    type = "S"
  }

  global_secondary_index {
    name            = "TypeCreatedAtIndex"
    hash_key        = "Type"
    range_key       = "CreatedAt"
    projection_type = "ALL" # feed reads need the full item, not just keys
  }

  global_secondary_index {
    name            = "userId-CreatedAt-index"
    hash_key        = "userId"
    range_key       = "CreatedAt"
    projection_type = "ALL"
  }

  # Moderation Service trigger (extension PRD §5.2/§7.2). Only the
  # new image is needed - it filters on INSERT.
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  point_in_time_recovery {
    enabled = true
  }
}

# Likes and like counts live here and ONLY here (extension PRD §4,
# invariant 2) so a like never writes to the Experiences table or its
# feed GSI. Two item kinds share the table: one row per like
# (userId = the liker's Cognito sub) and one count row per post
# (userId = the literal "COUNT" - a Cognito sub is a UUID, so the two
# can never collide). A missing count row means zero likes.
resource "aws_dynamodb_table" "reactions" {
  name         = "${var.project_name}-reactions"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "experienceId"
  range_key = "userId"

  attribute {
    name = "experienceId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# --- Likes redesign (docs/rateit-likes-redesign-prd.md) ---------------------
# Likes (source of truth) and LikeCounters (derived counts) replace the
# Reactions table above, which is removed in a later, separate apply once
# the data has been migrated and verified.

# One row per like. Keyed by user FIRST so writes spread evenly across
# partitions (no single user likes fast enough to matter). The cost is that
# this table cannot list the likes of a post - nothing in the product needs
# that. Deliberately NO index on experienceId: it would recreate the hot
# partition this design removes.
resource "aws_dynamodb_table" "likes" {
  name         = "${var.project_name}-likes"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "userId"
  range_key = "experienceId"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "experienceId"
    type = "S"
  }

  # Drives the Counter Lambda. Keys are enough: INSERT/REMOVE plus the
  # key (which carries the post ID) is all it needs.
  stream_enabled   = true
  stream_view_type = "KEYS_ONLY"

  point_in_time_recovery {
    enabled = true
  }
}

# Derived counts, one row per post, plus short-lived idempotency markers
# the Counter Lambda writes in the same transaction as the count updates
# (so a re-delivered stream batch is detected and applied only once).
# A missing counter means zero likes.
resource "aws_dynamodb_table" "like_counters" {
  name         = "${var.project_name}-like-counters"
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}
