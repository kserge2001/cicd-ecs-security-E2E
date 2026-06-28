# iam.tf — per-environment GitHub Actions OIDC deploy roles + shared ECS exec role

data "aws_caller_identity" "current" {}

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

# ---------- One deploy role per environment ----------
# Each role can be assumed ONLY by:
#   - a job running in that GitHub environment (sub = ...:environment:<env>), or
#   - a workflow on that env's branch       (sub = ...:ref:refs/heads/<branch>).
# So the dev pipeline can never assume the prod role (and vice-versa).
data "aws_iam_policy_document" "deploy_assume" {
  for_each = var.environments
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.repo_name}:environment:${each.key}",
        "repo:${var.github_owner}/${var.repo_name}:ref:refs/heads/${each.value.branch}",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each           = var.environments
  name               = "${var.repo_name}-${each.key}-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume[each.key].json
}

# Per-env permissions: push/pull ONLY this env's ECR repo, roll its ECS service.
data "aws_iam_policy_document" "deploy" {
  for_each = var.environments
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.app[each.key].arn] # scoped to this env's repo only
  }
  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:ListTasks",
    ]
    resources = ["*"] # ECS register/describe are not resource-scopable
  }
  statement {
    sid       = "PassExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_execution.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.environments
  name     = "${var.repo_name}-${each.key}-deploy"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy[each.key].json
}

# ---------- Shared ECS task execution role (pulls images, writes logs) ----------
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
