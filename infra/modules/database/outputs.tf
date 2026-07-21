output "db_endpoint" {
  value       = aws_db_instance.this.address
  description = "Hostname of the RDS instance (no port suffix)."
}

output "db_port" {
  value       = aws_db_instance.this.port
  description = "Port the RDS instance accepts connections on."
}

output "db_name" {
  value       = aws_db_instance.this.db_name
  description = "Name of the default database."
}

output "master_user_secret_arn" {
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  description = "Secrets Manager ARN holding the managed master user credentials."
}

output "db_sg_id" {
  value       = aws_security_group.db.id
  description = "ID of the database security group; consuming modules attach their own ingress rules to it."
}
