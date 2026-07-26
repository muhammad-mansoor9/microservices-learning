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
  description = "Private DNS namespace for ECS Service Discovery (Cloud Map)"
  vpc         = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-namespace" }
}

# ── Cloud Map services (one per ECS service) ──────────────────────────────────
# ECS `service_registries` needs an explicit aws_service_discovery_service to
# reference. Service Connect used to create these implicitly, but CODE_DEPLOY
# deployment controller and Service Connect are mutually exclusive, so we use
# classic ECS Service Discovery here.

resource "aws_service_discovery_service" "services" {
  for_each = toset(local.services)

  name = each.key

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.ms_learning.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = { Name = "${local.name_prefix}-${each.key}-discovery" }
}
