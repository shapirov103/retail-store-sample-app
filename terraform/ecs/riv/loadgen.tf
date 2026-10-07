# Steady synthetic traffic so the agent has metrics, logs and traces to correlate.
# Same pattern as the upstream Kubernetes example (src/load-generator/README.md):
# a setup container copies the scenario from the utils image, Artillery runs it.
# Traffic goes through the public ALB, so ALB metrics are populated too.
# Each Artillery run lasts one hour; ECS restarts it when it exits.

locals {
  loadgen_overrides = jsonencode({
    config = { phases = [{ duration = 3600, arrivalRate = var.load_generator_arrival_rate }] }
  })
}

resource "aws_iam_role" "loadgen_execution" {
  count = var.load_generator_enabled ? 1 : 0

  name = "${var.environment_name}-loadgen-te"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "loadgen_execution" {
  count      = var.load_generator_enabled ? 1 : 0
  role       = aws_iam_role.loadgen_execution[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "loadgen" {
  count = var.load_generator_enabled ? 1 : 0

  family                   = "${var.environment_name}-loadgen"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.loadgen_execution[0].arn

  volume {
    name = "scripts"
  }

  container_definitions = jsonencode([
    {
      name        = "setup"
      image       = "public.ecr.aws/aws-containers/retail-store-sample-utils:load-gen.${var.image_tag}"
      essential   = false
      entryPoint  = ["bash", "-c"]
      command     = ["cp /artillery/* /scripts"]
      mountPoints = [{ sourceVolume = "scripts", containerPath = "/scripts" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.tasks.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "loadgen-setup"
        }
      }
    },
    {
      name        = "artillery"
      image       = "artilleryio/artillery:2.0.22"
      essential   = true
      command     = ["run", "-t", "http://${aws_lb.ui.dns_name}", "--overrides", local.loadgen_overrides, "/scripts/scenario.yml"]
      dependsOn   = [{ containerName = "setup", condition = "SUCCESS" }]
      mountPoints = [{ sourceVolume = "scripts", containerPath = "/scripts" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.tasks.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "loadgen"
        }
      }
    }
  ])
}

resource "aws_security_group" "loadgen" {
  count = var.load_generator_enabled ? 1 : 0

  name        = "${var.environment_name}-loadgen"
  description = "Load generator: outbound only"
  vpc_id      = local.vpc_id

  egress {
    description = "Outbound to the ALB and image registries"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "loadgen" {
  count = var.load_generator_enabled ? 1 : 0

  name            = "loadgen"
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.loadgen[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.loadgen[0].id]
    subnets          = local.private_subnets
    assign_public_ip = false
  }

  depends_on = [module.ui]
}
