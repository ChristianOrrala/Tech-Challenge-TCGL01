output "alb_dns_name" {
  value       = aws_lb.this.dns_name
  description = "Public DNS name of the API load balancer."
}

output "alb_arn_suffix" {
  value       = aws_lb.this.arn_suffix
  description = "ARN suffix of the API load balancer, for CloudWatch metric dimensions."
}

output "target_group_arn_suffix" {
  value       = aws_lb_target_group.api.arn_suffix
  description = "ARN suffix of the API target group, for CloudWatch metric dimensions."
}

output "ecr_repo_url" {
  value       = aws_ecr_repository.api.repository_url
  description = "URL of the ECR repository holding the API container image."
}

output "cluster_name" {
  value       = aws_ecs_cluster.this.name
  description = "Name of the ECS cluster running the API service."
}

output "service_name" {
  value       = aws_ecs_service.api.name
  description = "Name of the ECS service running the API task."
}

output "api_sg_id" {
  value       = aws_security_group.api.id
  description = "ID of the API service security group."
}
