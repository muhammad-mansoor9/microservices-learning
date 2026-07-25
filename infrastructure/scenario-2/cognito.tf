resource "aws_cognito_user_pool" "main" {
  name = "${local.name_prefix}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  tags = { Name = "${local.name_prefix}-users" }
}

# ALB app client — Authorization Code flow requires a secret
resource "aws_cognito_user_pool_client" "alb" {
  name         = "${local.name_prefix}-alb"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = true

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  # Update these once an HTTPS listener + domain is configured.
  callback_urls = ["https://${var.alb_callback_domain}/oauth2/idpresponse"]
  logout_urls   = ["https://${var.alb_callback_domain}"]

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

# Developer/testing client — no secret, username+password auth
resource "aws_cognito_user_pool_client" "api_test" {
  name         = "${local.name_prefix}-api-test"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}

# Hosted UI domain — required for ALB Authorization Code flow
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}
