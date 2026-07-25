output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "ecr_order_service_url" {
  description = "ECR repository URL for order-service"
  value       = aws_ecr_repository.services["order-service"].repository_url
}

output "ecr_payment_service_url" {
  description = "ECR repository URL for payment-service"
  value       = aws_ecr_repository.services["payment-service"].repository_url
}

output "ecr_user_service_url" {
  description = "ECR repository URL for user-service"
  value       = aws_ecr_repository.services["user-service"].repository_url
}

output "rds_order_endpoint" {
  description = "Hostname of the order-service RDS instance"
  value       = aws_db_instance.order.address
}

output "rds_payment_endpoint" {
  description = "Hostname of the payment-service RDS instance"
  value       = aws_db_instance.payment.address
}

output "sqs_order_events_url" {
  description = "SQS queue URL for order-events"
  value       = aws_sqs_queue.order_events.url
}

output "sqs_order_events_dlq_url" {
  description = "SQS queue URL for order-events DLQ"
  value       = aws_sqs_queue.order_events_dlq.url
}

output "sqs_payment_events_url" {
  description = "SQS queue URL for payment-events"
  value       = aws_sqs_queue.payment_events.url
}

output "sqs_payment_events_dlq_url" {
  description = "SQS queue URL for payment-events DLQ"
  value       = aws_sqs_queue.payment_events_dlq.url
}
