variable "repo_name" {
  description = "GitHub repository name."
  type        = string
}

variable "repo_description" {
  description = "GitHub repository description."
  type        = string
  default     = "CI/CD ECS Fargate pipeline"
}

variable "visibility" {
  description = "public or private. public gives free Environment protection rules."
  type        = string
  default     = "public"
}

variable "environments" {
  description = "Map of env name => { branch, protect_branch }. Used to cut branches and apply protection."
  type = map(object({
    branch         = string
    protect_branch = bool
  }))
}

variable "aws_region" {
  description = "Value for the repo-level AWS_REGION Actions variable."
  type        = string
}

variable "container_name" {
  description = "Value for the repo-level CONTAINER_NAME Actions variable."
  type        = string
}

variable "repo_secrets" {
  description = "Repo-level GitHub secrets (e.g. SONAR_TOKEN, SNYK_TOKEN)."
  type        = map(string)
  default     = {}
}

variable "required_pr_approvals" {
  description = "Approvals required by branch protection. 0 keeps CI checks required but needs no human approval (solo repos)."
  type        = number
  default     = 1
}

variable "required_status_check" {
  description = "Status check context required before merge."
  type        = string
  default     = "build-and-scan"
}
