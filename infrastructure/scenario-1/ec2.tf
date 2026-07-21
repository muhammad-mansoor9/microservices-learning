# Latest Amazon Linux 2023 AMI

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Launch template for ASG (app services)

resource "aws_launch_template" "app" {
  name_prefix   = "ms-learning-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.small"
  key_name      = "ms-learning-key"

  vpc_security_group_ids = [aws_security_group.app.id]

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "ms-learning-app" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group

resource "aws_autoscaling_group" "app" {
  name                = "ms-learning-app-asg"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  target_group_arns   = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "ms-learning-app-asg"
    propagate_at_launch = true
  }
}

# Eureka Server (private subnet)

resource "aws_instance" "eureka_server" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private_a.id
  key_name               = "ms-learning-key"
  vpc_security_group_ids = [aws_security_group.app.id]

  tags = { Name = "ms-learning-eureka-server" }
}

# Config Server (private subnet)

resource "aws_instance" "config_server" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private_a.id
  key_name               = "ms-learning-key"
  vpc_security_group_ids = [aws_security_group.app.id]

  tags = { Name = "ms-learning-config-server" }
}

# RabbitMQ (private subnet)

resource "aws_instance" "rabbitmq" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private_b.id
  key_name               = "ms-learning-key"
  vpc_security_group_ids = [aws_security_group.infra.id]

  tags = { Name = "ms-learning-rabbitmq" }
}

# Keycloak (private subnet)

resource "aws_instance" "keycloak" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private_b.id
  key_name               = "ms-learning-key"
  vpc_security_group_ids = [aws_security_group.infra.id]

  tags = { Name = "ms-learning-keycloak" }
}

# Jenkins (public subnet)

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.public_a.id
  key_name                    = "ms-learning-key"
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  associate_public_ip_address = true

  tags = { Name = "ms-learning-jenkins" }
}

# Monitoring — Prometheus + Grafana (public subnet)

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public_b.id
  key_name                    = "ms-learning-key"
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  associate_public_ip_address = true

  tags = { Name = "ms-learning-monitoring" }
}
