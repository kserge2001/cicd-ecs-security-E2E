# outputs.tf

output "repo_url" {
  description = "The created GitHub repository."
  value       = github_repository.this.html_url
}

output "ecr_repository_urls" {
  description = "Per-environment ECR repositories the pipeline pushes images to."
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "github_actions_role_arns" {
  description = "Per-environment OIDC deploy roles the pipeline assumes."
  value       = { for k, r in aws_iam_role.deploy : k => r.arn }
}

output "environment_urls" {
  description = "Public URL per environment."
  value       = { for k, m in module.env : k => "https://${m.record_fqdn}" }
}

output "alb_dns_names" {
  description = "ALB DNS name per environment."
  value       = { for k, m in module.env : k => m.alb_dns_name }
}
