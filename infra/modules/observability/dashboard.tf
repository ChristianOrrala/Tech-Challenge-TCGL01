# Platform dashboard - one operator-facing view in triage order: SLO summary
# at the top, then traffic, compute, database, and ingestion, then alarm
# status at the bottom. Every metric widget's "region" is
# data.aws_region.current.name rather than a literal, so this file has zero
# region lock-in. Markdown text widgets mark the section breaks; transparent
# background so they render as headings, not empty cards.

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name

  dashboard_widgets = [
    # --- SLO summary --------------------------------------------------
    # One widget per row of the docs/slo.md table, in table order. The two
    # availability widgets are the same objective measured from two points
    # (canary at the edge, 5xx ratio at the ALB) - see docs/slo.md
    # "Measurement-point honesty" for why both exist.
    {
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 1
      properties = {
        markdown   = "## SLOs - availability 99.9% monthly (black-box canary + white-box ALB), p95 latency < 300 ms, freshness <= 10 min"
        background = "transparent"
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 1
      width  = 6
      height = 6
      properties = {
        title     = "Availability (black-box) - Canary Success %"
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
      y      = 1
      width  = 6
      height = 6
      properties = {
        title  = "Availability (white-box, 1h) - 1 - (5xx / requests)"
        view   = "gauge"
        region = local.region
        yAxis = {
          left = { min = 0, max = 1 }
        }
        # Same expression as the fast-burn alarm, with one display-side
        # addition: HTTPCode_* metrics only publish datapoints in periods
        # that saw at least one such response, so without FILL a clean hour
        # has no ratio to draw and the gauge goes blank. The alarm encodes
        # the same "quiet = available" intent via treat_missing_data.
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "m1", stat = "Sum", period = 3600, visible = false }],
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { id = "m2", stat = "Sum", period = 3600, visible = false }],
          [{ expression = "IF(m2 > 0, 1 - FILL(m1,0)/m2, 1)", label = "Availability", id = "e1" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 1
      width  = 6
      height = 6
      properties = {
        title     = "API Latency p95 (SLO < 300 ms)"
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
      y      = 1
      width  = 6
      height = 6
      properties = {
        # The handler publishes a constant 0 on success - cadence is the
        # signal, not the value; the freshness alarm pages on silence.
        title     = "Ingestion Heartbeat (0 = publishing)"
        view      = "singleValue"
        sparkline = true
        region    = local.region
        metrics = [
          ["TCGL01", "IngestionFreshnessSeconds", { stat = "Maximum", period = 300 }]
        ]
      }
    },

    # --- Traffic --------------------------------------------------------
    {
      type   = "text"
      x      = 0
      y      = 7
      width  = 24
      height = 1
      properties = {
        markdown   = "## Traffic - ALB"
        background = "transparent"
      }
    },
    # Target 5xx and ELB 5xx are different failure planes: ELB-generated
    # 5xx (mostly 503) appear when no healthy target exists and by
    # definition never count in the target-5xx SLI - the availability gauge
    # stays green while users get errors. Drawing both closes that gap.
    {
      type   = "metric"
      x      = 0
      y      = 8
      width  = 24
      height = 6
      properties = {
        title  = "ALB Requests & 5xx (target vs ALB-generated)"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", period = 300, label = "Requests", color = "#1f77b4" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", period = 300, label = "Target 5xx (app)", color = "#d62728", yAxis = "right" }],
          ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", period = 300, label = "ELB 5xx (ALB-generated)", color = "#ff7f0e", yAxis = "right" }]
        ]
        yAxis = {
          left  = { label = "Requests", min = 0 }
          right = { label = "5xx", min = 0 }
        }
      }
    },

    # --- Compute ----------------------------------------------------------
    {
      type   = "text"
      x      = 0
      y      = 14
      width  = 24
      height = 1
      properties = {
        markdown   = "## Compute - ECS"
        background = "transparent"
      }
    },
    # Running tasks (scheduler view) and healthy targets (ALB view) can
    # disagree - a task can be running yet failing health checks - so both
    # are drawn against the desired-count annotation.
    {
      type   = "metric"
      x      = 0
      y      = 15
      width  = 12
      height = 6
      properties = {
        title  = "API Capacity - ECS Tasks & ALB Healthy Targets"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300, label = "Running (ECS)", color = "#1f77b4" }],
          ["ECS/ContainerInsights", "PendingTaskCount", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300, label = "Pending (ECS)", color = "#ff7f0e" }],
          ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Average", period = 300, label = "Healthy targets (ALB)", color = "#2ca02c" }]
        ]
        yAxis = {
          left = { min = 0 }
        }
        annotations = {
          horizontal = [
            { label = "Desired", value = var.api_desired_count }
          ]
        }
      }
    },
    # AWS/ECS, not ECS/ContainerInsights: Container Insights publishes
    # absolute CpuUtilized/MemoryUtilized (units, MB), while the
    # percent-of-reserved utilization this widget draws only exists in the
    # AWS/ECS namespace.
    {
      type   = "metric"
      x      = 12
      y      = 15
      width  = 12
      height = 6
      properties = {
        title  = "ECS Service CPU & Memory (% of reserved)"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300, label = "CPU %" }],
          ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", period = 300, label = "Memory %" }]
        ]
        yAxis = {
          left = { min = 0, max = 100 }
        }
      }
    },

    # --- Database -----------------------------------------------------------
    {
      type   = "text"
      x      = 0
      y      = 21
      width  = 24
      height = 1
      properties = {
        markdown   = "## Database - RDS PostgreSQL"
        background = "transparent"
      }
    },
    # db.t4g.micro is burstable: credit exhaustion is the runbook's first
    # suspect for both the latency and rds-cpu-high alarms, so the credit
    # balance draws right next to CPU.
    {
      type   = "metric"
      x      = 0
      y      = 22
      width  = 8
      height = 6
      properties = {
        title  = "RDS CPU & Burst Credit Balance"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300, label = "CPU %", color = "#1f77b4" }],
          ["AWS/RDS", "CPUCreditBalance", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300, label = "Credit balance", color = "#7f7f7f", yAxis = "right" }]
        ]
        yAxis = {
          left  = { min = 0, max = 100 }
          right = { min = 0 }
        }
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 22
      width  = 8
      height = 6
      properties = {
        title  = "RDS Free Storage Space"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300 }]
        ]
        yAxis = {
          left = { min = 0 }
        }
        annotations = {
          horizontal = [
            # Mirrors the rds-storage-low alarm threshold.
            { label = "Alarm < 2 GB", value = 2000000000 }
          ]
        }
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 22
      width  = 8
      height = 6
      properties = {
        title  = "RDS Database Connections"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_identifier, { stat = "Average", period = 300 }]
        ]
        yAxis = {
          left = { min = 0 }
        }
      }
    },

    # --- Ingestion ------------------------------------------------------------
    {
      type   = "text"
      x      = 0
      y      = 28
      width  = 24
      height = 1
      properties = {
        markdown   = "## Ingestion - EventBridge rate(5 min) -> Lambda -> RDS"
        background = "transparent"
      }
    },
    # Duration rides the right axis: drift toward the 120 s function
    # timeout is a documented freshness-alarm cause long before Errors
    # goes nonzero.
    {
      type   = "metric"
      x      = 0
      y      = 29
      width  = 12
      height = 6
      properties = {
        title  = "Ingestion Lambda - Invocations, Errors & Duration"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name, { stat = "Sum", period = 300, label = "Invocations", color = "#1f77b4" }],
          ["AWS/Lambda", "Errors", "FunctionName", var.lambda_function_name, { stat = "Sum", period = 300, label = "Errors", color = "#d62728" }],
          ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "Maximum", period = 300, label = "Duration max (ms)", color = "#7f7f7f", yAxis = "right" }]
        ]
        yAxis = {
          left  = { min = 0 }
          right = { min = 0 }
        }
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 29
      width  = 12
      height = 6
      properties = {
        title  = "Events Upserted (per 5 min run)"
        view   = "timeSeries"
        region = local.region
        metrics = [
          ["TCGL01", "EventsUpserted", { stat = "Sum", period = 300, label = "Upserted" }]
        ]
        yAxis = {
          left = { min = 0 }
        }
      }
    },

    # --- Alarm status -----------------------------------------------
    {
      type   = "text"
      x      = 0
      y      = 35
      width  = 24
      height = 1
      properties = {
        markdown   = "## Alarms - alarm and OK actions both notify ${var.name_prefix}-alerts"
        background = "transparent"
      }
    },
    {
      type   = "alarm"
      x      = 0
      y      = 36
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
