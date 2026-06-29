# Providers
variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type    = string
  default = null
}

variable "github_owner" {
  type = string
}

variable "github_token" {
  type      = string
  sensitive = true
}

# Repository
variable "repo_name" {
  type = string
}

variable "repo_description" {
  type    = string
  default = "CI/CD ECS Fargate pipeline"
}

variable "repo_visibility" {
  type    = string
  default = "public"
}

# Networking
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

# Shared container defaults (envs can still override sizing)
variable "container_name" {
  type    = string
  default = "app"
}

variable "container_image" {
  type    = string
  default = "public.ecr.aws/nginx/nginx:latest"
}

variable "container_port" {
  type    = number
  default = 80
}

# DNS + TLS (shared)
variable "domain" {
  type = string
}

variable "hosted_zone_id" {
  type = string
}

variable "acm_certificate_arn" {
  type = string
}

# Environments (branch + protection only; per-env infra lives in envs/*)
variable "environments" {
  description = "Map of env name => { branch, protect_branch }."
  type = map(object({
    branch         = string
    protect_branch = bool
  }))
}

# Review gates / scanners / OIDC
variable "required_pr_approvals" {
  type    = number
  default = 1
}

variable "repo_secrets" {
  type    = map(string)
  default = {}
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}
