variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.42.0.0/16"
  description = "CIDR block for the VPC."
}
