# Root outputs - populated as components land.

output "vpc_id" {
  value       = module.network.vpc_id
  description = "VPC id"
}
