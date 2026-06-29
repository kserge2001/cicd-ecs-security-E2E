# Deploy to EKS the enterprise way (GitOps with Argo CD)

This guide runs the same containerized app on an **existing Amazon EKS cluster** using
the pattern enterprises actually use: **GitOps with Argo CD**. CI never touches the
cluster. Instead, the desired state lives in Git, and an in-cluster controller (Argo CD)
continuously reconciles the cluster to match Git.

> Why not `kubectl apply` from CI? Push-based deploys are an anti-pattern at scale:
> they put cluster-admin credentials in the CI runner, give you no drift detection,
> no single source of truth, no automatic rollback to the declared state, and a weak
> audit trail. GitOps fixes all of these.

## 1. The model

```mermaid
flowchart LR
  subgraph App repo
    A[push to dev/qa/main] --> B[CI: build + scan]
    B --> C[push image to ECR]
    C --> D[bump image tag in config repo]
  end
  subgraph Config repo (desired state)
    D -->|dev: auto-commit| E[overlays/dev]
    D -->|qa/prod: Pull Request + approval| F[overlays/qa, overlays/prod]
  end
  subgraph EKS cluster
    G[Argo CD] -->|reconciles| H[dev ns]
    G --> I[qa ns]
    G --> J[prod ns]
  end
  E --> G
  F --> G
```

Two repos (separation of concerns, the enterprise norm):

| Repo | Owns | Who writes |
|---|---|---|
| App repo (this one) | Source code, Dockerfile, CI that builds/scans/pushes the image | Developers |
| Config repo (GitOps) | Kubernetes manifests = the desired state, per environment | CI bumps image tags; humans review promotions |

Argo CD watches the **config repo** and makes the cluster match it. The only thing CI
does to "deploy" is change a tag in Git.

## 2. Prerequisites

- An existing EKS cluster you can reach. Bootstrapping Argo CD is the one time you use
  direct cluster access:

  ```bash
  aws eks update-kubeconfig --region <aws-region> --name <cluster-name>
  kubectl get nodes
  ```

  (If you ever need a cluster: `eksctl create cluster --name <name> --region <r> --with-oidc --managed`. That is the only "create a cluster" step. It is out of scope here.)

- The **AWS Load Balancer Controller** in the cluster (for ALB Ingress). Verify:
  `kubectl get deploy -n kube-system aws-load-balancer-controller`.
- **ExternalDNS** (for Route 53 records from Ingress) and **External Secrets Operator**
  (for pulling secrets from AWS Secrets Manager). Both are standard cluster add-ons.

## 3. Bootstrap Argo CD

Install once (Helm is the common enterprise install; pin the chart version):

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version <pinned-chart-version> \
  -f argocd-values.yaml   # SSO/OIDC, RBAC, HA, ingress configured here
```

In production, Argo CD itself is managed by GitOps (the **app-of-apps** pattern): a
root Application points at a folder of Application/ApplicationSet definitions so the
platform is reproducible and auditable. Configure SSO (OIDC to your IdP) and RBAC
rather than the local `admin` user.

## 4. The config repo layout (Kustomize base + overlays)

```
app-config/
  base/
    deployment.yaml      # or a Rollout (see section 8)
    service.yaml
    ingress.yaml
    hpa.yaml
    kustomization.yaml
  overlays/
    dev/   { kustomization.yaml, patches }   # namespace dev,  host dev.<domain>
    qa/    { kustomization.yaml, patches }    # namespace qa,   host qa.<domain>
    prod/  { kustomization.yaml, patches }    # namespace prod, host prod.<domain>
  argocd/
    project.yaml         # AppProject (guardrails)
    applicationset.yaml  # generates one Application per env
```

`base/ingress.yaml` (ALB via the AWS Load Balancer Controller, TLS from ACM):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: <acm-cert-arn-for-*.your-domain>
spec:
  ingressClassName: alb
  rules:
    - host: HOST_PLACEHOLDER     # patched per overlay
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: app, port: { number: 80 } } }
```

The Deployment, Service, and HPA are standard (image is set per overlay by
`kustomize edit set image`, which CI runs). Each overlay sets its `namespace`, `host`,
and `replicas`.

## 5. Guardrails: the AppProject

