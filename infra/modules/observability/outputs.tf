output "dashboard_name" {
  value       = aws_cloudwatch_dashboard.platform.dashboard_name
  description = "Name of the CloudWatch platform dashboard."
}

output "sns_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN of the SNS topic all alarms notify; subscribe additional endpoints here if needed."
}

output "canary_name" {
  value       = aws_synthetics_canary.heartbeat.name
  description = "Name of the Synthetics heartbeat canary."
}
