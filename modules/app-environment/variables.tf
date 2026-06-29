# Identity
variable "environment" {
  description = "Environment name (dev/qa/prod). Also the GitHub environment name."
  type        = string
}

variable "branch" {
  description = "Branch that deploys this env (dev/qa/main)."
  type        = string
}

variable "subdomain" {
  description = "Subdomain for this env. The record is <subdomain>.<domain>."
  type        = string
}

# From the shared stack
variable "repo_name" {
  description = "GitHub repository name (created in the shared stack)."
  type        = string
}

variable "github_owner" {
  description = "GitHub owner (user/org)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN (from the shared stack)."
  type        = string
}

variable "ecs_execution_role_arn" {
  description = "Shared ECS task execution role ARN (from the shared stack)."
  type        = string
}

variable "vpc_id" {
  description = "Shared VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Shared public subnet IDs."
  type        = list(string)
}

variable "aws_region" {
  description = "AWS region (for awslogs config)."
  type        = string
}

variable "domain" {
  description = "Apex domain."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener."
  type        = string
}

# Gate config
variable "required_reviewers" {
  description = "GitHub usernames that must approve deploys to this env. Empty = auto-deploy."
  type        = list(string)
  default     = []
}

variable "wait_timer" {
  description = "Minutes to wait after approval before deploying."
  type        = number
  default     = 0
}

variable "prevent_self_review" {
  description = "If true, the deploy triggerer cannot approve their own deploy. Set false for solo repos."
  type        = bool
  default     = true
}

variable "environment_secrets" {
  description = "Env-scoped GitHub secrets (resolve only after approval)."
  type        = map(string)
  default     = {}
}

# Container / sizing
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

variable "cpu" {
  type    = string
  default = "256"
}

variable "memory" {
  type    = string
  default = "512"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "ecr_force_delete" {
  description = "Allow ECR destroy with images present (lab convenience)."
  type        = bool
  default     = false
}
