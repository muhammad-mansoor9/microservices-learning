# ALB — public-facing HTTP/HTTPS

resource "aws_security_group" "alb" {
  name        = "ms-learning-alb-sg"
  description = "Allow HTTP and HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ms-learning-alb-sg" }
}

# Application services

resource "aws_security_group" "app" {
  name        = "ms-learning-app-sg"
  description = "Allow app traffic from ALB and SSH from operator IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App ports from ALB"
    from_port       = 8080
    to_port         = 8888
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description     = "SSH from Jenkins (Ansible jump host)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  ingress {
    description = "Intra-app-sg: app servers to Eureka, Config Server, and each other"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "Prometheus scraping from monitoring instance"
    from_port       = 8080
    to_port         = 8888
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ms-learning-app-sg" }
}

# Infrastructure services (RabbitMQ, Keycloak, Eureka)

resource "aws_security_group" "infra" {
  name        = "ms-learning-infra-sg"
  description = "Allow infra ports from app tier"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "RabbitMQ AMQP"
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Keycloak"
    from_port       = 9090
    to_port         = 9090
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Eureka"
    from_port       = 8761
    to_port         = 8761
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "SSH from Jenkins (Ansible jump host)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins.id]
  }

  tags = { Name = "ms-learning-infra-sg" }
}

# Jenkins

resource "aws_security_group" "jenkins" {
  name        = "ms-learning-jenkins-sg"
  description = "Allow Jenkins UI and SSH from operator IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ms-learning-jenkins-sg" }
}

# Monitoring (Prometheus + Grafana)

resource "aws_security_group" "monitoring" {
  name        = "ms-learning-monitoring-sg"
  description = "Allow Prometheus and Grafana from operator IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ms-learning-monitoring-sg" }
}
