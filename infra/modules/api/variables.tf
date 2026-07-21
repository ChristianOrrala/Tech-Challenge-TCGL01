variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to create the ALB and API security groups in."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "IDs of the public subnets the ALB is deployed into."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "IDs of the private subnets the ECS service tasks run in."
}

variable "db_sg_id" {
  type        = string
  description = "ID of the database security group; this module attaches the ingress rule allowing the API security group to reach it on 5432."
}

variable "db_secret_arn" {
  type        = string
  description = "Secrets Manager ARN holding the database master credentials; injected into the container as the DB_CREDS secret."
}

variable "db_host" {
  type        = string
  description = "Hostname of the database the API connects to."
}

variable "db_port" {
  type        = number
  description = "Port the database accepts connections on."
}

variable "db_name" {
  type        = string
  description = "Name of the database the API connects to."
}

variable "image_tag" {
  type        = string
  description = "Container image tag to deploy for the API service."
}

variable "desired_count" {
  type        = number
  description = "Desired number of running tasks for the API ECS service."
}
