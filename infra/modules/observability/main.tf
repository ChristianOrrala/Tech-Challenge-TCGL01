# Observability module - the SNS alert topic and the CloudWatch alarms that
# feed it. The Synthetics canary lives in canary.tf and the dashboard in
# dashboard.tf; this file holds the notification path and the alarms
# themselves, so the "what pages someone" surface stays in one place.

# --- Notifications ----------------------------------------------------
# Every alarm below sends both alarm_actions and ok_actions here, so a
# recovery is as visible as the original page. The email subscription is
# opt-in: var.alert_email == "" deploys the topic with zero subscribers,
# which keeps `terraform apply` usable without a real inbox on hand.

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"

  tags = {
    Name = "${var.name_prefix}-alerts"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Availability (fast burn) ------------------------------------------
# Metric-math alarm over a 1-hour window: 1 - (5xx / requests). IF() guards
# the division so an idle stack with zero requests evaluates to fully
# available (1) instead of NaN - a quiet demo account must not page itself.
# 5xx and request count are both read at the LoadBalancer dimension alone;
# this stack has exactly one target group per load balancer, so a
# TargetGroup dimension would be redundant, not more precise.

resource "aws_cloudwatch_metric_alarm" "availability_fast_burn" {
  alarm_name          = "${var.name_prefix}-availability-fast-burn"
  alarm_description   = "Composite availability (1 - 5xx/requests) dropped below 99% over the trailing hour."
  comparison_operator = "LessThanThreshold"
  threshold           = 0.99
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      stat        = "Sum"
      period      = 3600

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "m2"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      stat        = "Sum"
      period      = 3600

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
      }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "IF(m2 > 0, 1 - m1/m2, 1)"
    label       = "Availability"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-availability-fast-burn"
  }
}

# --- Latency --------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name_prefix}-latency-p95"
  alarm_description   = "API p95 response time exceeded 300ms for 3 consecutive 5-minute periods."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.3
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"
  period             = 300

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-latency-p95"
  }
}

# --- Data freshness ---------------------------------------------------
# treat_missing_data = "breaching" is deliberate: if the ingestion Lambda
# stops publishing this metric entirely - crash-looping, schedule disabled,
# an IAM break - that silence is itself staleness and must page. "No data"
# must not read as "no problem".

resource "aws_cloudwatch_metric_alarm" "data_freshness" {
  alarm_name          = "${var.name_prefix}-data-freshness"
  alarm_description   = "Newest earthquake event in the database is more than 15 minutes old."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 900
  evaluation_periods  = 1
  treat_missing_data  = "breaching"

  namespace   = "TCGL01"
  metric_name = "IngestionFreshnessSeconds"
  statistic   = "Maximum"
  period      = 300

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-data-freshness"
  }
}

# --- Ingestion failures -------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ingestion_failures" {
  alarm_name          = "${var.name_prefix}-ingestion-failures"
  alarm_description   = "Ingestion Lambda failed on 2 consecutive scheduled runs."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  statistic   = "Sum"
  period      = 300

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-ingestion-failures"
  }
}

# --- API capacity -------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_tasks_below_desired" {
  alarm_name          = "${var.name_prefix}-api-tasks-below-desired"
  alarm_description   = "Fewer ECS tasks running than the configured desired count."
  comparison_operator = "LessThanThreshold"
  threshold           = var.api_desired_count
  evaluation_periods  = 2
  treat_missing_data  = "breaching"

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  statistic   = "Average"
  period      = 300

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-api-tasks-below-desired"
  }
}

# --- Database -------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization above 80% for 2 consecutive 5-minute periods."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/RDS"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  period      = 300

  dimensions = {
    DBInstanceIdentifier = var.db_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-rds-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.name_prefix}-rds-storage-low"
  alarm_description   = "RDS free storage below 2 GB."
  comparison_operator = "LessThanThreshold"
  threshold           = 2000000000
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"
  statistic   = "Average"
  period      = 300

  dimensions = {
    DBInstanceIdentifier = var.db_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-rds-storage-low"
  }
}

# --- Synthetic heartbeat ------------------------------------------------
# References the canary defined in canary.tf - same module, one Terraform
# namespace, so the forward reference resolves without any extra wiring.

resource "aws_cloudwatch_metric_alarm" "canary_failing" {
  alarm_name          = "${var.name_prefix}-canary-failing"
  alarm_description   = "Synthetics heartbeat canary has failed for 2 consecutive runs."
  comparison_operator = "LessThanThreshold"
  threshold           = 100
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "breaching"

  namespace   = "CloudWatchSynthetics"
  metric_name = "SuccessPercent"
  statistic   = "Average"
  period      = 300

  dimensions = {
    CanaryName = aws_synthetics_canary.heartbeat.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.name_prefix}-canary-failing"
  }
}
