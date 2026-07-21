variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "alb_dns_name" {
  type        = string
  description = "Public DNS name of the API load balancer; used as CloudFront's ALB-side origin."
}

variable "enable_waf" {
  type        = bool
  description = "Whether to provision the WAF Web ACL (and its us-east-1 dependencies) and attach it to the distribution."
}

variable "listener_arn" {
  type        = string
  description = "ARN of the API module's :80 ALB listener; this module attaches the origin-pinning forward rule to it."
}

variable "target_group_arn" {
  type        = string
  description = "ARN of the API target group; the origin-pinning listener rule forwards verified traffic here."
}
