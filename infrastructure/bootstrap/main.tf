terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  using_localstack = var.localstack_endpoint != null
  bucket_name      = "${var.project_name}-terraform-state-${var.environment}"
  table_name       = "${var.project_name}-terraform-locks-${var.environment}"
}

provider "aws" {
  region = var.aws_region

  # Fake credentials are required by LocalStack; real AWS picks them up from the environment.
  access_key = local.using_localstack ? "test" : null
  secret_key = local.using_localstack ? "test" : null

  skip_credentials_validation = local.using_localstack
  skip_metadata_api_check     = local.using_localstack
  skip_requesting_account_id  = local.using_localstack

  # Path-style URLs are required by LocalStack S3.
  s3_use_path_style = local.using_localstack

  dynamic "endpoints" {
    for_each = local.using_localstack ? [var.localstack_endpoint] : []
    content {
      s3       = endpoints.value
      dynamodb = endpoints.value
      iam      = endpoints.value
      sts      = endpoints.value
    }
  }
}

# ---------------------------------------------------------------------------
# S3 bucket for remote Terraform state
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = local.bucket_name

  # Prevent accidental deletion when the bucket holds live state files.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB table for state locking
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_locks" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}
