# ══════════════════════════════════════════════════════════════════════════════
# CI/CD pipeline:
#   GitHub (AWS CodeConnections) → CodeBuild → CodeDeploy (blue/green per service)
# ══════════════════════════════════════════════════════════════════════════════

# ── Artifact Bucket ───────────────────────────────────────────────────────────

resource "aws_s3_bucket" "codepipeline_artifacts" {
  bucket        = "${local.name_prefix}-codepipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${local.name_prefix}-codepipeline-artifacts" }
}

resource "aws_s3_bucket_versioning" "codepipeline_artifacts" {
  bucket = aws_s3_bucket.codepipeline_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "codepipeline_artifacts" {
  bucket                  = aws_s3_bucket.codepipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "codepipeline_artifacts" {
  bucket = aws_s3_bucket.codepipeline_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── IAM: CodePipeline Role ────────────────────────────────────────────────────

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${local.name_prefix}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}

data "aws_iam_policy_document" "codepipeline" {
  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.codepipeline_artifacts.arn,
      "${aws_s3_bucket.codepipeline_artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "CodeConnectionsUse"
    effect = "Allow"
    actions = [
      # New action name after the July 2024 rename (CodeStar Connections → CodeConnections)
      "codeconnections:UseConnection",
      # Legacy alias — kept so pipelines pointing at pre-rename ARNs still work
      "codestar-connections:UseConnection",
    ]
    resources = [var.codeconnections_arn]
  }

  statement {
    sid    = "InvokeCodeBuild"
    effect = "Allow"
    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "InvokeCodeDeploy"
    effect = "Allow"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetApplication",
      "codedeploy:GetApplicationRevision",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:RegisterApplicationRevision",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECSPassRole"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "iam:PassRole",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "codepipeline-policy"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}

# ── IAM: CodeBuild Role ───────────────────────────────────────────────────────

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${local.name_prefix}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.codepipeline_artifacts.arn,
      "${aws_s3_bucket.codepipeline_artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
    ]
    resources = [for r in aws_ecr_repository.services : r.arn]
  }

  statement {
    sid    = "SSMRead"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ms-learning/*"
    ]
  }

  statement {
    sid    = "ECSDescribeTaskDefinitionForBuild"
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "codebuild-policy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

# ── IAM: CodeDeploy Role ──────────────────────────────────────────────────────

data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${local.name_prefix}-codedeploy-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json
}

resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# ── CodeBuild Project ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/${local.name_prefix}/codebuild"
  retention_in_days = 7
  tags              = { Name = "/${local.name_prefix}/codebuild" }
}

resource "aws_codebuild_project" "build" {
  name          = "${local.name_prefix}-build"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }

    environment_variable {
      name  = "ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }

    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/../../buildspec.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }

  tags = { Name = "${local.name_prefix}-build" }
}

# ── CodeDeploy Applications + Deployment Groups (one per service) ─────────────

locals {
  # Maps each service to its ALB listener + blue/green target group ARNs so we
  # can drive three near-identical CodeDeploy resources from one for_each.
  codedeploy_services = {
    order-service = {
      prod_listener_arn = aws_lb_listener.http.arn
      test_listener_arn = aws_lb_listener.http_test.arn
      blue_tg_name      = aws_lb_target_group.order_service.name
      green_tg_name     = aws_lb_target_group.order_service_green.name
      ecs_service_name  = aws_ecs_service.order_service.name
    }
    payment-service = {
      prod_listener_arn = aws_lb_listener.payment_prod.arn
      test_listener_arn = aws_lb_listener.payment_test.arn
      blue_tg_name      = aws_lb_target_group.payment_service.name
      green_tg_name     = aws_lb_target_group.payment_service_green.name
      ecs_service_name  = aws_ecs_service.payment_service.name
    }
    user-service = {
      prod_listener_arn = aws_lb_listener.user_prod.arn
      test_listener_arn = aws_lb_listener.user_test.arn
      blue_tg_name      = aws_lb_target_group.user_service.name
      green_tg_name     = aws_lb_target_group.user_service_green.name
      ecs_service_name  = aws_ecs_service.user_service.name
    }
  }
}

resource "aws_codedeploy_app" "services" {
  for_each         = local.codedeploy_services
  name             = "${local.name_prefix}-${each.key}"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "services" {
  for_each = local.codedeploy_services

  app_name               = aws_codedeploy_app.services[each.key].name
  deployment_group_name  = "${local.name_prefix}-${each.key}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = each.value.ecs_service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [each.value.prod_listener_arn]
      }
      test_traffic_route {
        listener_arns = [each.value.test_listener_arn]
      }
      target_group {
        name = each.value.blue_tg_name
      }
      target_group {
        name = each.value.green_tg_name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
}

# ── CodePipeline ──────────────────────────────────────────────────────────────

resource "aws_codepipeline" "main" {
  name     = "${local.name_prefix}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_artifacts.bucket
    type     = "S3"
  }

  # ── Source ──
  stage {
    name = "Source"

    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        # CodePipeline's action provider string is still "CodeStarSourceConnection" —
        # AWS kept the identifier stable across the CodeConnections rename.
        ConnectionArn        = var.codeconnections_arn
        FullRepositoryId     = var.github_repository_id
        BranchName           = var.github_branch
        DetectChanges        = "true"
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  # ── Build ──
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  # ── Deploy: order-service ──
  stage {
    name = "Deploy-Order"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.services["order-service"].name
        DeploymentGroupName            = aws_codedeploy_deployment_group.services["order-service"].deployment_group_name
        TaskDefinitionTemplateArtifact = "build_output"
        TaskDefinitionTemplatePath     = "taskdef-order-service.json"
        AppSpecTemplateArtifact        = "build_output"
        AppSpecTemplatePath            = "appspec-order-service.yaml"
      }
    }
  }

  # ── Deploy: payment-service ──
  stage {
    name = "Deploy-Payment"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.services["payment-service"].name
        DeploymentGroupName            = aws_codedeploy_deployment_group.services["payment-service"].deployment_group_name
        TaskDefinitionTemplateArtifact = "build_output"
        TaskDefinitionTemplatePath     = "taskdef-payment-service.json"
        AppSpecTemplateArtifact        = "build_output"
        AppSpecTemplatePath            = "appspec-payment-service.yaml"
      }
    }
  }

  # ── Deploy: user-service ──
  stage {
    name = "Deploy-User"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.services["user-service"].name
        DeploymentGroupName            = aws_codedeploy_deployment_group.services["user-service"].deployment_group_name
        TaskDefinitionTemplateArtifact = "build_output"
        TaskDefinitionTemplatePath     = "taskdef-user-service.json"
        AppSpecTemplateArtifact        = "build_output"
        AppSpecTemplatePath            = "appspec-user-service.yaml"
      }
    }
  }
}
