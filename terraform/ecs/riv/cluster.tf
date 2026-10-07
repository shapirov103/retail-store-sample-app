resource "aws_ecs_cluster" "this" {
  name = "${var.environment_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

resource "aws_cloudwatch_log_group" "tasks" {
  name              = "${var.environment_name}-tasks"
  retention_in_days = 30
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "retailstore.local"
  description = "Service Connect namespace"
  vpc         = local.vpc_id
}

# ECS service events (deployment state, task stopped reasons) into CloudWatch Logs,
# so they are queryable alongside app logs.
resource "aws_cloudwatch_log_group" "ecs_events" {
  name              = "/aws/events/ecs/${var.environment_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_event_rule" "ecs_events" {
  name        = "${var.environment_name}-ecs-events"
  description = "ECS events for ${aws_ecs_cluster.this.name}"

  event_pattern = jsonencode({
    source = ["aws.ecs"]
    detail = { clusterArn = [aws_ecs_cluster.this.arn] }
  })
}

resource "aws_cloudwatch_event_target" "ecs_events" {
  rule = aws_cloudwatch_event_rule.ecs_events.name
  arn  = aws_cloudwatch_log_group.ecs_events.arn
}

data "aws_iam_policy_document" "events_to_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ecs_events.arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "events_to_logs" {
  policy_name     = "${var.environment_name}-ecs-events"
  policy_document = data.aws_iam_policy_document.events_to_logs.json
}
