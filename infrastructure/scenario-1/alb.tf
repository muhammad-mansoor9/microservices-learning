resource "aws_lb" "main" {
  name               = "ms-learning-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = { Name = "ms-learning-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "ms-learning-app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/actuator/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "ms-learning-app-tg" }
}

# Only api-gateway sits behind the ALB — the other three services are internal.
resource "aws_lb_target_group_attachment" "api_gateway" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.api_gateway.id
  port             = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
