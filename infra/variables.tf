variable "project" {
  type        = string
  default     = "tcgl01"
  description = "Short project slug used to name and tag resources."
}

variable "env" {
  type        = string
  default     = "demo"
  description = "Deployment environment name (e.g. demo, staging, prod)."
}

variable "region" {
  type        = string
  default     = "us-east-2"
  description = "Primary AWS region for regional resources."
}

variable "enable_waf" {
  type        = bool
  default     = false
  description = "Deploy the CloudFront-scope WAF WebACL (us-east-1). Opt-in: default keeps the stack entirely in the workload region."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email for alarm notifications; empty string disables the SNS subscription."
}

variable "db_instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "RDS instance class for the PostgreSQL database."
}

variable "api_desired_count" {
  type        = number
  default     = 2
  description = "Desired number of running tasks for the API ECS service."
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Container image tag to deploy for the API service."
}
