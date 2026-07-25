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
