# modules/github-repo - the reusable "repo" module.
# Creates the GitHub repository, seeds the app + pipeline, cuts env branches,
# applies branch protection, and sets the repo-level base Actions variables and
# scanner secrets. Per-environment GitHub config lives in modules/app-environment.

resource "github_repository" "this" {
  name                   = var.repo_name
  description            = var.repo_description
  visibility             = var.visibility
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

  # Bootstrap-only: main is PR-protected, so Terraform must not push content
  # updates afterwards. All further changes go through pull requests.
  lifecycle {
    ignore_changes = [content]
  }
}

# ---------- Env branches (everything whose branch != main), cut from main ----------
resource "github_branch" "env" {
  for_each      = { for k, v in var.environments : k => v if v.branch != "main" }
  repository    = github_repository.this.name
  branch        = each.value.branch
  source_branch = "main"
  depends_on    = [github_repository_file.seed]
}

# ---------- Branch protection: main (PR-only) + protected env branches ----------
resource "github_branch_protection" "main" {
  repository_id                   = github_repository.this.node_id
  pattern                         = "main"
  enforce_admins                  = true # no direct pushes to main, even admins
  required_pull_request_reviews { required_approving_review_count = var.required_pr_approvals }
  required_status_checks {
    strict   = true
    contexts = [var.required_status_check]
  }
  depends_on = [github_repository_file.seed]
}

resource "github_branch_protection" "env" {
  for_each = { for k, v in var.environments : k => v if v.protect_branch && v.branch != "main" }
  repository_id                   = github_repository.this.node_id
  pattern                         = each.value.branch
  required_pull_request_reviews { required_approving_review_count = var.required_pr_approvals }
  required_status_checks {
    strict   = true
    contexts = [var.required_status_check]
  }
  depends_on = [github_branch.env]
}

# ---------- Repo-level base variables (read as ${{ vars.X }}) ----------
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

# ---------- Optional scanner secrets (SONAR_TOKEN, SNYK_TOKEN, ...) ----------
resource "github_actions_secret" "repo" {
  for_each        = var.repo_secrets
  repository      = github_repository.this.name
  secret_name     = each.key
  plaintext_value = each.value
}
