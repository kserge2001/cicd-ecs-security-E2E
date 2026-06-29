# envs/<env> - one environment's stack. Reads the shared stack via remote state
# and instantiates the app-environment module for this env.

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = "cicd-ecs/shared/terraform.tfstate"
    region = var.aws_region
  }
}

module "app" {
  source = "../../modules/app-environment"

  environment = var.environment
  branch      = var.branch
  subdomain   = var.subdomain

  # From the shared stack
  repo_name              = data.terraform_remote_state.shared.outputs.repo_name
  github_owner           = data.terraform_remote_state.shared.outputs.github_owner
  oidc_provider_arn      = data.terraform_remote_state.shared.outputs.github_oidc_provider_arn
  ecs_execution_role_arn = data.terraform_remote_state.shared.outputs.ecs_execution_role_arn
  vpc_id                 = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids             = data.terraform_remote_state.shared.outputs.public_subnet_ids
  aws_region             = data.terraform_remote_state.shared.outputs.aws_region
  domain                 = data.terraform_remote_state.shared.outputs.domain
  hosted_zone_id         = data.terraform_remote_state.shared.outputs.hosted_zone_id
  acm_certificate_arn    = data.terraform_remote_state.shared.outputs.acm_certificate_arn
  container_name         = data.terraform_remote_state.shared.outputs.container_name
  container_image        = data.terraform_remote_state.shared.outputs.container_image
  container_port         = data.terraform_remote_state.shared.outputs.container_port

  # Per-env gate + sizing
  required_reviewers  = var.required_reviewers
  wait_timer          = var.wait_timer
  prevent_self_review = var.prevent_self_review
  environment_secrets = var.environment_secrets
  cpu                 = var.cpu
  memory              = var.memory
  desired_count       = var.desired_count
  ecr_force_delete    = var.ecr_force_delete
}
