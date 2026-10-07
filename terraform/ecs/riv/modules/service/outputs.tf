output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = one(concat(aws_ecs_service.this[*].name, aws_ecs_service.ci_managed[*].name))
}

output "task_definition_family" {
  description = "Task definition family"
  value       = aws_ecs_task_definition.this.family
}

output "task_role_arn" {
  description = "Task role ARN"
  value       = aws_iam_role.task_role.arn
}

output "task_execution_role_arn" {
  description = "Task execution role ARN"
  value       = aws_iam_role.task_execution_role.arn
}

output "task_security_group_id" {
  description = "Task security group ID"
  value       = aws_security_group.this.id
}
