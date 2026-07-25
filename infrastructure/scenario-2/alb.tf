# ── External ALB (order-service) ──────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${local.name_prefix}-alb" }
}

# Blue target group — receives production traffic between deployments
resource "aws_lb_target_group" "order_service" {
  name        = "${local.name_prefix}-order-blue-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-order-blue-tg" }
}

# Green target group — CodeDeploy shifts traffic here during blue/green deploys
resource "aws_lb_target_group" "order_service_green" {
  name        = "${local.name_prefix}-order-green-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-order-green-tg" }
}

# Production listener — CodeDeploy flips its default action between blue/green
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.order_service.arn
  }

  # CodeDeploy manages default_action.target_group_arn during blue/green swaps
  lifecycle {
    ignore_changes = [default_action]
  }
}

# Test listener — CodeDeploy uses this for pre-shift validation on green
resource "aws_lb_listener" "http_test" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.order_service_green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# ── Internal ALB (payment-service + user-service) ─────────────────────────────
# CodeDeploy blue/green requires each service to sit behind an ALB (or NLB).
# We keep payment and user off the public Internet by attaching them to an
# internal ALB reachable only from inside the VPC. Service-to-service traffic
# continues to flow via Service Connect; the ALB exists primarily to give
# CodeDeploy a listener to swap between blue and green target groups.

resource "aws_lb" "internal" {
  name               = "${local.name_prefix}-internal-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.internal_alb.id]
  subnets            = aws_subnet.private[*].id

  tags = { Name = "${local.name_prefix}-internal-alb" }
}

# ── Payment Service (internal ALB) ────────────────────────────────────────────

resource "aws_lb_target_group" "payment_service" {
  name        = "${local.name_prefix}-payment-blue-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-payment-blue-tg" }
}

resource "aws_lb_target_group" "payment_service_green" {
  name        = "${local.name_prefix}-payment-green-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-payment-green-tg" }
}

resource "aws_lb_listener" "payment_prod" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.payment_service.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "payment_test" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.payment_service_green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# ── User Service (internal ALB) ───────────────────────────────────────────────

resource "aws_lb_target_group" "user_service" {
  name        = "${local.name_prefix}-user-blue-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-user-blue-tg" }
}

resource "aws_lb_target_group" "user_service_green" {
  name        = "${local.name_prefix}-user-green-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-user-green-tg" }
}

resource "aws_lb_listener" "user_prod" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 81
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.user_service.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "user_test" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 8081
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.user_service_green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}