An `AppProject` restricts what these Applications may do (multi-tenancy and blast-radius
control), a must-have in enterprise Argo CD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: app
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/<org>/app-config.git   # only this repo
  destinations:
    - server: https://kubernetes.default.svc
      namespace: dev
    - server: https://kubernetes.default.svc
      namespace: qa
    - server: https://kubernetes.default.svc
      namespace: prod
  clusterResourceWhitelist: []                   # no cluster-scoped resources
  namespaceResourceWhitelist:
    - { group: "apps", kind: Deployment }
    - { group: "", kind: Service }
    - { group: "networking.k8s.io", kind: Ingress }
    - { group: "autoscaling", kind: HorizontalPodAutoscaler }
  # Restrict prod deploys to a maintenance window if desired:
  syncWindows:
    - kind: allow
      schedule: "0 9 * * 1-5"
      duration: 8h
      applications: ["app-prod"]
```

## 6. One Application per environment (ApplicationSet)

`ApplicationSet` generates an Argo CD `Application` per env. The key enterprise nuance:
**dev auto-syncs; qa and prod are gated** (manual sync and/or PR-gated desired state):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: app
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - { env: dev,  auto: "true"  }
          - { env: qa,   auto: "false" }
          - { env: prod, auto: "false" }
  template:
    metadata:
      name: 'app-{{.env}}'
    spec:
      project: app
      source:
        repoURL: https://github.com/<org>/app-config.git
        targetRevision: main
        path: 'overlays/{{.env}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.env}}'
      syncPolicy:
        syncOptions: [ CreateNamespace=true ]
  templatePatch: |        # dev gets automated self-healing sync; qa/prod stay manual
    {{- if eq .auto "true" }}
    spec:
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
    {{- end }}
```

- **dev**: `automated` + `selfHeal` + `prune`: any change merged to the dev overlay is
  applied within minutes and drift is corrected automatically.
- **qa / prod**: no `automated` policy. The new desired state lands via a reviewed PR,
  then a human with the right Argo RBAC clicks Sync (or it is auto-synced inside a
  `syncWindow`). This is where the approval gate lives now.

## 7. Promotion: how the image tag gets to Git (this is the deploy)

CI's only deployment responsibility is to change the image tag in the config repo. This
replaces the old `kubectl` job entirely. Build, scan, and ECR push stay exactly as the
ECS pipeline does them (same per-env ECR, same OIDC role, same `vX.Y.Z` for prod /
commit SHA for dev/qa).

```yaml
  promote:
    needs: build-and-scan
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Checkout config repo
        uses: actions/checkout@v4
        with:
          repository: <org>/app-config
          token: ${{ secrets.CONFIG_REPO_TOKEN }}   # GitHub App token, write to config repo only

      - name: Set image in the right overlay
        env:
          ENV: ${{ github.ref_name == 'main' && 'prod' || github.ref_name }}
          IMAGE: ${{ needs.build-and-scan.outputs.image }}
        run: |
          cd overlays/$ENV
          kustomize edit set image app=$IMAGE

      # dev: commit straight to main (auto-deploys via Argo). qa/prod: open a PR.
      - name: Promote
        env:
          ENV: ${{ github.ref_name == 'main' && 'prod' || github.ref_name }}
        run: |
          if [ "$ENV" = "dev" ]; then
            git commit -am "dev: deploy ${{ needs.build-and-scan.outputs.version }}"
            git push
          else
            git switch -c promote/$ENV-${{ needs.build-and-scan.outputs.version }}
            git commit -am "$ENV: promote ${{ needs.build-and-scan.outputs.version }}"
            git push -u origin HEAD
            gh pr create --fill --base main
          fi
```

The **PR approval on the config repo is the enterprise promotion gate**, enforced with
branch protection + `CODEOWNERS` (for example, the SRE team owns `overlays/prod/`). This
is auditable in Git and decoupled from the build.

> Lower-touch alternative: **Argo CD Image Updater** watches ECR for new tags matching a
> constraint and writes the tag back to Git itself, so CI does not need write access to
> the config repo. Use it for dev/qa; keep PR-gated promotion for prod.

## 8. Progressive delivery (Argo Rollouts) instead of a plain Deployment

