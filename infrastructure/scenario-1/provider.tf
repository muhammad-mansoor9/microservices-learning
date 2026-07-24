terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key = "scenario1/terraform.tfstate"
    # bucket and region must be provided via -backend-config or environment
  }
}

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "my_ip" {
  description = "Your public IP for SSH and admin access (CIDR notation, e.g. 1.2.3.4/32)"
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to use (leave empty to use the default profile or AWS_PROFILE env var)"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance"
  type        = string
  sensitive   = true
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project  = "ms-learning"
      Scenario = "ec2"
    }
  }
}
