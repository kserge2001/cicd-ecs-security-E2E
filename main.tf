# main.tf — root: one ecs-env stack per environment (dev/qa/prod)

module "env" {
  source   = "./modules/ecs-env"
  for_each = var.environments

  name        = "${var.repo_name}-${each.key}"
  aws_region  = var.aws_region
  vpc_id      = aws_vpc.this.id
  subnet_ids  = aws_subnet.public[*].id
  record_fqdn = "${each.value.subdomain}.${var.domain}"

  acm_certificate_arn = var.acm_certificate_arn
  hosted_zone_id      = var.hosted_zone_id

  container_name     = var.container_name
  container_image    = var.container_image
  container_port     = var.container_port
  cpu                = var.cpu
  memory             = var.memory
  desired_count      = var.desired_count
  execution_role_arn = aws_iam_role.ecs_execution.arn
}
