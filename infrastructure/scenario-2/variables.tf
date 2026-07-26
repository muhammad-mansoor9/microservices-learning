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

variable "codeconnections_arn" {
  description = "ARN of the AWS CodeConnections resource that grants CodePipeline read access to GitHub. (Formerly 'CodeStar Connections'; renamed by AWS in July 2024 when the CodeStar project service was shut down. The underlying capability is unchanged; ARNs now use the codeconnections: prefix but legacy codestar-connections: ARNs still work.) Create once via AWS console (Developer Tools → Settings → Connections) and paste the ARN here."
  type        = string
}

variable "github_repository_id" {
  description = "GitHub repository in owner/repo form that CodePipeline should pull from"
  type        = string
  default     = "muhammad-mansoor9/microservices-learning"
}

variable "github_branch" {
  description = "GitHub branch that CodePipeline should track"
  type        = string
  default     = "scenario-2-ecs"
}

variable "alert_email_address" {
  description = "Email address that receives CloudWatch alarm notifications via SNS. Leave empty to create the topic without a subscription."
  type        = string
  default     = ""
}
