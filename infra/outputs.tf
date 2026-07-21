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
