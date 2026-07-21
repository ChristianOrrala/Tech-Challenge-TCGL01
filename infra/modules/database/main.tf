# Database module - RDS PostgreSQL (Multi-AZ) on isolated subnets.
#
# The security group created here starts with no ingress and no egress
# rules. RDS never initiates outbound connections, so egress is omitted
# entirely. Ingress is added later by consuming modules (api, ingestion),
# each attaching its own aws_vpc_security_group_ingress_rule to db_sg_id -
# this avoids a dependency cycle between this module and theirs.

resource "aws_security_group" "db" {
  name   = "${var.name_prefix}-db"
  vpc_id = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.isolated_subnet_ids

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class
  multi_az       = true

  db_name  = "quakes"
  username = "quakes_admin"

  # No password argument anywhere - AWS creates and owns the secret.
  manage_master_user_password = true

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  backup_retention_period = 7
  deletion_protection     = false
  skip_final_snapshot     = true
  publicly_accessible     = false
  port                    = 5432
  copy_tags_to_snapshot   = true

  vpc_security_group_ids = [aws_security_group.db.id]
  db_subnet_group_name   = aws_db_subnet_group.this.name

  tags = {
    Name = "${var.name_prefix}-db"
  }
}
