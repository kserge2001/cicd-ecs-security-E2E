# cicd-ecs-security-E2E

End-to-end **CI/CD + DevSecOps** lab provisioned by Terraform. A single `terraform apply`
stands up a GitHub repository **and** the AWS infrastructure to deploy a containerized
app to **ECS Fargate** across `dev` / `qa` / `prod`, behind HTTPS load balancers, driven
by **GitHub Actions using OIDC** (no long-lived AWS keys) with security scanning and
human approval gates.

## What it builds

**AWS**
- One VPC (public subnets across 2 AZs, IGW) - Fargate with public IPs, no NAT.
- Per environment: ALB (HTTP→HTTPS redirect, HTTPS listener w/ ACM wildcard cert),
  target group, ECS cluster + Fargate service + task definition, CloudWatch logs,
  Route 53 alias `<env>.<domain>`.
- **3 ECR repos** (one per env) for access separation.
- **3 OIDC deploy roles**, each scoped to its own environment/branch and its own ECR
  repo (least privilege - the dev pipeline cannot touch prod), plus a shared ECS
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

Deep-dive guides live in [`docs/`](docs/) (see the [docs index](docs/README.md)):
- [CI/CD & GitHub Actions](docs/01-cicd-and-github-actions.md): pipeline design, what to include, pitfalls, security hardening.
- [Deploy to EKS (GitOps with Argo CD)](docs/02-deploy-to-eks.md): run this app on an existing EKS cluster the enterprise way, pull-based with Argo CD.
- [Pipelines by language](docs/03-pipelines-by-language.md): how the pipeline changes for Java, Python, Ruby, .NET, Node, Go.
- [Testing strategy](docs/04-testing-strategy.md): smoke tests, post-sign-off tests, browser/DAST/load frameworks.
- [Continuous delivery vs deployment](docs/05-continuous-deployment.md): what full CD looks and feels like, progressive delivery.
- [Runners: hosted, self-hosted, Kubernetes](docs/06-runners-and-scaling.md): runner types, self-hosted + ARC setup, scaling.
- [Secrets and architecture](docs/07-secrets-and-architecture.md): sensitive data, plus security/scalability/governance concerns.

## Layout

The Terraform is organized as real-world multi-stack code: shared singletons in one
stack, and one independent stack (its own state) per environment.

```
modules/
  network/           reusable VPC (public subnets, IGW)
  github-repo/        reusable "repo" module: repository + pipeline seed + branches + protection
  ecr/                a single container image repository
  ecs-env/            ECS service + ALB + target group + DNS for one env
  oidc-deploy-role/   a per-env GitHub OIDC deploy role (least privilege)
  app-environment/    composes ecr + ecs-env + oidc-deploy-role + the GitHub environment
shared/               VPC, GitHub repo, OIDC provider, ECS exec role  (apply FIRST)
envs/
  dev/   qa/   prod/  one stack each: reads shared via remote state, calls app-environment
```

State lives in S3 with **native S3 locking** (`use_lockfile`, no DynamoDB), one key per
stack. The reusable modules (`github-repo`, `ecr`, `ecs-env`, ...) can be used on their own.

## Usage

Apply the shared stack first, then each environment. Each stack has its own
`terraform.tfvars.example`, copy it to `terraform.tfvars` and fill in.

```bash
export TF_VAR_github_token=ghp_xxx   # scopes: repo, workflow, read:org, delete_repo

# 1) shared singletons (VPC, repo, OIDC provider, exec role)
cd shared && cp terraform.tfvars.example terraform.tfvars   # edit, set your S3 bucket in backend.tf
terraform init && terraform apply

# 2) each environment (independent state)
cd ../envs/dev  && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply
cd ../envs/qa   && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply
cd ../envs/prod && cp terraform.tfvars.example terraform.tfvars && terraform init && terraform apply
```

Tear down in reverse: `envs/*` first, then `shared`.

> ⚠️ Real `*.tfvars` and `*.tfstate` contain secrets and are gitignored. Only the
> `*.tfvars.example` templates are committed. Set your S3 state bucket in each
> stack's `backend.tf`.
