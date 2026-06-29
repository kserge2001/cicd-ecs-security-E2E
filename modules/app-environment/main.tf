# modules/app-environment - one complete environment (dev | qa | prod):
#   ECR repo  +  ECS/ALB/DNS stack  +  OIDC deploy role  +  the GitHub
#   environment with its gate and the Actions variables/secrets the pipeline reads.
# Composed from the leaf modules so each env stack is a single module call.

locals {
  name     = "${var.repo_name}-${var.environment}"
  env_upper = upper(var.environment)
}

# ---------- Container registry for this env ----------
module "ecr" {
  source       = "../ecr"
  name         = local.name
  force_delete = var.ecr_force_delete
}

# ---------- ECS / ALB / DNS stack for this env ----------
module "ecs" {
  source = "../ecs-env"

  name        = local.name
  aws_region  = var.aws_region
  vpc_id      = var.vpc_id
  subnet_ids  = var.subnet_ids
  record_fqdn = "${var.subdomain}.${var.domain}"

  acm_certificate_arn = var.acm_certificate_arn
  hosted_zone_id      = var.hosted_zone_id

  container_name     = var.container_name
  container_image    = var.container_image
  container_port     = var.container_port
  cpu                = var.cpu
  memory             = var.memory
  desired_count      = var.desired_count
  execution_role_arn = var.ecs_execution_role_arn
}

# ---------- OIDC deploy role for this env ----------
module "deploy_role" {
  source = "../oidc-deploy-role"

  name                   = "${local.name}-deploy"
  oidc_provider_arn      = var.oidc_provider_arn
  github_owner           = var.github_owner
  repo_name              = var.repo_name
  environment            = var.environment
  branch                 = var.branch
  ecr_repository_arn     = module.ecr.repository_arn
  ecs_execution_role_arn = var.ecs_execution_role_arn
}

# ---------- The GitHub environment + approval gate ----------
data "github_user" "reviewers" {
  for_each = toset(var.required_reviewers)
  username = each.value
}

resource "github_repository_environment" "this" {
  repository  = var.repo_name
  environment = var.environment

  wait_timer          = var.wait_timer
  prevent_self_review = var.prevent_self_review && length(var.required_reviewers) > 0

  dynamic "reviewers" {
    for_each = length(var.required_reviewers) > 0 ? [1] : []
    content {
      users = [for u in var.required_reviewers : data.github_user.reviewers[u].id]
    }
  }
}

# ---------- Repo-level per-env variables (the no-environment build job reads these) ----------
resource "github_actions_variable" "ecr" {
  repository    = var.repo_name
  variable_name = "ECR_${local.env_upper}"
  value         = module.ecr.repository_name
}

resource "github_actions_variable" "role_arn" {
  repository    = var.repo_name
  variable_name = "ROLE_ARN_${local.env_upper}"
  value         = module.deploy_role.role_arn
}

# ---------- Env-scoped variables (the deploy job reads these) ----------
resource "github_actions_environment_variable" "cluster" {
  repository    = var.repo_name
  environment   = github_repository_environment.this.environment
  variable_name = "ECS_CLUSTER"
  value         = module.ecs.cluster_name
}

resource "github_actions_environment_variable" "service" {
  repository    = var.repo_name
  environment   = github_repository_environment.this.environment
  variable_name = "ECS_SERVICE"
  value         = module.ecs.service_name
}

resource "github_actions_environment_variable" "task_family" {
  repository    = var.repo_name
  environment   = github_repository_environment.this.environment
  variable_name = "ECS_TASK_FAMILY"
  value         = module.ecs.task_family
}

resource "github_actions_environment_variable" "role_arn" {
  repository    = var.repo_name
  environment   = github_repository_environment.this.environment
  variable_name = "AWS_ROLE_ARN"
  value         = module.deploy_role.role_arn
}

# ---------- Env-scoped secrets (resolve only after approval) ----------
resource "github_actions_environment_secret" "this" {
  for_each        = var.environment_secrets
  repository      = var.repo_name
  environment     = github_repository_environment.this.environment
  secret_name     = each.key
  plaintext_value = each.value
}
