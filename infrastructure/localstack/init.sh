#!/bin/bash
set -e

echo "Creating DynamoDB users table..."
aws dynamodb create-table \
  --endpoint-url http://localstack:4566 \
  --region us-east-1 \
  --table-name users \
  --attribute-definitions AttributeName=userId,AttributeType=S \
  --key-schema AttributeName=userId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

echo "Creating SQS order-events queue..."
aws sqs create-queue \
  --endpoint-url http://localstack:4566 \
  --region us-east-1 \
  --queue-name order-events

echo "LocalStack init complete."
