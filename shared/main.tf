# shared/ - resources shared across all environments:
#   the VPC, the GitHub repository (skeleton + pipeline), the GitHub OIDC
#   provider, and the shared ECS task execution role.
# Apply this stack FIRST. The envs/* stacks read its outputs via remote state.

module "network" {
  source   = "../modules/network"
  name     = var.repo_name
  vpc_cidr = var.vpc_cidr
  az_count = var.az_count
}

module "github_repo" {
  source = "../modules/github-repo"

  repo_name             = var.repo_name
  repo_description       = var.repo_description
  visibility            = var.repo_visibility
  aws_region            = var.aws_region
  container_name        = var.container_name
  repo_secrets          = var.repo_secrets
  required_pr_approvals  = var.required_pr_approvals
  required_status_check = "build-and-scan"

  environments = { for k, v in var.environments : k => {
    branch         = v.branch
    protect_branch = v.protect_branch
  } }
}

# ---------- GitHub Actions OIDC provider ----------
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# ---------- Shared ECS task execution role ----------
data "aws_iam_policy_document" "ecs_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.repo_name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_execution_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
