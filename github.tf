# github.tf

# ---------- Repository (public => env protection rules are free) ----------
resource "github_repository" "this" {
  name                   = var.repo_name
  description            = var.repo_description
  visibility             = "public"
  auto_init              = true
  delete_branch_on_merge = true
  vulnerability_alerts   = true
}

# ---------- Seed the repo with the app + pipeline on main ----------
locals {
  seed_files = {
    ".github/workflows/ci-cd.yml" = "${path.module}/repo-seed/.github/workflows/ci-cd.yml"
    "Dockerfile"                  = "${path.module}/repo-seed/Dockerfile"
    "app/index.html"              = "${path.module}/repo-seed/app/index.html"
    "sonar-project.properties"    = "${path.module}/repo-seed/sonar-project.properties"
    "README.md"                   = "${path.module}/repo-seed/README.md"
  }
}

resource "github_repository_file" "seed" {
  for_each            = local.seed_files
  repository          = github_repository.this.name
  branch              = "main"
  file                = each.key
  content             = file(each.value)
  commit_message      = "Seed: ${each.key}"
  overwrite_on_create = true

  # Bootstrap-only: seed the file once. After that, main is PR-protected, so
  # Terraform must NOT try to push content updates (it would be rejected) -
  # all further changes to these files go through pull requests.
  lifecycle {
    ignore_changes = [content]
  }
}

# ---------- Branches: dev/qa/prod cut from main AFTER files exist ----------
resource "github_branch" "env" {
  # Skip any env that maps to "main" - main already exists (auto_init).
  for_each      = { for k, v in var.environments : k => v if v.branch != "main" }
  repository    = github_repository.this.name
  branch        = each.value.branch
  source_branch = "main"
  depends_on    = [github_repository_file.seed]
}

# ---------- Branch protection: main + any env with protect_branch = true ----------
# (i.e. everything except dev)
resource "github_branch_protection" "main" {
  repository_id = github_repository.this.node_id
  pattern       = "main"
  enforce_admins = true # no direct pushes to main - even admins must use a PR
  required_pull_request_reviews { required_approving_review_count = var.required_pr_approvals }
  required_status_checks {
    strict   = true
    contexts = ["build-and-scan"]
  }
  depends_on = [github_repository_file.seed]
}

resource "github_branch_protection" "env" {
  # Exclude any env mapping to "main" - it's already covered by the "main" rule above.
  for_each      = { for k, v in var.environments : k => v if v.protect_branch && v.branch != "main" }
  repository_id = github_repository.this.node_id
  pattern       = each.value.branch
  required_pull_request_reviews { required_approving_review_count = var.required_pr_approvals }
  required_status_checks {
    strict   = true
    contexts = ["build-and-scan"]
  }
  depends_on = [github_branch.env]
}

# ---------- Resolve reviewer usernames -> numeric user IDs ----------
locals {
  all_reviewers = toset(flatten([for e in var.environments : e.required_reviewers]))
}

data "github_user" "reviewers" {
  for_each = local.all_reviewers
  username = each.value
}

# ---------- Environments + approval gates ----------
resource "github_repository_environment" "this" {
  for_each    = var.environments
  repository  = github_repository.this.name
  environment = each.key

  wait_timer          = each.value.wait_timer
  prevent_self_review = var.prevent_self_review && length(each.value.required_reviewers) > 0

  dynamic "reviewers" {
    for_each = length(each.value.required_reviewers) > 0 ? [1] : []
    content {
      users = [for u in each.value.required_reviewers : data.github_user.reviewers[u].id]
    }
  }
  # No deployment_branch_policy => deployable from any branch ("deploy anywhere").
}

# ---------- Repo-level variables (read as ${{ vars.X }}) ----------
resource "github_actions_variable" "aws_region" {
  repository    = github_repository.this.name
  variable_name = "AWS_REGION"
  value         = var.aws_region
}
resource "github_actions_variable" "container_name" {
  repository    = github_repository.this.name
  variable_name = "CONTAINER_NAME"
  value         = var.container_name
}

# Repo-level per-env ECR repo + deploy-role ARN, named ECR_<ENV> / ROLE_ARN_<ENV>.
# The build-and-scan job has no GitHub environment, so it reads these (keyed by
# branch) to pick which registry to push to and which role to assume.
resource "github_actions_variable" "ecr_per_env" {
  for_each      = var.environments
  repository    = github_repository.this.name
  variable_name = "ECR_${upper(each.key)}"
  value         = aws_ecr_repository.app[each.key].name
}
resource "github_actions_variable" "role_arn_per_env" {
  for_each      = var.environments
  repository    = github_repository.this.name
  variable_name = "ROLE_ARN_${upper(each.key)}"
  value         = aws_iam_role.deploy[each.key].arn
}

# ---------- Per-environment variables: which cluster/service/task to hit ----------
resource "github_actions_environment_variable" "cluster" {
  for_each      = var.environments
  repository    = github_repository.this.name
  environment   = github_repository_environment.this[each.key].environment
  variable_name = "ECS_CLUSTER"
  value         = module.env[each.key].cluster_name
}
resource "github_actions_environment_variable" "service" {
  for_each      = var.environments
  repository    = github_repository.this.name
  environment   = github_repository_environment.this[each.key].environment
  variable_name = "ECS_SERVICE"
  value         = module.env[each.key].service_name
}
resource "github_actions_environment_variable" "task_family" {
  for_each      = var.environments
  repository    = github_repository.this.name
  environment   = github_repository_environment.this[each.key].environment
  variable_name = "ECS_TASK_FAMILY"
  value         = module.env[each.key].task_family
}
# Env-scoped role ARN for the (environment-bound) deploy job.
resource "github_actions_environment_variable" "role_arn" {
  for_each      = var.environments
  repository    = github_repository.this.name
  environment   = github_repository_environment.this[each.key].environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.deploy[each.key].arn
}

# ---------- Repo-level secrets ----------
# Optional scanner secrets (SONAR_TOKEN, SONAR_HOST_URL, SNYK_TOKEN...).
resource "github_actions_secret" "repo" {
  for_each        = var.repo_secrets
  repository      = github_repository.this.name
  secret_name     = each.key
  plaintext_value = each.value
}

# ---------- Per-environment secrets (resolve only after approval) ----------
resource "github_actions_environment_secret" "env" {
  for_each = merge([
    for env_name, kv in var.environment_secrets : {
      for sk, sv in kv : "${env_name}:${sk}" => {
        environment = env_name
        name        = sk
        value       = sv
      }
    }
  ]...)

  repository      = github_repository.this.name
  environment     = github_repository_environment.this[each.value.environment].environment
  secret_name     = each.value.name
  plaintext_value = each.value.value
}
