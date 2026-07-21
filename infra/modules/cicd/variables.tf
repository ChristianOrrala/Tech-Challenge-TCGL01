variable "name_prefix" {
  type        = string
  description = "Prefix used to name and tag resources created by this module."
}

variable "repo" {
  type        = string
  description = "GitHub repository, \"owner/name\", allowed to assume the deploy role via OIDC."
}
