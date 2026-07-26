output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
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

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_alb_client_id" {
  description = "Cognito app client ID for ALB (has secret)"
  value       = aws_cognito_user_pool_client.alb.id
}

output "cognito_api_test_client_id" {
  description = "Cognito app client ID for developer testing (no secret)"
  value       = aws_cognito_user_pool_client.api_test.id
}

output "cognito_hosted_ui_domain" {
  description = "Cognito hosted UI base URL"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "dynamodb_users_table" {
  description = "DynamoDB users table name"
  value       = aws_dynamodb_table.users.name
}

output "order_saga_state_machine_arn" {
  description = "ARN of the Order SAGA Step Functions state machine"
  value       = aws_sfn_state_machine.order_saga.arn
}

output "codepipeline_url" {
  description = "AWS console URL for the CI/CD pipeline"
  value       = "https://${var.aws_region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.main.name}/view?region=${var.aws_region}"
}

output "codepipeline_artifacts_bucket" {
  description = "S3 bucket that stores pipeline artifacts"
  value       = aws_s3_bucket.codepipeline_artifacts.bucket
}

output "internal_alb_dns_name" {
  description = "DNS name of the internal ALB fronting payment and user services"
  value       = aws_lb.internal.dns_name
}

output "cloudwatch_dashboard_url" {
  description = "AWS console URL for the CloudWatch dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.ecs.dashboard_name}"
}

output "alerts_sns_topic_arn" {
  description = "ARN of the SNS topic that receives CloudWatch alarm notifications"
  value       = aws_sns_topic.alerts.arn
}
