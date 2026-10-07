# GitHub Actions OIDC role for .github/workflows/deploy-catalog.yml.
# No long-lived AWS keys in the repo. Only runs on var.github_deploy_branch of
# var.github_repository can assume it, and it can only deploy the catalog service.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  # GitHub can send either "repo:<owner>/<repo>" or, when the repository uses the immutable
  # subject claim, "repo:<owner>@<owner-id>/<repo>@<repo-id>". The exact prefix is read from
  #   gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
  # and passed in as var.github_subject_prefix. No wildcards: a wildcard would also match other accounts.
  github_subject_prefix = var.github_subject_prefix != "" ? var.github_subject_prefix : "repo:${var.github_repository}"

  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  catalog_service_arn      = "arn:${data.aws_partition.current.partition}:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.this.name}/${module.catalog.ecs_service_name}"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject_prefix}:ref:refs/heads/${var.github_deploy_branch}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.environment_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "deploy-catalog"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPushCatalog"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = aws_ecr_repository.catalog.arn
      },
      {
        # Register/Describe task definition do not support resource-level permissions.
        Sid      = "TaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
        Resource = "*"
      },
      {
        # The rendered task definition keeps the tags Terraform set, and registering a
        # tagged task definition requires TagResource. Limited to the catalog family.
        Sid      = "TagCatalogTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:TagResource"]
        Resource = "arn:${data.aws_partition.current.partition}:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${module.catalog.task_definition_family}:*"
      },
      {
        Sid      = "DeployCatalogService"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = local.catalog_service_arn
      },
      {
        Sid      = "PassCatalogRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [module.catalog.task_role_arn, module.catalog.task_execution_role_arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      }
    ]
  })
}
