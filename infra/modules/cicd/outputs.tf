output "deploy_role_arn" {
  value       = aws_iam_role.deploy.arn
  description = "ARN of the IAM role GitHub Actions assumes via OIDC to deploy this stack; set as the repo's AWS_DEPLOY_ROLE_ARN secret."
}
