# DB URLs are wired from RDS outputs so they're always in sync.

resource "aws_ssm_parameter" "order_db_url" {
  name  = "/ms-learning/order/db-url"
  type  = "SecureString"
  value = "jdbc:postgresql://${aws_db_instance.order.address}:${aws_db_instance.order.port}/order_db"
  tags  = { Name = "order-db-url" }
}

resource "aws_ssm_parameter" "order_db_username" {
  name  = "/ms-learning/order/db-username"
  type  = "SecureString"
  value = var.db_username
  tags  = { Name = "order-db-username" }
}

resource "aws_ssm_parameter" "order_db_password" {
  name  = "/ms-learning/order/db-password"
  type  = "SecureString"
  value = var.db_password
  tags  = { Name = "order-db-password" }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "payment_db_url" {
  name  = "/ms-learning/payment/db-url"
  type  = "SecureString"
  value = "jdbc:postgresql://${aws_db_instance.payment.address}:${aws_db_instance.payment.port}/payment_db"
  tags  = { Name = "payment-db-url" }
}

resource "aws_ssm_parameter" "payment_db_username" {
  name  = "/ms-learning/payment/db-username"
  type  = "SecureString"
  value = var.db_username
  tags  = { Name = "payment-db-username" }
}

resource "aws_ssm_parameter" "payment_db_password" {
  name  = "/ms-learning/payment/db-password"
  type  = "SecureString"
  value = var.db_password
  tags  = { Name = "payment-db-password" }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "cognito_user_pool_id" {
  name  = "/ms-learning/cognito/user-pool-id"
  type  = "SecureString"
  value = aws_cognito_user_pool.main.id
  tags  = { Name = "cognito-user-pool-id" }
}

# Cloud Map resolves these FQDNs within the VPC's private DNS namespace.
# Container port 8080 must be included since there's no Envoy sidecar rewriting
# port 80 → 8080 (we don't use Service Connect — see ecs_cluster.tf comment).
resource "aws_ssm_parameter" "payment_url" {
  name  = "/ms-learning/payment/url"
  type  = "String"
  value = "http://payment-service.ms-learning.local:8080"
  tags  = { Name = "payment-url" }
}

resource "aws_ssm_parameter" "user_url" {
  name  = "/ms-learning/user/url"
  type  = "String"
  value = "http://user-service.ms-learning.local:8080"
  tags  = { Name = "user-url" }
}

resource "aws_ssm_parameter" "user_dynamodb_table" {
  name  = "/ms-learning/user/dynamodb-table"
  type  = "String"
  value = aws_dynamodb_table.users.name
  tags  = { Name = "user-dynamodb-table" }
}
