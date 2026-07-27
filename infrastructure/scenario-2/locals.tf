locals {
  name_prefix = "ms-learning"
  services    = ["order-service", "payment-service", "user-service"]

  # X-Ray daemon sidecar, one instance per service. The AWS X-Ray SDK in
  # each Java app sends segments to 127.0.0.1:2000 UDP by default; because
  # ECS awsvpc containers in the same task share a network namespace,
  # the sidecar receives them there and forwards to the X-Ray API.
  # essential=false so a daemon crash doesn't kill the app container.
  xray_sidecar = {
    for svc in local.services : svc => {
      name              = "xray-daemon"
      image             = "public.ecr.aws/xray/aws-xray-daemon:latest"
      essential         = false
      cpu               = 32
      memoryReservation = 64
      portMappings      = [{ containerPort = 2000, protocol = "udp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.services[svc].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "xray"
        }
      }
    }
  }
}
