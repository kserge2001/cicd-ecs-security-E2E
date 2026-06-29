# Consumed by the envs/* stacks via terraform_remote_state.

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "repo_name" {
  value = module.github_repo.repo_name
}

output "repo_html_url" {
  value = module.github_repo.repo_html_url
}

output "github_oidc_provider_arn" {
  value = local.github_oidc_arn
}

output "ecs_execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}

# Echoed shared config so env stacks do not redeclare it.
output "aws_region" {
  value = var.aws_region
}

output "github_owner" {
  value = var.github_owner
}

output "domain" {
  value = var.domain
}

output "hosted_zone_id" {
  value = var.hosted_zone_id
}

output "acm_certificate_arn" {
  value = var.acm_certificate_arn
}

output "container_name" {
  value = var.container_name
}

output "container_image" {
  value = var.container_image
}

output "container_port" {
  value = var.container_port
}
