variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to create the database security group in."
}

variable "isolated_subnet_ids" {
  type        = list(string)
  description = "IDs of the isolated subnets used for the DB subnet group."
}

variable "instance_class" {
  type        = string
  description = "RDS instance class for the PostgreSQL database."
}
