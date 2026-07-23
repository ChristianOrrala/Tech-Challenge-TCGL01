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
  # Embeds the account id; the deploy workflow's logs are public, and a
  # plain `terraform output` dump would otherwise print it in the clear.
  sensitive = true
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

output "deploy_role_arn" {
  # null when var.enable_cicd is false (module.cicd has count 0).
  value       = one(module.cicd[*].deploy_role_arn)
  description = "ARN of the IAM role GitHub Actions assumes via OIDC to deploy this stack; set as the repo's AWS_DEPLOY_ROLE_ARN secret."
  sensitive   = true
}
