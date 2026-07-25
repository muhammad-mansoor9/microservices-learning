# ── Order Events ─────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "order_events_dlq" {
  name                      = "${local.name_prefix}-order-events-dlq"
  message_retention_seconds = 1209600

  tags = { Name = "${local.name_prefix}-order-events-dlq" }
}

resource "aws_sqs_queue" "order_events" {
  name                       = "${local.name_prefix}-order-events"
  visibility_timeout_seconds = 120

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${local.name_prefix}-order-events" }
}

# ── Payment Events ────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "payment_events_dlq" {
  name                      = "${local.name_prefix}-payment-events-dlq"
  message_retention_seconds = 1209600

  tags = { Name = "${local.name_prefix}-payment-events-dlq" }
}

resource "aws_sqs_queue" "payment_events" {
  name                       = "${local.name_prefix}-payment-events"
  visibility_timeout_seconds = 120

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.payment_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${local.name_prefix}-payment-events" }
}
