# Documentation

In-depth guides that go beyond this repo's ECS lab: how to design pipelines, test them,
run your own Kubernetes, scale runners, and ship safely.

| # | Guide | What it covers |
|---|-------|----------------|
| 01 | [CI/CD & GitHub Actions](01-cicd-and-github-actions.md) | CI vs CD, full GitHub Actions anatomy, how to design a good pipeline, what to include (test, SAST, SCA, secret scan, container scan, IaC scan, SBOM, signing, deploy), pitfalls and security hardening, and a walkthrough of this repo's pipeline. |
| 02 | [Self-hosted Kubernetes](02-self-hosted-kubernetes.md) | k8s architecture, distro comparison, a full `kubeadm` cluster build, bare-metal networking (MetalLB, ingress-nginx, cert-manager), storage, day-2 ops, hardening, and a k3s fast path. |
| 03 | [Deploy to EKS instead of ECS](03-deploy-to-eks.md) | ECS vs EKS, provisioning EKS with Terraform, IRSA and the AWS Load Balancer Controller, app manifests, mapping every ECS piece to its EKS equivalent, pipeline changes, and a GitOps alternative. |
| 04 | [Pipelines by language](04-pipelines-by-language.md) | How the build/test/package stages change per stack: Java, Python, Ruby, .NET, Node/TS, Go (plus PHP, Rust), with caching, Dockerfile patterns, and ready-to-paste jobs. |
| 05 | [Testing strategy](05-testing-strategy.md) | The test pyramid, what gates PRs vs runs after dev sign-off, smoke tests, and real-world frameworks for functional/browser (Playwright, Cypress, Selenium), DAST (OWASP ZAP), and load testing (k6, Gatling, Locust, JMeter). |
| 06 | [Continuous delivery vs deployment](06-continuous-deployment.md) | What full continuous deployment looks, feels, and runs like; delivery-vs-deployment diagrams; progressive delivery (blue-green, canary, feature flags); DORA metrics; and how to convert this repo. |
| 07 | [Runners: hosted, self-hosted, Kubernetes](07-runners-and-scaling.md) | GitHub-hosted vs larger vs self-hosted runners, step-by-step self-hosted setup, ephemeral runners, Kubernetes runners with Actions Runner Controller (ARC), autoscaling, and runner security hardening. |
| 08 | [Secrets and architecture](08-secrets-and-architecture.md) | Handling sensitive data in pipelines (OIDC, vaults, masking, scanning, rotation) and CI/CD architecture concerns: security, scalability, reliability, maintainability, observability, cost, and governance. |

> These are teaching references, accurate as of 2025-2026. The runnable lab itself is the
> Terraform at the repo root; see the top-level [README](../README.md).
