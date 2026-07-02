variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Used as a prefix for all resource names"
  type        = string
  default     = "microservices-learning"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "localstack_endpoint" {
  description = "Set to http://localhost:4566 to target LocalStack instead of AWS"
  type        = string
  default     = null
}
