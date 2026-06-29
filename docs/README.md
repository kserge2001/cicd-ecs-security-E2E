# Documentation

In-depth guides that go beyond this repo's ECS lab: how to design pipelines, test them,
ship safely, scale runners, and take the app to an existing EKS cluster.

| # | Guide | What it covers |
|---|-------|----------------|
| 01 | [CI/CD & GitHub Actions](01-cicd-and-github-actions.md) | CI vs CD, full GitHub Actions anatomy, how to design a good pipeline, what to include (test, SAST, SCA, secret scan, container scan, IaC scan, SBOM, signing, deploy), pitfalls and security hardening, and a walkthrough of this repo's pipeline. |
| 02 | [Deploy to EKS (existing cluster)](02-deploy-to-eks.md) | Run the same app on an existing EKS cluster: get creds with `aws eks update-kubeconfig` (or `eksctl` if you ever need a cluster), app manifests (Deployment/Service/Ingress/HPA + kustomize), the ECS-to-EKS mapping, the `kubectl` deploy job, and a GitOps alternative. |
| 03 | [Pipelines by language](03-pipelines-by-language.md) | How the build/test/package stages change per stack: Java, Python, Ruby, .NET, Node/TS, Go (plus PHP, Rust), with caching, Dockerfile patterns, and ready-to-paste jobs. |
| 04 | [Testing strategy](04-testing-strategy.md) | The test pyramid, what gates PRs vs runs after dev sign-off, smoke tests, and real-world frameworks for functional/browser (Playwright, Cypress, Selenium), DAST (OWASP ZAP), and load testing (k6, Gatling, Locust, JMeter). |
| 05 | [Continuous delivery vs deployment](05-continuous-deployment.md) | What full continuous deployment looks, feels, and runs like; delivery-vs-deployment diagrams; progressive delivery (blue-green, canary, feature flags); DORA metrics; and how to convert this repo. |
| 06 | [Runners: hosted, self-hosted, Kubernetes](06-runners-and-scaling.md) | GitHub-hosted vs larger vs self-hosted runners, step-by-step self-hosted setup, ephemeral runners, Kubernetes runners with Actions Runner Controller (ARC), autoscaling, and runner security hardening. |
| 07 | [Secrets and architecture](07-secrets-and-architecture.md) | Handling sensitive data in pipelines (OIDC, vaults, masking, scanning, rotation) and CI/CD architecture concerns: security, scalability, reliability, maintainability, observability, cost, and governance. |

> These are teaching references, accurate as of 2025-2026. The runnable lab itself is the
> Terraform at the repo root; see the top-level [README](../README.md).
