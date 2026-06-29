# Documentation

In-depth guides that go beyond this repo's ECS lab — how to design pipelines, run
your own Kubernetes, and take the same app to EKS.

| # | Guide | What it covers |
|---|-------|----------------|
| 01 | [CI/CD & GitHub Actions](01-cicd-and-github-actions.md) | CI vs CD, full GitHub Actions anatomy, how to design a good pipeline, what to include (test/SAST/SCA/secret-scan/container-scan/IaC-scan/SBOM/signing/deploy), pitfalls & security hardening, and a walkthrough of this repo's pipeline. |
| 02 | [Self-hosted Kubernetes](02-self-hosted-kubernetes.md) | k8s architecture, distro comparison, a full `kubeadm` cluster build, bare-metal networking (MetalLB, ingress-nginx, cert-manager), storage, day-2 ops, hardening, and a k3s fast path. |
| 03 | [Deploy to EKS instead of ECS](03-deploy-to-eks.md) | ECS vs EKS, provisioning EKS with Terraform, IRSA & the AWS Load Balancer Controller, app manifests (Deployment/Service/Ingress/HPA), mapping every ECS piece to its EKS equivalent, pipeline changes, and a GitOps alternative. |

> These are teaching references — accurate as of 2025–2026. The runnable lab itself is
> the Terraform at the repo root; see the top-level [README](../README.md).
