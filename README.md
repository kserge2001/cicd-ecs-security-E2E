# cicd-ecs-security-E2E

End-to-end **CI/CD + DevSecOps** lab provisioned by Terraform. A single `terraform apply`
stands up a GitHub repository **and** the AWS infrastructure to deploy a containerized
app to **ECS Fargate** across `dev` / `qa` / `prod`, behind HTTPS load balancers, driven
by **GitHub Actions using OIDC** (no long-lived AWS keys) with security scanning and
human approval gates.

## What it builds

**AWS**
- One VPC (public subnets across 2 AZs, IGW) — Fargate with public IPs, no NAT.
- Per environment: ALB (HTTP→HTTPS redirect, HTTPS listener w/ ACM wildcard cert),
  target group, ECS cluster + Fargate service + task definition, CloudWatch logs,
  Route 53 alias `<env>.<domain>`.
- **3 ECR repos** (one per env) for access separation.
- **3 OIDC deploy roles**, each scoped to its own environment/branch and its own ECR
  repo (least privilege — the dev pipeline cannot touch prod), plus a shared ECS
  task execution role.

**GitHub**
- Public repo seeded with the app + pipeline; `dev`/`qa` branches (`main` = production).
- Branch protection (`main` is PR-only via `enforce_admins`; required `build-and-scan` check).
- Environments with approval gates: `dev` auto-deploys; `qa`/`prod` require approval;
  `prod` adds a wait-timer soak window.
- Per-env + repo-level Actions variables/secrets wired for the pipeline.

**Pipeline** ([repo-seed/.github/workflows/ci-cd.yml](repo-seed/.github/workflows/ci-cd.yml))
- PRs: build + scan only (no AWS access).
- Push to `dev`/`qa`/`main`: build → SonarQube (SAST) + Snyk (container/SCA) →
  push to the env's ECR → deploy to ECS (gated by the environment's approval).
- **Prod releases** auto-bump a semver git tag (`vX.Y.Z`) and tag the image with it;
  `dev`/`qa` images are tagged by commit SHA.

## Documentation

Deep-dive guides live in [`docs/`](docs/):
- [CI/CD & GitHub Actions](docs/01-cicd-and-github-actions.md) — pipeline design, what to include, pitfalls, security hardening.
- [Self-hosted Kubernetes](docs/02-self-hosted-kubernetes.md) — build your own cluster with `kubeadm` (and k3s).
- [Deploy to EKS instead of ECS](docs/03-deploy-to-eks.md) — take this app to Kubernetes on AWS.

## Layout

| Path | Purpose |
|---|---|
| `*.tf` | Root config: VPC, ECR, IAM/OIDC, GitHub repo + pipeline wiring |
| `modules/ecs-env/` | Reusable per-environment ECS/ALB/DNS stack |
| `repo-seed/` | App + pipeline files seeded into the created repo |
| `terraform.auto.tfvars.example` | Copy to `terraform.auto.tfvars` and fill in |

## Usage

```bash
cp terraform.auto.tfvars.example terraform.auto.tfvars   # then edit values
export TF_VAR_github_token=ghp_xxx   # scopes: repo, workflow, read:org, delete_repo
terraform init
terraform plan
terraform apply
```

Tear down with `terraform destroy`.

> ⚠️ `terraform.auto.tfvars` and `*.tfstate` contain secrets and are gitignored — never commit them.
