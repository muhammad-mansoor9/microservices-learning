variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "ms-learning-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones for the VPC (must be exactly 2 to match subnet lists)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Managed node group minimum size"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Managed node group maximum size"
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "Managed node group desired size"
  type        = number
  default     = 2
}

variable "users_table_name" {
  description = "DynamoDB users table name (user-service IRSA scope)"
  type        = string
  default     = "users"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Helm chart version for aws-load-balancer-controller"
  type        = string
  default     = "1.8.1"
}

variable "argocd_chart_version" {
  description = "Helm chart version for Argo CD"
  type        = string
  default     = "7.6.10"
}

variable "keda_chart_version" {
  description = "Helm chart version for KEDA"
  type        = string
  default     = "2.15.1"
}

variable "istio_chart_version" {
  description = "Helm chart version for Istio (base, istiod, gateway)"
  type        = string
  default     = "1.23.0"
}
