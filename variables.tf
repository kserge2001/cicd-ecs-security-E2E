# variables.tf — root inputs

# ---------- AWS / GitHub providers ----------
variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "aws_profile" {
  description = "Local AWS CLI profile to authenticate with. Set null to use the default chain."
  type        = string
  default     = null
}

variable "github_owner" {
  description = "GitHub user or org that owns the repo."
  type        = string
}

variable "github_token" {
  description = "GitHub PAT. Provide via TF_VAR_github_token, not in tfvars."
  type        = string
  sensitive   = true
}

# ---------- Repository ----------
variable "repo_name" {
  description = "Name of the GitHub repo to create. Also used as a name prefix for AWS resources."
  type        = string
}

variable "repo_description" {
  description = "GitHub repo description."
  type        = string
  default     = "CI/CD ECS Fargate pipeline lab"
}

# ---------- DNS + TLS ----------
variable "domain" {
  description = "Apex domain; per-env records are <subdomain>.<domain>."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for the domain."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM cert ARN (must be in aws_region and cover *.domain)."
  type        = string
}

# ---------- Networking (a fresh VPC is created from this) ----------
variable "vpc_cidr" {
  description = "CIDR block for the new VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of AZs / public subnets to spread across."
  type        = number
  default     = 2
}

# ---------- Container / task sizing (shared across environments) ----------
variable "container_name" {
  description = "Container name in the task definition (the pipeline references this)."
  type        = string
  default     = "app"
}

variable "container_image" {
  description = "Initial image used until the pipeline pushes a real one."
  type        = string
  default     = "public.ecr.aws/nginx/nginx:latest"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 80
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Initial desired task count per environment."
  type        = number
  default     = 1
}

# ---------- Environments ----------
variable "environments" {
  description = "Map of environment name => settings. Each becomes a branch, a GitHub environment, and an ECS stack."
  type = map(object({
    branch             = string
    subdomain          = string
    required_reviewers = list(string)
    protect_branch     = bool
    wait_timer         = optional(number, 0)
  }))
}

# ---------- Secrets / variables wired into GitHub ----------
variable "environment_secrets" {
  description = "Map of environment name => { SECRET_NAME = value } set as per-env GitHub secrets."
  type        = map(map(string))
  default     = {}
}

variable "repo_secrets" {
  description = "Repo-level GitHub secrets (e.g. SONAR_TOKEN, SNYK_TOKEN). Keys are used as for_each instance keys, so this map cannot be marked sensitive."
  type        = map(string)
  default     = {}
}

# ---------- Review gates ----------
# In a solo repo you can't approve your own PR or your own deployment, so the
# defaults (1 approval, no self-review) would deadlock. Set approvals to 0 and
# self-review to false for a single-person lab; keep the defaults for a real team.
variable "required_pr_approvals" {
  description = "PR approvals required by branch protection. 0 = no human approval needed (CI status checks still required)."
  type        = number
  default     = 1
}

variable "prevent_self_review" {
  description = "If true, the user who triggers a deployment cannot approve it. Set false for a solo repo."
  type        = bool
  default     = true
}

# ---------- OIDC ----------
variable "create_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false if it already exists in the account."
  type        = bool
  default     = true
}
