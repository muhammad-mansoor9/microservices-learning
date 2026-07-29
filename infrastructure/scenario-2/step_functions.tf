# ── Internal API Key ──────────────────────────────────────────────────────────
# Shared secret that SAGA Lambda proxies present when calling order-service
# internal endpoints (/confirm, /cancel).  Generated once; ignored on re-apply.

resource "random_password" "internal_api_key" {
  length  = 40
  special = false
}

# ── Lambda Execution Role ─────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "saga_lambda" {
  name               = "${local.name_prefix}-saga-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# VPC access + basic CloudWatch Logs
resource "aws_iam_role_policy_attachment" "saga_lambda_vpc" {
  role       = aws_iam_role.saga_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "saga_lambda_permissions" {
  statement {
    sid       = "CloudMapDiscovery"
    effect    = "Allow"
    actions   = ["servicediscovery:DiscoverInstances"]
    resources = ["*"]
  }

  statement {
    sid     = "SSMInternalKey"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ms-learning/order/internal-api-key"
    ]
  }
}

resource "aws_iam_role_policy" "saga_lambda_permissions" {
  name   = "saga-lambda-permissions"
  role   = aws_iam_role.saga_lambda.id
  policy = data.aws_iam_policy_document.saga_lambda_permissions.json
}

# ── Lambda Security Group ─────────────────────────────────────────────────────

resource "aws_security_group" "saga_lambdas" {
  name        = "${local.name_prefix}-saga-lambdas-sg"
  description = "SAGA Lambda proxies outbound to ECS services"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-saga-lambdas-sg" }
}

# Ingress from saga_lambdas to ecs_tasks is declared inline on the
# ecs_tasks security group in sg.tf — a separate aws_security_group_rule
# resource would be stripped on every apply because inline ingress is
# authoritative.

# ── Lambda Source Artifact ────────────────────────────────────────────────────
# Shaded jar produced by `mvn -pl saga-lambdas package` at the repo root.
# All five Lambdas share this single jar; each aws_lambda_function selects a
# different handler class.

locals {
  saga_lambda_jar = "${path.module}/../../saga-lambdas/target/saga-lambdas.jar"
}

# ── Lambda Functions ──────────────────────────────────────────────────────────

locals {
  lambda_vpc_config = {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.saga_lambdas.id]
  }
  lambda_common_env = {
    SERVICE_NAMESPACE = aws_service_discovery_private_dns_namespace.ms_learning.name
  }
  internal_key_param = aws_ssm_parameter.internal_api_key.name
}

resource "aws_lambda_function" "validate_user" {
  function_name    = "${local.name_prefix}-saga-validate-user"
  role             = aws_iam_role.saga_lambda.arn
  filename         = local.saga_lambda_jar
  source_code_hash = filebase64sha256(local.saga_lambda_jar)
  handler          = "com.example.saga.ValidateUserHandler::handleRequest"
  runtime          = "java21"
  timeout          = 60
  memory_size      = 512

  # SnapStart: publish an immutable version on each deploy, snapshot the
  # initialized JVM, and restore from that snapshot on cold starts.
  publish = true
  snap_start {
    apply_on = "PublishedVersions"
  }

  vpc_config {
    subnet_ids         = local.lambda_vpc_config.subnet_ids
    security_group_ids = local.lambda_vpc_config.security_group_ids
  }

  environment {
    variables = local.lambda_common_env
  }

  tags = { Name = "${local.name_prefix}-saga-validate-user" }
}

resource "aws_lambda_function" "process_payment" {
  function_name    = "${local.name_prefix}-saga-process-payment"
  role             = aws_iam_role.saga_lambda.arn
  filename         = local.saga_lambda_jar
  source_code_hash = filebase64sha256(local.saga_lambda_jar)
  handler          = "com.example.saga.ProcessPaymentHandler::handleRequest"
  runtime          = "java21"
  timeout          = 60
  memory_size      = 512

  # SnapStart: publish an immutable version on each deploy, snapshot the
  # initialized JVM, and restore from that snapshot on cold starts.
  publish = true
  snap_start {
    apply_on = "PublishedVersions"
  }

  vpc_config {
    subnet_ids         = local.lambda_vpc_config.subnet_ids
    security_group_ids = local.lambda_vpc_config.security_group_ids
  }

  environment {
    variables = local.lambda_common_env
  }

  tags = { Name = "${local.name_prefix}-saga-process-payment" }
}

resource "aws_lambda_function" "confirm_order" {
  function_name    = "${local.name_prefix}-saga-confirm-order"
  role             = aws_iam_role.saga_lambda.arn
  filename         = local.saga_lambda_jar
  source_code_hash = filebase64sha256(local.saga_lambda_jar)
  handler          = "com.example.saga.ConfirmOrderHandler::handleRequest"
  runtime          = "java21"
  timeout          = 60
  memory_size      = 512

  # SnapStart: publish an immutable version on each deploy, snapshot the
  # initialized JVM, and restore from that snapshot on cold starts.
  publish = true
  snap_start {
    apply_on = "PublishedVersions"
  }

  vpc_config {
    subnet_ids         = local.lambda_vpc_config.subnet_ids
    security_group_ids = local.lambda_vpc_config.security_group_ids
  }

  environment {
    variables = merge(local.lambda_common_env, {
      INTERNAL_API_KEY_PARAM = local.internal_key_param
    })
  }

  tags = { Name = "${local.name_prefix}-saga-confirm-order" }
}

