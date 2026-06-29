# Deploy to EKS (existing cluster)

This guide takes the same containerized app and runs it on an **existing Amazon EKS
cluster** instead of ECS Fargate. It assumes the cluster already exists and that you
have `kubectl`, `aws`, and (for templating) `kustomize` available. We do not provision
a cluster here.

What stays the same vs the ECS lab:

| Stays the same | Changes |
|---|---|
| Per-env ECR repos, OIDC deploy roles, build + image push, semver tagging | The deploy target: ECS service to a Kubernetes Deployment |
| dev / qa / prod model and GitHub Environment approval gates | ALB created by the AWS Load Balancer Controller (via an Ingress) instead of Terraform |
| SonarQube / Snyk scanning, branch protection | Deploy step uses `kubectl` / `kustomize` after `aws eks update-kubeconfig` |

## 1. Get cluster credentials

Point your local kubeconfig at the existing cluster, then confirm access:

```bash
aws eks update-kubeconfig --region <aws-region> --name <cluster-name>
kubectl get nodes
kubectl get pods -A
```

`update-kubeconfig` writes a context into `~/.kube/config` that calls `aws eks
get-token` for short-lived credentials, so there is no static kubeconfig secret to
manage. Your IAM identity must be granted access to the cluster (see section 6).

## 2. If you ever need to create a cluster

You said the cluster already exists, so skip this. If you ever need one, a single
`eksctl` command creates the control plane, a node group, the VPC, and the OIDC
provider, then wires kubeconfig for you:

```bash
eksctl create cluster \
  --name <cluster-name> \
  --region <aws-region> \
  --nodes 2 --node-type t3.medium \
  --with-oidc --managed

# eksctl updates kubeconfig automatically; if not:
aws eks update-kubeconfig --region <aws-region> --name <cluster-name>
```

That is it for cluster creation. Everything below is about deploying the app onto the
cluster you already have.

> ⚠️ The Ingress in section 4 needs the **AWS Load Balancer Controller** installed in
> the cluster. Most existing clusters already have it. Check with
> `kubectl get deploy -n kube-system aws-load-balancer-controller`. If it is missing,
> install it once via Helm (chart `eks/aws-load-balancer-controller`) with an IRSA role.

## 3. ECS vs EKS in one table

| Concern | ECS Fargate (this lab) | EKS |
|---|---|---|
| Control plane | None to manage | Managed by AWS (hourly cost per cluster) |
| Learning curve | Low | Higher (Kubernetes) |
| Portability | AWS only | Portable across any k8s |
| Ecosystem | AWS-native | Helm, Operators, Argo, etc. |
| Best when | Simple services, small teams | Many services, k8s skills, multi-cloud |

Use the cluster you have; this section is just context for interviews and design calls.

## 4. App manifests (kustomize: base + per-env overlays)

One cluster, three **namespaces** (`dev`, `qa`, `prod`). Layout:

```
k8s/
  base/
    namespace.yaml
    deployment.yaml
    service.yaml
    ingress.yaml
    hpa.yaml
    kustomization.yaml
  overlays/
    dev/kustomization.yaml
    qa/kustomization.yaml
    prod/kustomization.yaml
```

**base/deployment.yaml** (image is patched per env by the pipeline):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 2
  selector:
    matchLabels: { app: app }
  template:
    metadata:
      labels: { app: app }
    spec:
      containers:
        - name: app
          image: PLACEHOLDER_IMAGE # patched by the pipeline (ECR image:tag)
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet: { path: /, port: 80 }
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "250m", memory: "256Mi" }
```

**base/service.yaml**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app
spec:
  selector: { app: app }
  ports:
    - port: 80
      targetPort: 80
```

**base/ingress.yaml** (the AWS Load Balancer Controller turns this into an internet-facing ALB with TLS):

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
    - host: HOST_PLACEHOLDER # e.g. dev.your-domain.com, patched per env
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port: { number: 80 }
```

**base/hpa.yaml**:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: app }
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
```

**overlays/dev/kustomization.yaml** (qa and prod are the same idea with their own namespace/host):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: dev
resources:
  - ../../base
patches:
  - target: { kind: Ingress, name: app }
    patch: |
      - op: replace
        path: /spec/rules/0/host
        value: dev.your-domain.com
