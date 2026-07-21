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

module "ingestion" {
  source = "./modules/ingestion"

  name_prefix        = var.project
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  db_sg_id      = module.database.db_sg_id
  db_secret_arn = module.database.master_user_secret_arn
  db_host       = module.database.db_endpoint
  db_port       = module.database.db_port
  db_name       = module.database.db_name
}

module "edge" {
  source = "./modules/edge"

  # configuration_aliases forces an explicit providers map; once present,
  # it stops all implicit inheritance for the "aws" local name (not just
  # the aliased entry), so the default provider has to be re-listed here
  # too or every non-WAF resource in the module fails to resolve one.
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix      = var.project
  alb_dns_name     = module.api.alb_dns_name
  listener_arn     = module.api.listener_arn
  target_group_arn = module.api.target_group_arn
  enable_waf       = var.enable_waf
}

module "observability" {
  source = "./modules/observability"

  name_prefix = var.project
  alert_email = var.alert_email

  alb_arn_suffix          = module.api.alb_arn_suffix
  target_group_arn_suffix = module.api.target_group_arn_suffix
  cluster_name            = module.api.cluster_name
  service_name            = module.api.service_name
  api_desired_count       = var.api_desired_count

  lambda_function_name = module.ingestion.lambda_function_name

  db_identifier = "${var.project}-db"

  cloudfront_domain = module.edge.cloudfront_domain
}

module "cicd" {
  source = "./modules/cicd"

  name_prefix = var.project
  repo        = "ChristianOrrala/Tech-Challenge-TCGL01"
}
