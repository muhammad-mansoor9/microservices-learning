#!/bin/bash
# Wait for LocalStack to be fully ready
echo "Initialising LocalStack resources..."

# Create DynamoDB users table
awslocal dynamodb create-table \
  --table-name users \
  --attribute-definitions AttributeName=userId,AttributeType=S \
  --key-schema AttributeName=userId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Create SQS queues (used from Scenario 1 onwards)
awslocal sqs create-queue --queue-name order-events
awslocal sqs create-queue --queue-name order-events-dlq
awslocal sqs create-queue --queue-name payment-events
awslocal sqs create-queue --queue-name payment-events-dlq

# Create SSM parameters (used from Scenario 2 onwards)
awslocal ssm put-parameter --name /ms-learning/payment/url --value http://payment-service:8080 --type String
awslocal ssm put-parameter --name /ms-learning/user/url --value http://user-service:8080 --type String

echo "LocalStack init complete"
