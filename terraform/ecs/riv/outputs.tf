output "application_url" {
  description = "Store URL"
  value       = "http://${aws_lb.ui.dns_name}"
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "catalog_service_name" {
  value = module.catalog.ecs_service_name
}

output "catalog_task_family" {
  value = module.catalog.task_definition_family
}

output "catalog_ecr_repository" {
  description = "Repository name for ECR_REPOSITORY in the deploy workflow"
  value       = aws_ecr_repository.catalog.name
}

output "github_deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub"
  value       = aws_iam_role.github_deploy.arn
}

output "github_variables" {
  description = "Paste into GitHub: Settings > Secrets and variables > Actions > Variables"
  value = {
    AWS_REGION          = var.region
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.github_deploy.arn
    ECR_REPOSITORY      = aws_ecr_repository.catalog.name
    ECS_CLUSTER         = aws_ecs_cluster.this.name
    ECS_SERVICE         = module.catalog.ecs_service_name
    ECS_TASK_FAMILY     = module.catalog.task_definition_family
    ECS_CONTAINER_NAME  = "catalog-service"
  }
}
