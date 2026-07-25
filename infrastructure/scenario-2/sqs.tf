# ── Order Events ─────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "order_events_dlq" {
  name                      = "order-events-dlq"
  message_retention_seconds = 1209600

  tags = { Name = "order-events-dlq" }
}

resource "aws_sqs_queue" "order_events" {
  name = "order-events"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "order-events" }
}

# ── Payment Events ────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "payment_events_dlq" {
  name                      = "payment-events-dlq"
  message_retention_seconds = 1209600

  tags = { Name = "payment-events-dlq" }
}

resource "aws_sqs_queue" "payment_events" {
  name = "payment-events"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.payment_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "payment-events" }
}
