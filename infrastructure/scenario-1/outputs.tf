output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "jenkins_public_ip" {
  description = "Public IP of the Jenkins EC2 instance"
  value       = aws_instance.jenkins.public_ip
}

output "eureka_server_private_ip" {
  description = "Private IP of the Eureka Server instance"
  value       = aws_instance.eureka_server.private_ip
}

output "config_server_private_ip" {
  description = "Private IP of the Config Server instance"
  value       = aws_instance.config_server.private_ip
}

output "rabbitmq_private_ip" {
  description = "Private IP of the RabbitMQ instance"
  value       = aws_instance.rabbitmq.private_ip
}

output "keycloak_private_ip" {
  description = "Private IP of the Keycloak instance"
  value       = aws_instance.keycloak.private_ip
}

output "monitoring_private_ip" {
  description = "Private IP of the Monitoring instance (Prometheus + Grafana)"
  value       = aws_instance.monitoring.private_ip
}

output "monitoring_public_ip" {
  description = "Public IP of the Monitoring instance"
  value       = aws_instance.monitoring.public_ip
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port) — use as DB_URL host in Ansible"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_host" {
  description = "RDS hostname only (without port)"
  value       = aws_db_instance.postgres.address
}
