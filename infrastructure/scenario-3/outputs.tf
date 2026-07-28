output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN used by all IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "node_group_iam_role_arn" {
  description = "IAM role ARN attached to the default managed node group"
  value       = try(values(module.eks.eks_managed_node_groups)[0].iam_role_arn, null)
}

output "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller"
  value       = module.aws_lb_controller_irsa.iam_role_arn
}

output "ebs_csi_driver_role_arn" {
  description = "IRSA role ARN attached to the aws-ebs-csi-driver addon"
  value       = module.ebs_csi_irsa.iam_role_arn
}

output "order_service_role_arn" {
  description = "IRSA role ARN for default/order-service"
  value       = module.order_service_irsa.iam_role_arn
}

output "payment_service_role_arn" {
  description = "IRSA role ARN for default/payment-service"
  value       = module.payment_service_irsa.iam_role_arn
}

output "user_service_role_arn" {
  description = "IRSA role ARN for default/user-service"
  value       = module.user_service_irsa.iam_role_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

output "kubeconfig_command" {
  description = "Command to update your local kubeconfig for kubectl access"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "order_events_queue_url" {
  description = "SQS queue URL consumed by payment-service and used by KEDA"
  value       = aws_sqs_queue.order_events.url
}

output "order_events_queue_arn" {
  description = "SQS queue ARN referenced by order/payment IRSA policies"
  value       = aws_sqs_queue.order_events.arn
}
