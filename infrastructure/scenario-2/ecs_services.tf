# ── CloudWatch Log Groups ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "services" {
  for_each          = toset(local.services)
  name              = "/${local.name_prefix}/${each.key}"
  retention_in_days = 7

  tags = { Name = "/${local.name_prefix}/${each.key}" }
}

# ── Order Service ─────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "order_service" {
  family                   = "${local.name_prefix}-order-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.order_service.arn

  container_definitions = jsonencode([
    {
      name      = "order-service"
      image     = "${aws_ecr_repository.services["order-service"].repository_url}:latest"
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "prod" },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.services["order-service"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = "${local.name_prefix}-order-service" }
}

resource "aws_ecs_service" "order_service" {
  name                              = "order-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.order_service.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120

  # Blue/green deployments driven by CodeDeploy (see cicd.tf)
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.order_service.arn
    container_name   = "order-service"
    container_port   = 8080
  }

  # ECS registers each running task's ENI IP in Cloud Map so peers (and the
  # SAGA Lambdas) can resolve `order-service.ms-learning.local`.
  service_registries {
    registry_arn = aws_service_discovery_service.services["order-service"].arn
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener.http_test]

  # CodeDeploy owns task_definition + load_balancer swaps after initial create;
  # desired_count is autoscaled at runtime.
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  tags = { Name = "${local.name_prefix}-order-service" }
}

# ── Payment Service ───────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "payment_service" {
  family                   = "${local.name_prefix}-payment-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.payment_service.arn

  container_definitions = jsonencode([
    {
      name      = "payment-service"
      image     = "${aws_ecr_repository.services["payment-service"].repository_url}:latest"
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "prod" },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.services["payment-service"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = "${local.name_prefix}-payment-service" }
}

resource "aws_ecs_service" "payment_service" {
  name                              = "payment-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.payment_service.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.payment_service.arn
    container_name   = "payment-service"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["payment-service"].arn
  }

  depends_on = [aws_lb_listener.payment_prod, aws_lb_listener.payment_test]

  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  tags = { Name = "${local.name_prefix}-payment-service" }
}

# ── User Service ──────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "user_service" {
  family                   = "${local.name_prefix}-user-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.user_service.arn

  container_definitions = jsonencode([
    {
      name      = "user-service"
      image     = "${aws_ecr_repository.services["user-service"].repository_url}:latest"
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "prod" },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.services["user-service"].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = "${local.name_prefix}-user-service" }
}

resource "aws_ecs_service" "user_service" {
  name                              = "user-service"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.user_service.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.user_service.arn
    container_name   = "user-service"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["user-service"].arn
  }

  depends_on = [aws_lb_listener.user_prod, aws_lb_listener.user_test]

  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  tags = { Name = "${local.name_prefix}-user-service" }
}
