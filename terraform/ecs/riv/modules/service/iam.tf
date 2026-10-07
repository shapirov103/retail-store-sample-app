data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.cloudwatch_logs_group_id}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution_role" {
  name               = "${var.environment_name}-${var.service_name}-te"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_role_policy" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_role" {
  name               = "${var.environment_name}-${var.service_name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "task" {
  name = "logs-traces-exec"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:DescribeLogStreams"]
          Resource = ["${local.log_group_arn}:*"]
        },
        {
          # ECS Exec
          Effect = "Allow"
          Action = [
            "ssmmessages:CreateControlChannel",
            "ssmmessages:CreateDataChannel",
            "ssmmessages:OpenControlChannel",
            "ssmmessages:OpenDataChannel"
          ]
          Resource = "*"
        }
      ],
      var.opentelemetry_enabled ? [
        {
          Effect   = "Allow"
          Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
          Resource = "*"
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "task_role_additional" {
  count      = length(var.additional_task_role_iam_policy_arns)
  role       = aws_iam_role.task_role.name
  policy_arn = var.additional_task_role_iam_policy_arns[count.index]
}
