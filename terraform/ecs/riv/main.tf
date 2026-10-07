# Trimmed stack for the re:Invent CON340 demo.
#
#   ALB -> ui (Java) -> catalog (Go, in-memory)
#                    -> carts (Java) -> DynamoDB
#   orders and checkout are not deployed; the UI uses its built-in mocks for them.
#
# Reuses the upstream tags, vpc and images modules unchanged.

module "tags" {
  source           = "../../lib/tags"
  environment_name = var.environment_name
}

module "vpc" {
  source           = "../../lib/vpc"
  environment_name = var.environment_name
  tags             = module.tags.result
}

module "container_images" {
  source = "../../lib/images"

  container_image_overrides = {
    default_tag = var.image_tag
  }
}

locals {
  vpc_id          = module.vpc.inner.vpc_id
  vpc_cidr        = module.vpc.vpc_cidr
  private_subnets = module.vpc.inner.private_subnets
  public_subnets  = module.vpc.inner.public_subnets
}