For real prod safety, replace the `Deployment` with an **Argo Rollouts** `Rollout` that
does canary or blue-green with automated metric analysis and auto-rollback. This is what
"safe continuous deployment" looks like on Kubernetes:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: app }
spec:
  replicas: 4
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: { duration: 2m }
        - analysis:                 # query Prometheus; auto-abort on bad metrics
            templates: [{ templateName: success-rate }]
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100
  selector: { matchLabels: { app: app } }
  template: { } # same pod spec as the Deployment
```

`AnalysisTemplate` checks success rate / p95 latency against an SLO during the canary;
if it breaches, Argo Rollouts automatically rolls back. Pair it with **Flagger** if you
prefer that controller. This is how you remove the human from prod safely (see
[continuous deployment](05-continuous-deployment.md)).

## 9. Secrets the enterprise way (never plaintext in Git)

GitOps means everything is in Git, so secrets need encryption or externalization:

- **External Secrets Operator (recommended on AWS)**: store secrets in AWS Secrets
  Manager / SSM, and an `ExternalSecret` syncs them into Kubernetes Secrets. The
  operator authenticates with **IRSA**, so no static keys.

  ```yaml
  apiVersion: external-secrets.io/v1beta1
  kind: ExternalSecret
  metadata: { name: app-secrets, namespace: prod }
  spec:
    secretStoreRef: { name: aws-secretsmanager, kind: SecretStore }
    target: { name: app-secrets }
    data:
      - secretKey: APP_ENV_SECRET
        remoteRef: { key: pipeline-lab/prod/APP_ENV_SECRET }
  ```

- **Sealed Secrets / SOPS + KMS**: if you must keep the secret material in Git, store it
  encrypted (only the in-cluster controller / a KMS key can decrypt). Use this when you
  do not have a central secrets manager.

If the app needs AWS APIs at runtime, give its `ServiceAccount` an **IRSA** role, not a
key in a secret.

## 10. Map the ECS pieces to the GitOps/EKS world

| ECS (this repo) | GitOps on EKS |
|---|---|
| ECS service | Deployment or Rollout (in the config repo) |
| Task definition | Pod template |
| ALB + target group + listeners | Ingress + AWS Load Balancer Controller |
| ECS cluster | Namespace (dev/qa/prod) |
| `amazon-ecs-deploy-task-definition` in CI | CI bumps the image tag in Git; Argo CD deploys |
| GitHub Environment approval gate | PR approval + CODEOWNERS on the config repo (and Argo manual sync / sync windows) |
| Task execution role | IRSA / Pod Identity |
| Route 53 alias (Terraform) | Ingress host + ExternalDNS |
| Manual rollback | `git revert` (Argo reconciles back) or Argo Rollouts auto-rollback |

## 11. Why this is the real pattern

- **Single source of truth**: the cluster's desired state is a Git repo. Drift is
  detected and (for dev) auto-corrected.
- **No cluster credentials in CI**: the pull-based controller holds access, not the
  runner. Smaller attack surface.
- **Auditable promotion**: every prod change is a reviewed, signed PR with history.
- **Trivial rollback / DR**: `git revert`, or rebuild a cluster and point Argo at the
  same repo to restore the entire platform state.
- **Separation of duties**: developers change code, platform/SRE owns prod overlays via
  CODEOWNERS, Argo RBAC governs who can sync.

## 12. Enterprise GitOps readiness checklist

- [ ] Separate app repo and config (GitOps) repo
- [ ] Argo CD installed via GitOps (app-of-apps), SSO + RBAC, HA mode
- [ ] AppProject restricting repos, destinations, and resource kinds
- [ ] ApplicationSet: dev auto-sync + self-heal; qa/prod manual or sync-window gated
- [ ] Promotion via PR + branch protection + CODEOWNERS on `overlays/prod`
- [ ] CI has write access only to the config repo (GitHub App), never cluster admin
- [ ] Argo Rollouts (or Flagger) for prod canary/blue-green with metric analysis + auto-rollback
- [ ] Secrets via External Secrets Operator (IRSA) or Sealed Secrets/SOPS, never plaintext in Git
- [ ] Ingress TLS via ACM, DNS via ExternalDNS, image tags immutable (no `latest`)
- [ ] Argo notifications + health dashboards; alert on OutOfSync / degraded
