resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.name_prefix}-cluster" }
}

resource "aws_service_discovery_private_dns_namespace" "ms_learning" {
  name        = "ms-learning.local"
  description = "Private DNS namespace for ECS Service Connect"
  vpc         = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-namespace" }
}
