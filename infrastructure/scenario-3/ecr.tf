locals {
  services = ["order-service", "payment-service", "user-service"]
}

resource "aws_ecr_repository" "service" {
  for_each = toset(local.services)

  name                 = "ms-learning/${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
