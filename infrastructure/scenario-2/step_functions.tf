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

# ── Lambda Source Archives ────────────────────────────────────────────────────

data "archive_file" "validate_user" {
  type        = "zip"
  output_path = "${path.module}/sfn_validate_user.zip"
  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      import os, json, random, boto3, urllib.request, urllib.error

      NAMESPACE = os.environ['SERVICE_NAMESPACE']
      _sd = None

      def sd():
          global _sd
          if _sd is None:
              _sd = boto3.client('servicediscovery')
          return _sd

      def discover_ip(svc):
          r = sd().discover_instances(
              NamespaceName=NAMESPACE, ServiceName=svc,
              MaxResults=10, HealthStatus='HEALTHY')
          instances = r.get('Instances', [])
          if not instances:
              raise Exception(f'No healthy instances for {svc}')
          return random.choice(instances)['Attributes']['AWS_INSTANCE_IPV4']

      def handler(event, context):
          user_id = event['userId']
          ip  = discover_ip('user-service')
          url = f'http://{ip}:8080/api/users/{user_id}'
          try:
              with urllib.request.urlopen(url, timeout=10) as r:
                  return json.loads(r.read())
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  raise Exception('UserNotFoundException')
              raise
    PYTHON
  }
}

data "archive_file" "process_payment" {
  type        = "zip"
  output_path = "${path.module}/sfn_process_payment.zip"
  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      import os, json, random, boto3, urllib.request

      NAMESPACE = os.environ['SERVICE_NAMESPACE']
      _sd = None

      def sd():
          global _sd
          if _sd is None:
              _sd = boto3.client('servicediscovery')
          return _sd

      def discover_ip(svc):
          r = sd().discover_instances(
              NamespaceName=NAMESPACE, ServiceName=svc,
              MaxResults=10, HealthStatus='HEALTHY')
          instances = r.get('Instances', [])
          if not instances:
              raise Exception(f'No healthy instances for {svc}')
          return random.choice(instances)['Attributes']['AWS_INSTANCE_IPV4']

      def handler(event, context):
          ip      = discover_ip('payment-service')
          payload = json.dumps({
              'orderId': event['orderId'],
              'userId':  event['userId'],
              'amount':  event['amount'],
          }).encode()
          req = urllib.request.Request(
              f'http://{ip}:8080/api/payments',
              data=payload,
              headers={'Content-Type': 'application/json'},
              method='POST',
          )
          with urllib.request.urlopen(req, timeout=15) as r:
              return json.loads(r.read())
    PYTHON
  }
}

data "archive_file" "confirm_order" {
  type        = "zip"
  output_path = "${path.module}/sfn_confirm_order.zip"
  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      import os, json, random, boto3, urllib.request

      NAMESPACE     = os.environ['SERVICE_NAMESPACE']
      KEY_PARAM     = os.environ['INTERNAL_API_KEY_PARAM']
      _sd = _ssm = _key = None

      def sd():
          global _sd
          if _sd is None:
              _sd = boto3.client('servicediscovery')
          return _sd

      def api_key():
          global _ssm, _key
          if _key is None:
              if _ssm is None:
                  _ssm = boto3.client('ssm')
              _key = _ssm.get_parameter(Name=KEY_PARAM, WithDecryption=True)['Parameter']['Value']
          return _key

      def discover_ip(svc):
          r = sd().discover_instances(
              NamespaceName=NAMESPACE, ServiceName=svc,
              MaxResults=10, HealthStatus='HEALTHY')
          instances = r.get('Instances', [])
          if not instances:
              raise Exception(f'No healthy instances for {svc}')
          return random.choice(instances)['Attributes']['AWS_INSTANCE_IPV4']

      def handler(event, context):
          order_id = event['orderId']
          ip  = discover_ip('order-service')
          req = urllib.request.Request(
              f'http://{ip}:8080/api/orders/{order_id}/confirm',
              data=b'{}',
              headers={'Content-Type': 'application/json', 'X-Internal-Api-Key': api_key()},
              method='POST',
          )
          with urllib.request.urlopen(req, timeout=15) as r:
              return {'status': 'confirmed', 'orderId': order_id}
    PYTHON
  }
}

