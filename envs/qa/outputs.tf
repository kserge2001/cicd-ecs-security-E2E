output "url" {
  value = module.app.url
}

output "ecr_repository_url" {
  value = module.app.ecr_repository_url
}

output "deploy_role_arn" {
  value = module.app.deploy_role_arn
}