resource "aws_lambda_function" "refund_payment" {
  function_name    = "${local.name_prefix}-saga-refund-payment"
  role             = aws_iam_role.saga_lambda.arn
  filename         = local.saga_lambda_jar
  source_code_hash = filebase64sha256(local.saga_lambda_jar)
  handler          = "com.example.saga.RefundPaymentHandler::handleRequest"
  runtime          = "java21"
  timeout          = 60
  memory_size      = 512

  # SnapStart: publish an immutable version on each deploy, snapshot the
  # initialized JVM, and restore from that snapshot on cold starts.
  publish = true
  snap_start {
    apply_on = "PublishedVersions"
  }

  vpc_config {
    subnet_ids         = local.lambda_vpc_config.subnet_ids
    security_group_ids = local.lambda_vpc_config.security_group_ids
  }

  environment {
    variables = local.lambda_common_env
  }

  tags = { Name = "${local.name_prefix}-saga-refund-payment" }
}

resource "aws_lambda_function" "cancel_order" {
  function_name    = "${local.name_prefix}-saga-cancel-order"
  role             = aws_iam_role.saga_lambda.arn
  filename         = local.saga_lambda_jar
  source_code_hash = filebase64sha256(local.saga_lambda_jar)
  handler          = "com.example.saga.CancelOrderHandler::handleRequest"
  runtime          = "java21"
  timeout          = 60
  memory_size      = 512

  # SnapStart: publish an immutable version on each deploy, snapshot the
  # initialized JVM, and restore from that snapshot on cold starts.
  publish = true
  snap_start {
    apply_on = "PublishedVersions"
  }

  vpc_config {
    subnet_ids         = local.lambda_vpc_config.subnet_ids
    security_group_ids = local.lambda_vpc_config.security_group_ids
  }

  environment {
    variables = merge(local.lambda_common_env, {
      INTERNAL_API_KEY_PARAM = local.internal_key_param
    })
  }

  tags = { Name = "${local.name_prefix}-saga-cancel-order" }
}

# ── Step Functions IAM Role ───────────────────────────────────────────────────

data "aws_iam_policy_document" "sfn_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "order_saga_sfn" {
  name               = "${local.name_prefix}-order-saga-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json
}

data "aws_iam_policy_document" "order_saga_sfn" {
  statement {
    sid     = "InvokeSagaLambdas"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      # Unqualified allows invoking $LATEST; the ":*" wildcard covers every
      # published version (SnapStart requires invoking a versioned qualifier).
      aws_lambda_function.validate_user.arn,
      "${aws_lambda_function.validate_user.arn}:*",
      aws_lambda_function.process_payment.arn,
      "${aws_lambda_function.process_payment.arn}:*",
      aws_lambda_function.confirm_order.arn,
      "${aws_lambda_function.confirm_order.arn}:*",
      aws_lambda_function.refund_payment.arn,
      "${aws_lambda_function.refund_payment.arn}:*",
      aws_lambda_function.cancel_order.arn,
      "${aws_lambda_function.cancel_order.arn}:*",
    ]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:PutLogEvents",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "order_saga_sfn" {
  name   = "invoke-saga-lambdas"
  role   = aws_iam_role.order_saga_sfn.id
  policy = data.aws_iam_policy_document.order_saga_sfn.json
}

# ── CloudWatch Log Group for State Machine ────────────────────────────────────

resource "aws_cloudwatch_log_group" "order_saga" {
  name              = "/${local.name_prefix}/order-saga"
  retention_in_days = 7
  tags              = { Name = "/${local.name_prefix}/order-saga" }
}

# ── State Machine ─────────────────────────────────────────────────────────────

resource "aws_sfn_state_machine" "order_saga" {
  name     = "${local.name_prefix}-order-saga"
  role_arn = aws_iam_role.order_saga_sfn.arn

  # qualified_arn includes the published version (e.g. …:validate_user:3), so
  # Step Functions invokes the SnapStart-restored version, not $LATEST.
  definition = templatefile("${path.module}/step_functions/order_saga.json", {
    validate_user_lambda_arn   = aws_lambda_function.validate_user.qualified_arn
    process_payment_lambda_arn = aws_lambda_function.process_payment.qualified_arn
    confirm_order_lambda_arn   = aws_lambda_function.confirm_order.qualified_arn
    refund_payment_lambda_arn  = aws_lambda_function.refund_payment.qualified_arn
    cancel_order_lambda_arn    = aws_lambda_function.cancel_order.qualified_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.order_saga.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = { Name = "${local.name_prefix}-order-saga" }
}

# ── SSM Parameters ────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "internal_api_key" {
  name  = "/ms-learning/order/internal-api-key"
  type  = "SecureString"
  value = random_password.internal_api_key.result
  tags  = { Name = "order-internal-api-key" }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "saga_state_machine_arn" {
  name  = "/ms-learning/order/saga-state-machine-arn"
  type  = "String"
  value = aws_sfn_state_machine.order_saga.arn
  tags  = { Name = "order-saga-state-machine-arn" }
}
