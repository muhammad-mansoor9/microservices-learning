# IAM role that every EC2 instance in this scenario assumes
resource "aws_iam_role" "ec2" {
  name = "ms-learning-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "ms-learning-ec2-role" }
}

# S3: read JAR artifacts uploaded by Jenkins
resource "aws_iam_role_policy" "s3_artifacts" {
  name = "ms-learning-s3-artifacts"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::ms-learning-artifacts",
          "arn:aws:s3:::ms-learning-artifacts/*"
        ]
      }
    ]
  })
}

# DynamoDB: user-service reads/writes the users table
resource "aws_iam_role_policy" "dynamodb" {
  name = "ms-learning-dynamodb"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:*:table/users"
      }
    ]
  })
}

# SSM Session Manager — lets you shell into private instances from the AWS
# Console without needing a bastion host or open SSH port
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The instance profile is the wrapper that attaches the role to an EC2 instance
resource "aws_iam_instance_profile" "ec2" {
  name = "ms-learning-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = { Name = "ms-learning-ec2-profile" }
}
