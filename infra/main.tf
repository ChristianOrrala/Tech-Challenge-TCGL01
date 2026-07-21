# Root module - components are wired here as they land.

module "network" {
  source      = "./modules/network"
  name_prefix = var.project
  vpc_cidr    = "10.42.0.0/16"
}
