data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ── Task Execution Role (shared by all services) ──────────────────────────────
# Used by the ECS agent to pull images from ECR and write CloudWatch logs.

resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_ssm" {
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ms-learning/*"
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_ssm" {
  name   = "ssm-read"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_ssm.json
}

# ── Order-Service Task Role ───────────────────────────────────────────────────
# Runtime identity of the order-service container.
# SigV4 signing for inter-service calls uses these credentials automatically —
# no extra execute-api permission is needed for direct VPC (Service Connect) traffic.

resource "aws_iam_role" "order_service" {
  name               = "${local.name_prefix}-order-service-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "order_service" {
  statement {
    sid    = "SQSOrderEvents"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [
      aws_sqs_queue.order_events.arn,
      aws_sqs_queue.order_events_dlq.arn,
    ]
  }

  statement {
    sid     = "SSMRead"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ms-learning/*"
    ]
  }
}

resource "aws_iam_role_policy" "order_service" {
  name   = "order-service-policy"
  role   = aws_iam_role.order_service.id
  policy = data.aws_iam_policy_document.order_service.json
}

# ── Payment-Service Task Role ─────────────────────────────────────────────────

resource "aws_iam_role" "payment_service" {
  name               = "${local.name_prefix}-payment-service-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "payment_service" {
  statement {
    sid    = "SQSPaymentEvents"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [
      aws_sqs_queue.payment_events.arn,
      aws_sqs_queue.payment_events_dlq.arn,
    ]
  }

  statement {
    sid     = "SSMRead"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ms-learning/*"
    ]
  }
}

resource "aws_iam_role_policy" "payment_service" {
  name   = "payment-service-policy"
  role   = aws_iam_role.payment_service.id
  policy = data.aws_iam_policy_document.payment_service.json
}

# ── User-Service Task Role ────────────────────────────────────────────────────

resource "aws_iam_role" "user_service" {
  name               = "${local.name_prefix}-user-service-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "user_service" {
  statement {
    sid    = "DynamoDBUsers"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:DeleteItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/users"
    ]
  }

  statement {
    sid     = "SSMRead"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ms-learning/*"
    ]
  }
}

resource "aws_iam_role_policy" "user_service" {
  name   = "user-service-policy"
  role   = aws_iam_role.user_service.id
  policy = data.aws_iam_policy_document.user_service.json
}
