resource "aws_s3_bucket" "artifacts" {
  bucket        = "ms-learning-artifacts"
  force_destroy = true

  tags = { Name = "ms-learning-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}
