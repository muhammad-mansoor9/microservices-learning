terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "microservices-learning-terraform-state-dev"
    key            = "scenario2/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "microservices-learning-terraform-locks-dev"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project  = "ms-learning"
      Scenario = "ecs"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }
