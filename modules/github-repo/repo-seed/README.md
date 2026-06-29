# Pipeline Lab

This repository is seeded by Terraform. Pushing to `dev`, `qa`, or `prod`
builds a container image, pushes it to Amazon ECR, and deploys it to the
matching ECS Fargate environment.

- `dev` deploys automatically.
- `qa` and `prod` require a reviewer approval (GitHub Environments gate).

The pipeline lives in [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml).
