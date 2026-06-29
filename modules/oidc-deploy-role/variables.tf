variable "name" {
  description = "IAM role name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  type        = string
}

variable "github_owner" {
  description = "GitHub owner (user/org) for the OIDC sub condition."
  type        = string
}

variable "repo_name" {
  description = "GitHub repo name for the OIDC sub condition."
  type        = string
}

variable "environment" {
  description = "GitHub environment name this role is scoped to (dev/qa/prod)."
  type        = string
}

variable "branch" {
  description = "Branch this role may also be assumed from (dev/qa/main)."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repo this role may push/pull."
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "ARN of the ECS task execution role this role may pass."
  type        = string
}
