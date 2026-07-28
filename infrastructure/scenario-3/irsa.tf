# -----------------------------------------------------------------------------
# EBS CSI driver — IRSA for kube-system/ebs-csi-controller-sa.
# The aws-ebs-csi-driver addon cannot reach ACTIVE state without a role that
# lets the controller call the EC2 API (CreateVolume, AttachVolume, ...).
# -----------------------------------------------------------------------------
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-ebs-csi-driver"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — IRSA for kube-system/aws-load-balancer-controller
# Uses the sub-module's built-in policy (rendered from the official upstream JSON).
# -----------------------------------------------------------------------------
module "aws_lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-aws-load-balancer-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# -----------------------------------------------------------------------------
# order-service IRSA — trusts default/order-service SA.
# SQS: Receive/Send/Delete on order-events queue. SSM: GetParameter on /ms-learning/*.
# -----------------------------------------------------------------------------
module "order_service_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-order-service"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:order-service"]
    }
  }
}

resource "aws_iam_role_policy" "order_service" {
  name = "order-service-inline"
  role = module.order_service_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SqsOrderEvents"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:SendMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = local.order_events_queue_arn
      },
      {
        Sid      = "SsmParameterRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = local.ssm_parameter_arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# payment-service IRSA — trusts default/payment-service SA.
# SQS consumer on order-events queue.
# -----------------------------------------------------------------------------
module "payment_service_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-payment-service"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:payment-service"]
    }
  }
}

resource "aws_iam_role_policy" "payment_service" {
  name = "payment-service-inline"
  role = module.payment_service_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SqsOrderEventsConsumer"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = local.order_events_queue_arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# user-service IRSA — trusts default/user-service SA.
# DynamoDB: PutItem/GetItem/Query on users table.
# -----------------------------------------------------------------------------
module "user_service_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-user-service"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:user-service"]
    }
  }
}

resource "aws_iam_role_policy" "user_service" {
  name = "user-service-inline"
  role = module.user_service_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDbUsersTable"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
        ]
        Resource = local.users_table_arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# FluentBit IRSA — trusts amazon-cloudwatch/fluentbit SA.
# CloudWatch Logs write scope so the DaemonSet can ship container logs to the
# /eks/ms-learning log group.
# -----------------------------------------------------------------------------
module "fluentbit_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-fluentbit"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["amazon-cloudwatch:fluentbit"]
    }
  }
}

resource "aws_iam_role_policy" "fluentbit" {
  name = "fluentbit-inline"
  role = module.fluentbit_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
    ]
  })
}
