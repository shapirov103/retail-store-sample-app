locals {
  service_common = {
    environment_name                = var.environment_name
    cluster_arn                     = aws_ecs_cluster.this.arn
    vpc_id                          = local.vpc_id
    vpc_cidr                        = local.vpc_cidr
    subnet_ids                      = local.private_subnets
    service_discovery_namespace_arn = aws_service_discovery_private_dns_namespace.this.arn
    cloudwatch_logs_group_id        = aws_cloudwatch_log_group.tasks.name
    opentelemetry_enabled           = var.opentelemetry_enabled
  }
}

# Catalog: Go. The service broken on stage. CI-managed, so the CD workflow owns
# its task definition revisions after the first apply.
module "catalog" {
  source = "./modules/service"

  service_name     = "catalog"
  container_image  = module.container_images.result.catalog.url
  healthcheck_path = "/health"
  ci_managed       = true

  # Demo setting: replace the single catalog task in place (old task stops first). A bad deploy
  # then takes catalog down and users see errors, instead of the old task quietly staying up.
  # ECS defaults (min 100, max 200) would hide the failed deployment from users.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Circuit breaker on, rollback off: after 3 failed tasks ECS marks the deployment FAILED and stops
  # retrying, but leaves the broken revision in place. Setting rollback = true is the "prevent" step:
  # ECS then restores the last COMPLETED deployment on its own.
  deployment_circuit_breaker_enabled  = true
  deployment_circuit_breaker_rollback = false

  environment_variables = {
    RETAIL_CATALOG_PERSISTENCE_PROVIDER = "in-memory"
    RETAIL_CATALOG_SEARCH_ENABLED       = "false"
  }

  environment_name                = local.service_common.environment_name
  cluster_arn                     = local.service_common.cluster_arn
  vpc_id                          = local.service_common.vpc_id
  vpc_cidr                        = local.service_common.vpc_cidr
  subnet_ids                      = local.service_common.subnet_ids
  service_discovery_namespace_arn = local.service_common.service_discovery_namespace_arn
  cloudwatch_logs_group_id        = local.service_common.cloudwatch_logs_group_id
  opentelemetry_enabled           = local.service_common.opentelemetry_enabled
}

module "carts" {
  source = "./modules/service"

  service_name     = "carts"
  container_image  = module.container_images.result.cart.url
  healthcheck_path = "/actuator/health"

  environment_variables = {
    RETAIL_CART_PERSISTENCE_PROVIDER            = "dynamodb"
    RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME = aws_dynamodb_table.carts.name
  }

  additional_task_role_iam_policy_arns = [aws_iam_policy.carts_dynamodb.arn]

  environment_name                = local.service_common.environment_name
  cluster_arn                     = local.service_common.cluster_arn
  vpc_id                          = local.service_common.vpc_id
  vpc_cidr                        = local.service_common.vpc_cidr
  subnet_ids                      = local.service_common.subnet_ids
  service_discovery_namespace_arn = local.service_common.service_discovery_namespace_arn
  cloudwatch_logs_group_id        = local.service_common.cloudwatch_logs_group_id
  opentelemetry_enabled           = local.service_common.opentelemetry_enabled
}

module "ui" {
  source = "./modules/service"

  service_name         = "ui"
  container_image      = module.container_images.result.ui.url
  healthcheck_path     = "/actuator/health"
  alb_target_group_arn = aws_lb_target_group.ui.arn

  # Service Connect aliases resolve to port 80 (modules/service/ecs.tf).
  # Checkout and orders endpoints are left unset on purpose: the UI falls back
  # to in-process mocks (src/ui/README.md, RETAIL_UI_ENDPOINTS_*).
  environment_variables = {
    RETAIL_UI_ENDPOINTS_CATALOG = "http://${module.catalog.ecs_service_name}"
    RETAIL_UI_ENDPOINTS_CARTS   = "http://${module.carts.ecs_service_name}"
    RETAIL_UI_SEARCH_ENABLED    = "false"
  }

  environment_name                = local.service_common.environment_name
  cluster_arn                     = local.service_common.cluster_arn
  vpc_id                          = local.service_common.vpc_id
  vpc_cidr                        = local.service_common.vpc_cidr
  subnet_ids                      = local.service_common.subnet_ids
  service_discovery_namespace_arn = local.service_common.service_discovery_namespace_arn
  cloudwatch_logs_group_id        = local.service_common.cloudwatch_logs_group_id
  opentelemetry_enabled           = local.service_common.opentelemetry_enabled

  # UI must start after its dependencies exist, and only once the ALB listener exists.
  depends_on = [aws_lb_listener.http]
}