data "archive_file" "refund_payment" {
  type        = "zip"
  output_path = "${path.module}/sfn_refund_payment.zip"
  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      import os, json, random, boto3, urllib.request

      NAMESPACE = os.environ['SERVICE_NAMESPACE']
      _sd = None

      def sd():
          global _sd
          if _sd is None:
              _sd = boto3.client('servicediscovery')
          return _sd

      def discover_ip(svc):
          r = sd().discover_instances(
              NamespaceName=NAMESPACE, ServiceName=svc,
              MaxResults=10, HealthStatus='HEALTHY')
          instances = r.get('Instances', [])
          if not instances:
              raise Exception(f'No healthy instances for {svc}')
          return random.choice(instances)['Attributes']['AWS_INSTANCE_IPV4']

      def handler(event, context):
          payment    = event.get('payment') or {}
          payment_id = payment.get('paymentId')
          if not payment_id:
              return {'status': 'no_payment_to_refund'}
          ip  = discover_ip('payment-service')
          req = urllib.request.Request(
              f'http://{ip}:8080/api/payments/{payment_id}/refund',
              data=b'{}',
              headers={'Content-Type': 'application/json'},
              method='POST',
          )
          with urllib.request.urlopen(req, timeout=15) as r:
              return json.loads(r.read())
    PYTHON
  }
}

data "archive_file" "cancel_order" {
  type        = "zip"
  output_path = "${path.module}/sfn_cancel_order.zip"
  source {
    filename = "lambda_function.py"
    content  = <<-PYTHON
      import os, json, random, boto3, urllib.request

      NAMESPACE = os.environ['SERVICE_NAMESPACE']
      KEY_PARAM = os.environ['INTERNAL_API_KEY_PARAM']
      _sd = _ssm = _key = None

      def sd():
          global _sd
          if _sd is None:
              _sd = boto3.client('servicediscovery')
          return _sd

      def api_key():
          global _ssm, _key
          if _key is None:
              if _ssm is None:
                  _ssm = boto3.client('ssm')
              _key = _ssm.get_parameter(Name=KEY_PARAM, WithDecryption=True)['Parameter']['Value']
          return _key

      def discover_ip(svc):
          r = sd().discover_instances(
              NamespaceName=NAMESPACE, ServiceName=svc,
              MaxResults=10, HealthStatus='HEALTHY')
          instances = r.get('Instances', [])
          if not instances:
              raise Exception(f'No healthy instances for {svc}')
          return random.choice(instances)['Attributes']['AWS_INSTANCE_IPV4']

      def handler(event, context):
          order_id = event['orderId']
          ip  = discover_ip('order-service')
          req = urllib.request.Request(
              f'http://{ip}:8080/api/orders/{order_id}/cancel',
              data=b'{}',
              headers={'Content-Type': 'application/json', 'X-Internal-Api-Key': api_key()},
              method='POST',
          )
          with urllib.request.urlopen(req, timeout=15) as r:
              return {'status': 'cancelled', 'orderId': order_id}
    PYTHON
  }
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
  filename         = data.archive_file.validate_user.output_path
  source_code_hash = data.archive_file.validate_user.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

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
  filename         = data.archive_file.process_payment.output_path
  source_code_hash = data.archive_file.process_payment.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

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
  filename         = data.archive_file.confirm_order.output_path
  source_code_hash = data.archive_file.confirm_order.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

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
  filename         = data.archive_file.refund_payment.output_path
  source_code_hash = data.archive_file.refund_payment.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

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
  filename         = data.archive_file.cancel_order.output_path
  source_code_hash = data.archive_file.cancel_order.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

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
      aws_lambda_function.validate_user.arn,
      aws_lambda_function.process_payment.arn,
      aws_lambda_function.confirm_order.arn,
      aws_lambda_function.refund_payment.arn,
      aws_lambda_function.cancel_order.arn,
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

  definition = templatefile("${path.module}/step_functions/order_saga.json", {
    validate_user_lambda_arn   = aws_lambda_function.validate_user.arn
    process_payment_lambda_arn = aws_lambda_function.process_payment.arn
    confirm_order_lambda_arn   = aws_lambda_function.confirm_order.arn
    refund_payment_lambda_arn  = aws_lambda_function.refund_payment.arn
    cancel_order_lambda_arn    = aws_lambda_function.cancel_order.arn
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
