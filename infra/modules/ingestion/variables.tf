variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to create the ingestion Lambda security group in."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "IDs of the private subnets the ingestion Lambda runs in."
}

variable "db_sg_id" {
  type        = string
  description = "ID of the database security group; this module attaches the ingress rule allowing the ingestion security group to reach it on 5432."
}

variable "db_secret_arn" {
  type        = string
  description = "Secrets Manager ARN holding the database master credentials; granted to the Lambda role and injected as DB_SECRET_ARN."
}

variable "db_host" {
  type        = string
  description = "Hostname of the database the ingestion Lambda connects to."
}

variable "db_port" {
  type        = number
  description = "Port the database accepts connections on."
}

variable "db_name" {
  type        = string
  description = "Name of the database the ingestion Lambda connects to."
}
