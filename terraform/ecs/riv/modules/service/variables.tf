variable "environment_name" {
  type        = string
  description = "Name of the environment"
}

variable "service_name" {
  type        = string
  description = "Name of the ECS service"
}

variable "cluster_arn" {
  type        = string
  description = "ECS cluster ARN"
}

variable "tags" {
  type        = any
  default     = {}
  description = "Tags applied to resources"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR. Task ingress on 8080 is limited to this range."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for tasks"
}

variable "container_image" {
  type        = string
  description = "Container image for the service"
}

variable "service_discovery_namespace_arn" {
  type        = string
  description = "Service Connect namespace ARN"
}

variable "environment_variables" {
  type        = map(string)
  default     = {}
  description = "Environment variables for the app container"
}

variable "additional_task_role_iam_policy_arns" {
  type        = list(string)
  default     = []
  description = "Extra IAM policies for the task role"
}

variable "healthcheck_path" {
  type        = string
  default     = "/health"
  description = "HTTP path used by the container health check"
}

variable "cloudwatch_logs_group_id" {
  type        = string
  description = "CloudWatch Logs group for task logs"
}

variable "alb_target_group_arn" {
  type        = string
  default     = ""
  description = "Target group to register tasks with. Empty means no load balancer."
}

variable "opentelemetry_enabled" {
  type        = bool
  description = "Add the CloudWatch agent sidecar and OTEL environment variables"
}

variable "ci_managed" {
  type        = bool
  default     = false
  description = <<-EOT
    When true, Terraform creates the first task definition but then ignores
    task_definition on the service, so revisions deployed by the CD pipeline
    are not rolled back by a later terraform apply.
  EOT
}

variable "deployment_minimum_healthy_percent" {
  type        = number
  default     = 100
  description = "ECS default is 100: the old task keeps serving until the new one is healthy. 0 stops the old task first."
}

variable "deployment_maximum_percent" {
  type        = number
  default     = 200
  description = "ECS default is 200. With 1 task and a value of 100, the old task must stop before a new one starts."
}
