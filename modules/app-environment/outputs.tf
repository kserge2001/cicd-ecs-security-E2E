output "ecr_repository_url" {
  description = "ECR repository URL for this env."
  value       = module.ecr.repository_url
}

output "deploy_role_arn" {
  description = "OIDC deploy role ARN for this env."
  value       = module.deploy_role.role_arn
}

output "cluster_name" {
  value = module.ecs.cluster_name
}

output "service_name" {
  value = module.ecs.service_name
}

output "url" {
  description = "Public URL for this env."
  value       = "https://${var.subdomain}.${var.domain}"
}
