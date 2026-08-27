terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

# Attached to CloudFront (below), not directly to API Gateway: AWS
# WAF's AssociateWebACL simply does not support HTTP API (v2) stages
# as a resource type at all - only REST API stages, ALB, AppSync,
# Cognito user pools, App Runner, Verified Access, and Amplify apps
# (confirmed against the current AssociateWebACL API reference).
# CloudFront is also the better attachment point regardless: it's the
# actual single public entry point for every path (/, /api/*,
# /images/*), not just the API - and CloudFront-scoped web ACLs must
# live in us-east-1 and use `web_acl_id` on the distribution itself,
# not AssociateWebACL.
#
# Authentication answers who you are; it doesn't answer how many times
# per second you're allowed to do it - these are separate concerns
# (infra PRD §6). Two rules cover both cases WAF can actually see a
# caller by, since WAF sits in front of the JWT authorizer and can't
# decode a token's claims itself:
#
#  1. Requests carrying an Authorization header are rate-limited by
#     that header's raw value - a real Cognito token doesn't change
#     for up to an hour, so this closely approximates "per user"
#     limiting without needing to decode the JWT.
#  2. Requests with no Authorization header at all (the PRD's
#     "unauthenticated abuse" case) fall through to a separate rule
#     keyed by the caller's real IP instead.
#
# Both return 429 - matching what the frontend (lib/api.ts) already
# expects and handles ("slow down and try again"), not WAF's default
# 403.
resource "aws_wafv2_web_acl" "api" {
  provider = aws.us_east_1

  name        = "${var.project_name}-api-waf"
  description = "Rate limiting for the RateIt app"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitByAuthToken"
    priority = 1

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "CUSTOM_KEYS"

        custom_key {
          header {
            name = "authorization"
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }

        # Only requests carrying a real bearer-token-shaped
        # Authorization header count toward this rule (WAF's
        # byte_match_statement requires a non-empty search string, so
        # matching literally on "Bearer" - our frontend's actual auth
        # scheme - doubles as the existence check).
        scope_down_statement {
          byte_match_statement {
            search_string         = "Bearer"
            positional_constraint = "CONTAINS"
            field_to_match {
              single_header {
                name = "authorization"
              }
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit-by-token"
    }
  }

  rule {
    name     = "RateLimitByIp"
    priority = 2

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        # A CloudFront-scoped web ACL evaluates at the edge, seeing the
        # real viewer IP directly - no forwarded_ip_config needed here
        # (that's only for a WAF sitting behind another proxy, like a
        # regional ACL on an ALB/API Gateway would).
        limit              = var.rate_limit
        aggregate_key_type = "IP"

        # The inverse of the rule above: only requests WITHOUT an
        # Authorization header fall into the IP-keyed bucket.
        scope_down_statement {
          not_statement {
            statement {
              byte_match_statement {
                search_string         = "Bearer"
                positional_constraint = "CONTAINS"
                field_to_match {
                  single_header {
                    name = "authorization"
                  }
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit-by-ip"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-api-waf"
  }
}
