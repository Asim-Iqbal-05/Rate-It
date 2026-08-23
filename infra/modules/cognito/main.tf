resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-users"

  # Username is the user-chosen handle at signup (Cognito enforces
  # uniqueness on it natively - no separate check needed). Email is an
  # alias, not the username: Cognito also enforces alias uniqueness, so
  # no two users can share an email either, and it doubles as the
  # sign-in identifier for "forgot password" / optional email login.
  alias_attributes         = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # Cognito sends the verification code itself - no custom email/SMS
  # sending infra needed for v1.
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }
}

# Single app client for the SPA. Public client (no secret) because a
# browser-based SPA cannot keep a secret confidential.
resource "aws_cognito_user_pool_client" "spa" {
  name         = "${var.project_name}-spa-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  # Direct API auth (SRP) for a custom-built UI - deliberately NOT
  # configuring Hosted UI / OAuth (no callback_urls, no allowed_oauth_flows).
  # See app PRD: frontend owns its own login/signup screens and talks to
  # Cognito directly (e.g. via Amplify or aws-sdk), no hosted redirect flow.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}
