# Adapted from terraform/lib/ecs/service/ecs.tf. Differences for the re:Invent demo:
#   - optional ci_managed mode (see variables.tf) so the CD pipeline owns task definitions
#   - no secrets block (the trimmed stack has no database credentials)
#   - deployment circuit breaker deliberately NOT configured; enabling it is part of the talk

locals {
  otel_environment = var.opentelemetry_enabled ? {
    OTEL_SDK_DISABLED                      = "false"
    OTEL_EXPORTER_OTLP_PROTOCOL            = "http/protobuf"
    OTEL_RESOURCE_PROVIDERS_AWS_ENABLED    = "true"
    OTEL_METRICS_EXPORTER                  = "none"
    OTEL_JAVA_GLOBAL_AUTOCONFIGURE_ENABLED = "true"
    OTEL_EXPORTER_OTLP_ENDPOINT            = "http://localhost:4318"
    OTEL_PROPAGATORS                       = "tracecontext,baggage"
    OTEL_SERVICE_NAME                      = var.service_name
  } : {}

  environment = [
    for k, v in merge(var.environment_variables, local.otel_environment) : { name = k, value = v }
  ]

  app_container = {
    name  = "${var.service_name}-service"
    image = var.container_image
    portMappings = [
      {
        containerPort = 8080
        hostPort      = 8080
        name          = "${var.service_name}-service"
        protocol      = "tcp"
      }
    ]
    essential              = true
    readonlyRootFilesystem = false
    environment            = local.environment
    cpu                    = 0
    mountPoints            = []
    volumesFrom            = []
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080${var.healthcheck_path} || exit 1"]
      interval    = 10
      startPeriod = 60
      retries     = 3
      timeout     = 5
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.cloudwatch_logs_group_id
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "${var.service_name}-service"
      }
    }
  }

  otel_container = {
    name      = "cloudwatch-agent"
    image     = "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest"
    essential = true
    environment = [
      {
        name = "CW_CONFIG_CONTENT"
        value = jsonencode({
          agent  = {}
          traces = { traces_collected = { otlp = {} } }
        })
      }
    ]
    portMappings = [{ containerPort = 4318, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.cloudwatch_logs_group_id
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "cloudwatch-agent"
      }
    }
  }

  containers = concat([local.app_container], var.opentelemetry_enabled ? [local.otel_container] : [])
}

data "aws_region" "current" {}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.environment_name}-${var.service_name}"
  container_definitions    = jsonencode(local.containers)
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.task_execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn
  tags                     = var.tags
}

# Two copies of the service resource because lifecycle blocks cannot be conditional.
# Exactly one is created, selected by var.ci_managed.

resource "aws_ecs_service" "this" {
  count = var.ci_managed ? 0 : 1

  name                   = var.service_name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true
  wait_for_steady_state  = true

  network_configuration {
    security_groups  = [aws_security_group.this.id]
    subnets          = var.subnet_ids
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.service_discovery_namespace_arn
    service {
      client_alias {
        dns_name = var.service_name
        port     = "80"
      }
      discovery_name = var.service_name
      port_name      = "${var.service_name}-service"
    }
  }

  dynamic "load_balancer" {
    for_each = var.alb_target_group_arn == "" ? [] : [1]
    content {
      target_group_arn = var.alb_target_group_arn
      container_name   = "${var.service_name}-service"
      container_port   = 8080
    }
  }

  tags = var.tags
}

resource "aws_ecs_service" "ci_managed" {
  count = var.ci_managed ? 1 : 0

  name                   = var.service_name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true
  wait_for_steady_state  = true

  network_configuration {
    security_groups  = [aws_security_group.this.id]
    subnets          = var.subnet_ids
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.service_discovery_namespace_arn
    service {
      client_alias {
        dns_name = var.service_name
        port     = "80"
      }
      discovery_name = var.service_name
      port_name      = "${var.service_name}-service"
    }
  }

  dynamic "load_balancer" {
    for_each = var.alb_target_group_arn == "" ? [] : [1]
    content {
      target_group_arn = var.alb_target_group_arn
      container_name   = "${var.service_name}-service"
      container_port   = 8080
    }
  }

  # The CD pipeline registers new revisions and updates the service.
  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = var.tags
}
