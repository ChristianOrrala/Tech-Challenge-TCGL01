variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "alert_email" {
  type        = string
  description = "Email address for alarm notifications; empty string disables the SNS email subscription."
}

variable "alb_arn_suffix" {
  type        = string
  description = "ARN suffix of the API load balancer, for CloudWatch metric dimensions."
}

variable "target_group_arn_suffix" {
  type        = string
  description = "ARN suffix of the API target group, for CloudWatch metric dimensions."
}

variable "cluster_name" {
  type        = string
  description = "Name of the ECS cluster running the API service."
}

variable "service_name" {
  type        = string
  description = "Name of the ECS service running the API task."
}

variable "api_desired_count" {
  type        = number
  description = "Desired number of running tasks for the API ECS service; the running-task alarm fires below this value."
}

variable "lambda_function_name" {
  type        = string
  description = "Name of the ingestion Lambda function, for CloudWatch metric dimensions and dashboard widgets."
}

variable "db_identifier" {
  type        = string
  description = "Identifier of the RDS database instance, for CloudWatch metric dimensions."
}

variable "cloudfront_domain" {
  type        = string
  description = "CloudFront distribution domain name the Synthetics canary probes."
}
