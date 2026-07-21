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

module "api" {
  source = "./modules/api"

  name_prefix        = var.project
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  db_sg_id      = module.database.db_sg_id
  db_secret_arn = module.database.master_user_secret_arn
  db_host       = module.database.db_endpoint
  db_port       = module.database.db_port
  db_name       = module.database.db_name

  image_tag     = var.image_tag
  desired_count = var.api_desired_count
}
