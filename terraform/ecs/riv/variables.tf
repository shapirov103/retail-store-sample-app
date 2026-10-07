variable "region" {
  type        = string
  default     = "us-east-1"
  description = "Region for the workload. The DevOps Agent space lives in us-east-1 regardless."
}

variable "environment_name" {
  type        = string
  default     = "riv-retail"
  description = "Prefix for all resource names"
}

variable "image_tag" {
  type        = string
  default     = "1.6.3"
  description = "Upstream published image tag used for the first deploy of every service"
}

variable "opentelemetry_enabled" {
  type        = bool
  default     = true
  description = "Traces via the CloudWatch agent sidecar. Keep on: the agent needs traces."
}

variable "github_repository" {
  type        = string
  default     = "shapirov103/retail-store-sample-app"
  description = "owner/repo allowed to assume the CD deploy role"
}

variable "github_subject_prefix" {
  type        = string
  default     = ""
  description = <<-EOT
    Exact "repo:..." prefix of the GitHub OIDC token subject. Leave empty to use
    "repo:<github_repository>". Repositories that use GitHub's immutable subject claim need the
    value from: gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
}

variable "github_deploy_branch" {
  type        = string
  default     = "main"
  description = "Only workflow runs on this branch may assume the deploy role"
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = true
  description = "Create the token.actions.githubusercontent.com OIDC provider. Set false if the account already has one."
}

variable "load_generator_enabled" {
  type        = bool
  default     = true
  description = "Run an Artillery task that keeps steady traffic on the store"
}

variable "load_generator_arrival_rate" {
  type        = number
  default     = 2
  description = "New Artillery virtual users per second"
}