```

Apply by hand to test:

```bash
kubectl apply -k k8s/overlays/dev
kubectl -n dev rollout status deploy/app
```

DNS: point `dev/qa/prod.your-domain.com` at the ALB the Ingress creates. Use
**ExternalDNS** in the cluster to manage Route 53 records automatically, or create the
alias records manually once.

## 5. Map the ECS pieces to EKS

| ECS (this repo) | EKS equivalent |
|---|---|
| ECS service | Deployment |
| Task definition / container def | Pod template in the Deployment |
| ALB + target group + listeners | Ingress + AWS Load Balancer Controller |
| ECS cluster | Namespace (dev/qa/prod) in the shared cluster |
| Task execution role | IRSA / Pod Identity (only if the app needs AWS APIs) |
| awslogs log driver | Container stdout, shipped by Fluent Bit / CloudWatch |
| Route 53 alias (Terraform) | Ingress host + ExternalDNS |
| Desired count | `replicas` + HPA |

## 6. Pipeline changes

Build and push to the per-env ECR stay exactly as they are today (same OIDC role,
same image tag = semver for prod / SHA for dev/qa). Only the **deploy job** changes.

Two one-time setup items so the deploy role can talk to the cluster:

1. **IAM**: add `eks:DescribeCluster` to each env deploy role (the existing roles in
   `iam.tf` already have ECR + ECS; just add this one action, and drop the ECS actions
   when you fully move off ECS).
2. **Kubernetes access**: grant the role access with an **EKS Access Entry** (the modern
   replacement for the `aws-auth` ConfigMap), scoped to that env's namespace:

```bash
aws eks create-access-entry \
  --cluster-name <cluster> \
  --principal-arn arn:aws:iam::<acct>:role/pipeline-lab-full-cicd-dev-deploy

aws eks associate-access-policy \
  --cluster-name <cluster> \
  --principal-arn arn:aws:iam::<acct>:role/pipeline-lab-full-cicd-dev-deploy \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=dev
```

Then the deploy job (replaces the ECS deploy step):

```yaml
  deploy:
    needs: build-and-scan
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: ${{ github.ref_name == 'main' && 'prod' || github.ref_name }}
    permissions: { contents: read, id-token: write }
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC, env-scoped role)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - name: Get cluster credentials
        run: aws eks update-kubeconfig --region ${{ vars.AWS_REGION }} --name ${{ vars.EKS_CLUSTER }}

      - name: Deploy
        env:
          NS: ${{ github.ref_name == 'main' && 'prod' || github.ref_name }}
          IMAGE: ${{ needs.build-and-scan.outputs.image }}
        run: |
          kubectl -n "$NS" set image deployment/app app="$IMAGE"
          kubectl -n "$NS" rollout status deployment/app --timeout=120s
```

Add a repo/env variable `EKS_CLUSTER` with the cluster name. Keep the same environment
approval gates and prod semver tagging from the ECS pipeline.

> Prefer declarative over `kubectl set image`? Use `kubectl apply -k k8s/overlays/$NS`
> after patching the image with `kustomize edit set image`.

## 7. GitOps alternative (recommended for k8s at scale)

Instead of the pipeline pushing with `kubectl` (push-based), commit the rendered
manifests to a git repo and let **Argo CD** or **Flux** reconcile the cluster to match
(pull-based). The CI job's only k8s responsibility becomes "bump the image tag in the
manifests repo and open a PR". Benefits: git is the single source of truth, drift is
auto-corrected, rollback is `git revert`, and the cluster credentials never live in CI.
Trade-off: another component to run and learn.

## 8. Migration from the ECS setup, and teardown

- Stand the app up on EKS in a `dev` namespace first; verify via the ALB host.
- Cut DNS (`dev/qa/prod`) from the ECS ALBs to the EKS Ingress ALBs one env at a time.
- Once traffic is on EKS, remove the ECS module usage from Terraform (the `modules/ecs-env`
  calls) and the ECS actions from the deploy roles. Keep ECR and the OIDC roles.
- Teardown of EKS workloads is `kubectl delete -k k8s/overlays/<env>`; the cluster
  itself is managed outside this repo (you own it).

## 9. EKS production readiness checklist

- [ ] AWS Load Balancer Controller installed and healthy
- [ ] Each env namespace created with resource quotas / limit ranges
- [ ] Deploy roles granted via EKS Access Entries, scoped to their namespace
- [ ] Readiness + liveness probes on every Deployment
- [ ] HPA (and Cluster Autoscaler or Karpenter) configured
- [ ] Ingress TLS via ACM, DNS via ExternalDNS
- [ ] Logs to CloudWatch (Fluent Bit) and metrics to Prometheus/CloudWatch
- [ ] NetworkPolicies and Pod Security Admission enforced
- [ ] Image tags immutable (no `latest`); rollouts use `rollout status` gating
