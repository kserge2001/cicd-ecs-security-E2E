# Providers (kept local so the provider blocks do not depend on remote state)
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

# Where the shared stack's state lives (same bucket as this stack's backend)
variable "tfstate_bucket" {
  type = string
}

# Env identity
variable "environment" {
  type = string
}

variable "branch" {
  type = string
}

variable "subdomain" {
  type = string
}

# Gate
variable "required_reviewers" {
  type    = list(string)
  default = []
}

variable "wait_timer" {
  type    = number
  default = 0
}

variable "prevent_self_review" {
  type    = bool
  default = true
}

variable "environment_secrets" {
  type    = map(string)
  default = {}
}

# Sizing
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
  type    = bool
  default = false
}
