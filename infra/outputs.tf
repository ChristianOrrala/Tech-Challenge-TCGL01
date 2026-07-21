# Root outputs - populated as components land.

output "vpc_id" {
  value       = module.network.vpc_id
  description = "VPC id"
}

output "alb_dns_name" {
  value       = module.api.alb_dns_name
  description = "Public DNS name of the API load balancer."
}

output "ecr_repo_url" {
  value       = module.api.ecr_repo_url
  description = "URL of the ECR repository holding the API container image."
}

output "cloudfront_domain" {
  value       = module.edge.cloudfront_domain
  description = "Live URL host"
}

output "spa_bucket_name" {
  value       = module.edge.spa_bucket_name
  description = "Name of the S3 bucket serving the SPA static assets."
}

output "distribution_id" {
  value       = module.edge.distribution_id
  description = "ID of the CloudFront distribution."
}

output "dashboard_name" {
  value       = module.observability.dashboard_name
  description = "Name of the CloudWatch platform dashboard."
}
