# Platform dashboard - one operator-facing view: SLO summary at the top,
# then traffic, compute, data, and ingestion, then alarm status at the
# bottom. Every metric widget's "region" is data.aws_region.current.name
# rather than a literal, so this file has zero region lock-in.

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name

  dashboard_widgets = [
    # --- Row 0: SLO summary ------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 0
      width  = 6
      height = 6
      properties = {
        title     = "Canary Success Rate"
        view      = "singleValue"
        sparkline = true
        region    = local.region
        metrics = [
          ["CloudWatchSynthetics", "SuccessPercent", "CanaryName", aws_synthetics_canary.heartbeat.name, { stat = "Average", period = 300 }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 6
      y      = 0
      width  = 6
      height = 6
      properties = {
        title  = "Availability (1h, 5xx/requests)"
        view   = "gauge"
        region = local.region
        yAxis = {
          left = { min = 0, max = 1 }
        }
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "m1", stat = "Sum", period = 3600, visible = false }],
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { id = "m2", stat = "Sum", period = 3600, visible = false }],
          [{ expression = "IF(m2 > 0, 1 - m1/m2, 1)", label = "Availability", id = "e1" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 0
      width  = 6
      height = 6
      properties = {
        title     = "API p95 Latency"
        view      = "singleValue"
        sparkline = true
        region    = local.region
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "p95", period = 300 }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 18
      y      = 0
      width  = 6
      height = 6
      properties = {
        title     = "Ingestion heartbeat"
        view      = "singleValue"
        sparkline = true
        region    = local.region
        metrics = [
          ["TCGL01", "IngestionFreshnessSeconds", { stat = "Maximum", period = 300 }]
        ]
      }
    },

    # --- Row 1: traffic ------------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 6
      width  = 24
      height = 6
      properties = {
        title  = "ALB Requests & 5xx Errors"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", period = 300, label = "Requests" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", period = 300, label = "5xx Errors", yAxis = "right" }]
        ]
        yAxis = {
          left  = { label = "Requests", min = 0 }
          right = { label = "5xx", min = 0 }
        }
      }
    },

    # --- Row 2: compute -------------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 12
      width  = 12
      height = 6
      properties = {
        title  = "ECS Running Tasks"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300 }]
        ]
        annotations = {
          horizontal = [
            { label = "Desired", value = var.api_desired_count }
          ]
        }
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 12
      width  = 12
      height = 6
      properties = {
        title  = "ECS CPU / Memory Utilization"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["ECS/ContainerInsights", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300, label = "CPU %" }],
          ["ECS/ContainerInsights", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300, label = "Memory %" }]
        ]
        yAxis = {
          left = { min = 0, max = 100 }
        }
      }
    },

    # --- Row 3: data (RDS) -----------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 18
      width  = 8
      height = 6
      properties = {
        title  = "RDS CPU Utilization"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300 }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 18
      width  = 8
      height = 6
      properties = {
        title  = "RDS Free Storage Space"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300 }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 18
      width  = 8
      height = 6
      properties = {
        title  = "RDS Database Connections"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300 }]
        ]
      }
    },

    # --- Row 4: ingestion -------------------------------------------------
    {
      type   = "metric"
      x      = 0
      y      = 24
      width  = 12
      height = 6
      properties = {
        title  = "Ingestion Lambda Invocations & Errors"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name, { stat = "Sum", period = 300 }],
          ["AWS/Lambda", "Errors", "FunctionName", var.lambda_function_name, { stat = "Sum", period = 300 }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 24
      width  = 12
      height = 6
      properties = {
        title  = "Events Upserted"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["TCGL01", "EventsUpserted", { stat = "Sum", period = 300 }]
        ]
      }
    },

    # --- Row 5: alarm status -----------------------------------------
    {
      type   = "alarm"
      x      = 0
      y      = 30
      width  = 24
      height = 8
      properties = {
        title = "Alarm Status"
        alarms = [
          aws_cloudwatch_metric_alarm.availability_fast_burn.arn,
          aws_cloudwatch_metric_alarm.latency_p95.arn,
          aws_cloudwatch_metric_alarm.data_freshness.arn,
          aws_cloudwatch_metric_alarm.ingestion_failures.arn,
          aws_cloudwatch_metric_alarm.api_tasks_below_desired.arn,
          aws_cloudwatch_metric_alarm.rds_cpu_high.arn,
          aws_cloudwatch_metric_alarm.rds_storage_low.arn,
          aws_cloudwatch_metric_alarm.canary_failing.arn,
        ]
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${var.name_prefix}-platform"
  dashboard_body = jsonencode({
    widgets = local.dashboard_widgets
  })
}
