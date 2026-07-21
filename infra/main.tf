# Root module - components are wired here as they land.

module "network" {
  source      = "./modules/network"
  name_prefix = var.project
  vpc_cidr    = "10.42.0.0/16"
}

module "database" {
  source              = "./modules/database"
  name_prefix         = var.project
  vpc_id              = module.network.vpc_id
  isolated_subnet_ids = module.network.isolated_subnet_ids
  instance_class      = var.db_instance_class
}
