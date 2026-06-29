# ecr.tf - one image registry per environment (separate access boundaries)

resource "aws_ecr_repository" "app" {
  for_each             = var.environments
  name                 = "${var.repo_name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lab: allow destroy even with images present

  image_scanning_configuration {
    scan_on_push = true
  }
}
