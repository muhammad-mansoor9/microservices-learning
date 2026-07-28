resource "aws_sqs_queue" "order_events" {
  name = "order-events"

  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20     # long polling
}
