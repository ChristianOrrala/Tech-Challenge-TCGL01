output "vpc_id" {
  value       = aws_vpc.this.id
  description = "ID of the VPC."
}

output "vpc_cidr" {
  value       = aws_vpc.this.cidr_block
  description = "CIDR block of the VPC."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of the public subnets (routed to the internet gateway)."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "IDs of the private subnets (routed to the NAT gateway)."
}

output "isolated_subnet_ids" {
  value       = aws_subnet.isolated[*].id
  description = "IDs of the isolated subnets (no outbound route; RDS only)."
}
