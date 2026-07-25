# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch observability — dashboard, alarms, saved Logs Insights queries.
# Service log groups (/ms-learning/{order,payment,user}-service) live in
# ecs_services.tf and are referenced here, not redeclared.
# ══════════════════════════════════════════════════════════════════════════════

# ── SNS Topic for Alerts ──────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
  tags = { Name = "${local.name_prefix}-alerts" }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email_address == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email_address
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "ecs" {
  dashboard_name = "${local.name_prefix}-ecs"

  dashboard_body = jsonencode({
    widgets = [
      # ECS CPU utilisation — all three services
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ECS CPU Utilisation"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.order_service.name],
            [".", ".", ".", ".", ".", aws_ecs_service.payment_service.name],
            [".", ".", ".", ".", ".", aws_ecs_service.user_service.name],
          ]
        }
      },
      # ECS Memory utilisation — all three services
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ECS Memory Utilisation"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          stat    = "Average"
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.order_service.name],
            [".", ".", ".", ".", ".", aws_ecs_service.payment_service.name],
            [".", ".", ".", ".", ".", aws_ecs_service.user_service.name],
          ]
        }
      },
      # SQS queue depths — SAGA event backlog
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "SQS Queue Depth"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.order_events.name, { label = "order-events visible" }],
            [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "order-events in-flight" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", aws_sqs_queue.payment_events.name, { label = "payment-events visible" }],
            [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "payment-events in-flight" }],
          ]
        }
      },
      # ALB metrics
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB Traffic"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum", label = "Requests" }],
            [".", "HTTPCode_ELB_5XX_Count", ".", ".", { stat = "Sum", label = "5xx errors" }],
            [".", "TargetResponseTime", ".", ".", { stat = "Average", label = "Response time (s)", yAxis = "right" }],
          ]
        }
      },
      # Step Functions executions
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions Executions"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", aws_sfn_state_machine.order_saga.arn],
            [".", "ExecutionsFailed", ".", "."],
          ]
        }
      },
      # Custom metric: MsLearning/OrdersCreated
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Orders Created (custom)"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = [
            ["MsLearning", "OrdersCreated"],
          ]
        }
      },
    ]
  })
}

# ── Alarms ────────────────────────────────────────────────────────────────────

# ECS CPU > 80% for 2 periods — one alarm per service
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  for_each = {
    order-service   = aws_ecs_service.order_service.name
    payment-service = aws_ecs_service.payment_service.name
    user-service    = aws_ecs_service.user_service.name
  }

  alarm_name          = "${local.name_prefix}-${each.key}-cpu-high"
  alarm_description   = "ECS CPU utilisation over 80% for ${each.key}"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# SQS order-events in-flight > 50 → SAGA backlog building up
resource "aws_cloudwatch_metric_alarm" "sqs_order_events_backlog" {
  alarm_name          = "${local.name_prefix}-order-events-backlog"
  alarm_description   = "Order events in-flight > 50 (SAGA processing may be stalled)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesNotVisible"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 50
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.order_events.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Step Functions ExecutionsFailed > 5 in 5 min
resource "aws_cloudwatch_metric_alarm" "sfn_executions_failed" {
  alarm_name          = "${local.name_prefix}-order-saga-failures"
  alarm_description   = "Order SAGA ExecutionsFailed > 5 in 5 minutes"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.order_saga.arn
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ALB 5xx rate > 5% for 2 periods — metric-math alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${local.name_prefix}-alb-5xx-rate-high"
  alarm_description   = "ALB HTTP 5xx rate above 5% for two consecutive minutes"
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "IF(requests > 0, 100 * (elb_5xx + tg_5xx) / requests, 0)"
    label       = "5xx rate (%)"
    return_data = true
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "elb_5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "tg_5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# RDS FreeStorageSpace < 1 GiB — one alarm per instance
resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  for_each = {
    order   = aws_db_instance.order.identifier
    payment = aws_db_instance.payment.identifier
  }

  alarm_name         = "${local.name_prefix}-${each.key}-rds-free-storage-low"
  alarm_description  = "RDS ${each.key} FreeStorageSpace below 1 GiB"
  namespace          = "AWS/RDS"
  metric_name        = "FreeStorageSpace"
  statistic          = "Average"
  period             = 300
  evaluation_periods = 1
  # 1 GiB in bytes
  threshold           = 1073741824
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = each.value
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── CloudWatch Logs Insights Saved Queries ────────────────────────────────────

locals {
  service_log_group_names = [for lg in aws_cloudwatch_log_group.services : lg.name]
}

resource "aws_cloudwatch_query_definition" "recent_errors" {
  name            = "${local.name_prefix}/RecentErrors"
  log_group_names = local.service_log_group_names

  query_string = <<-EOT
    fields @timestamp, service, level, traceId, logger, message
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 200
  EOT
}

resource "aws_cloudwatch_query_definition" "orders_by_status" {
  name            = "${local.name_prefix}/OrdersByStatus"
  log_group_names = [aws_cloudwatch_log_group.services["order-service"].name]

  query_string = <<-EOT
    fields @timestamp, message
    | filter message like /order/
    | parse message /status[=: ]+(?<status>[A-Z]+)/
    | filter ispresent(status)
    | stats count() as events by status
  EOT
}

resource "aws_cloudwatch_query_definition" "trace_search" {
  name            = "${local.name_prefix}/TraceSearch"
  log_group_names = local.service_log_group_names

  # Replace TRACE_ID_HERE with the X-Amzn-Trace-Id you're tracking.
  query_string = <<-EOT
    fields @timestamp, service, level, traceId, logger, message
    | filter traceId = "TRACE_ID_HERE"
    | sort @timestamp asc
    | limit 500
  EOT
}
