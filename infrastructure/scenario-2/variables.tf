variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "db_username" {
  description = "Master username for RDS instances"
  type        = string
  default     = "mslearning"
}

variable "db_password" {
  description = "Master password for RDS instances"
  type        = string
  sensitive   = true
}

variable "alb_callback_domain" {
  description = "Domain used for Cognito ALB callback URLs (set to your ALB/custom domain when HTTPS is enabled)"
  type        = string
  default     = "placeholder.example.com"
}
