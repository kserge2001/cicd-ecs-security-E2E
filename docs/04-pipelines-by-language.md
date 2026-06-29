# CI/CD pipeline differences by language / stack

This document explains how the CI/CD pipeline in `cicd-ecs-security-E2E` changes depending on the application language or stack you deploy.

The base pipeline (`repo-seed/.github/workflows/ci-cd.yml`) currently ships a **static nginx site**: there is no compile step, no dependency resolution, and the "build" is just `docker build`. The image is then scanned, pushed to a per-environment ECR repository, and rolled out to ECS Fargate. The base `Dockerfile` is intentionally trivial:

```dockerfile
FROM nginx:alpine
COPY app/ /usr/share/nginx/html/
EXPOSE 80
HEALTHCHECK CMD wget -qO- http://localhost/ || exit 1
```

Real applications need a language-specific **build-and-test** stage that runs *before* the container is built (or as the first stage of a multi-stage build). That stage is where almost all the per-language differences live. Everything after the image is produced (scan, push to ECR, deploy to ECS via OIDC, environment promotion) is identical across languages.

The snippets below are GitHub Actions jobs you can paste alongside the existing `build-and-scan` job. They run unit tests, linters, and coverage, then either produce a build artifact that the Dockerfile copies in, or rely on a multi-stage Dockerfile that compiles inside the build.

> Note on versions: action and tool versions reflect the 2025-2026 ecosystem. Pin to the latest patched release in your own repo and let Dependabot bump them.

---

## 1. Java (Maven and Gradle)

### Build tools
- **Maven** (`pom.xml`) or **Gradle** (`build.gradle` / `build.gradle.kts`). Pick one per service.
- JDK provisioned by `actions/setup-java@v4`, which has built-in dependency caching for both build tools.

### Dependency install + caching
`setup-java` caches the local repository (`~/.m2` for Maven, `~/.gradle/caches` and wrapper for Gradle) automatically when you set the `cache` input. No separate `actions/cache` step is required.

```yaml
- uses: actions/setup-java@v4
  with:
    distribution: temurin   # Eclipse Temurin 21 LTS
    java-version: '21'
    cache: maven            # or: gradle
```

The cache key is derived from your lockfile/build files (`pom.xml`, or `*.gradle*` plus `gradle-wrapper.properties`).

### Unit tests + coverage
- **JUnit 5** is the standard test framework. Surefire (Maven) / the `test` task (Gradle) run it.
- Coverage via **JaCoCo**. Maven: `jacoco-maven-plugin` bound to `test` + `report`. Gradle: `jacocoTestReport`.

```bash
mvn -B verify                 # compiles, runs JUnit, produces target/site/jacoco
# or
./gradlew test jacocoTestReport
```

### Linters / formatters / SAST
- **Checkstyle** (style), **SpotBugs** (static bug finder, the successor to FindBugs), optionally **PMD**.
- Formatting via **Spotless** (google-java-format).
- Wire SpotBugs/Checkstyle into `mvn verify` so they gate the build:

```bash
mvn -B checkstyle:check spotbugs:check
```

### Artifact
A `jar` (Spring Boot fat jar) or `war`. Spring Boot produces an executable jar under `target/*.jar`.

### Dockerfile pattern
Two common options.

**Option A: Jib (no Dockerfile, no Docker daemon).** Jib builds an optimized, layered, non-root image straight from the build tool. It is reproducible and fast.

```bash
mvn -B compile jib:dockerBuild -Dimage=app:ci
# or ./gradlew jibDockerBuild --image=app:ci
```

**Option B: multi-stage Dockerfile.**

```dockerfile
# build stage
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline      # cache deps layer
COPY src ./src
RUN mvn -B -q package -DskipTests

# runtime stage (slim, non-root JRE)
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=build /src/target/*.jar app.jar
USER app
EXPOSE 8080
ENTRYPOINT ["java","-jar","app.jar"]
```

### Ready-to-paste build-and-test job

```yaml
build-and-test-java:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-java@v4
      with:
        distribution: temurin
        java-version: '21'
        cache: maven
    - name: Build, test, coverage, static analysis
      run: mvn -B verify checkstyle:check spotbugs:check
    - uses: actions/upload-artifact@v4
      with:
        name: jar
        path: target/*.jar
```

---

## 2. Python

### Build tools
- **pip** + `requirements.txt`, **Poetry** (`pyproject.toml` + `poetry.lock`), or **uv** (`pyproject.toml` + `uv.lock`). uv is the fastest and increasingly the default for new projects.
- Python provisioned by `actions/setup-python@v5` (has pip cache built in), or by `astral-sh/setup-uv@v6` for uv.

### Dependency install + caching
**pip** (cache keyed on `requirements*.txt`):

```yaml
- uses: actions/setup-python@v5
  with:
    python-version: '3.12'
    cache: pip
    cache-dependency-path: requirements*.txt
- run: pip install -r requirements.txt
```

**Poetry** (cache the virtualenv with `actions/cache`):

```yaml
- uses: actions/setup-python@v5
  with: { python-version: '3.12' }
- run: pipx install poetry
- uses: actions/cache@v4
  with:
    path: ~/.cache/pypoetry
    key: poetry-${{ runner.os }}-${{ hashFiles('poetry.lock') }}
- run: poetry install --no-interaction
```

**uv** (built-in caching, keyed on `uv.lock`):

```yaml
- uses: astral-sh/setup-uv@v6
  with:
    enable-cache: true
    cache-dependency-glob: uv.lock
- run: uv sync --frozen
```

### Unit tests + coverage
- **pytest** + **pytest-cov** (built on `coverage.py`).

```bash
pytest --cov=app --cov-report=xml --cov-report=term
```

### Linters / formatters / type checking
- **Ruff** (lint + format, replaces flake8/isort and competes with black), or **Black** for formatting.
- **mypy** for static type checking.

```bash
ruff check . && ruff format --check .
mypy app
```

### Artifact
A **wheel** (`.whl`) built with `python -m build` or `uv build`, or just the source tree copied into the image.

### Dockerfile pattern
Use a **slim** base (`python:3.12-slim`), install only runtime deps, run as non-root. Note: serve WSGI/ASGI apps with **gunicorn** (sync, e.g. Django/Flask) or **uvicorn** / `gunicorn -k uvicorn.workers.UvicornWorker` (ASGI, e.g. FastAPI). Do not use the dev server in production.

```dockerfile
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd -m app && chown -R app /app
USER app
EXPOSE 8000
CMD ["gunicorn","-k","uvicorn.workers.UvicornWorker","-b","0.0.0.0:8000","app.main:app"]
```

### Ready-to-paste build-and-test job

```yaml
build-and-test-python:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: astral-sh/setup-uv@v6
      with:
        enable-cache: true
        cache-dependency-glob: uv.lock
    - run: uv sync --frozen
    - name: Lint + type check
      run: |
        uv run ruff check .
        uv run ruff format --check .
        uv run mypy app
    - name: Test + coverage
      run: uv run pytest --cov=app --cov-report=xml
    - uses: actions/upload-artifact@v4
      with:
        name: coverage
        path: coverage.xml
```

---

## 3. Ruby

### Build tools
- **Bundler** (`Gemfile` + `Gemfile.lock`).
- Ruby provisioned by `ruby/setup-ruby@v1`, which can install gems and cache them via `bundler-cache: true`.

### Dependency install + caching
`bundler-cache: true` runs `bundle install` and caches gems keyed on `Gemfile.lock`. No separate cache step needed.

```yaml
- uses: ruby/setup-ruby@v1
  with:
    ruby-version: '3.3'
    bundler-cache: true
```

### Unit tests + coverage
- **RSpec** (`bundle exec rspec`) or **Minitest** (`bundle exec rake test`).
- Coverage via **SimpleCov** (required at the top of `spec_helper.rb` / `test_helper.rb`).

```bash
bundle exec rspec        # or: bundle exec rake test
```

### Linters / formatters
- **RuboCop** (lint + autocorrect formatting). Brakeman is a common Rails-specific SAST tool.

```bash
bundle exec rubocop
```

### Artifact
There is no compiled artifact: Ruby ships source. For Rails, **precompile assets** at build time so the image contains static, fingerprinted assets:

```bash
RAILS_ENV=production bundle exec rake assets:precompile
```

### Dockerfile pattern
Multi-stage: build gems and precompile assets in a builder, copy into a slim runtime, run **Puma** as the app server, non-root.

```dockerfile
FROM ruby:3.3-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test
COPY . .
RUN RAILS_ENV=production SECRET_KEY_BASE=dummy bundle exec rake assets:precompile

FROM ruby:3.3-slim
WORKDIR /app
RUN useradd -m app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
USER app
EXPOSE 3000
CMD ["bundle","exec","puma","-C","config/puma.rb"]
```

### Ready-to-paste build-and-test job

```yaml
build-and-test-ruby:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: ruby/setup-ruby@v1
      with:
        ruby-version: '3.3'
        bundler-cache: true
    - name: Lint
      run: bundle exec rubocop
    - name: Test
      run: bundle exec rspec
```

---

## 4. .NET

### Build tools
- The **dotnet SDK** CLI: `dotnet restore`, `build`, `test`, `publish`.
- SDK provisioned by `actions/setup-dotnet@v4`.

### Dependency install + caching
NuGet packages live under `~/.nuget/packages`. Enable lock files (`packages.lock.json`) and cache on them. `setup-dotnet` supports a `cache` input keyed on lock files.

```yaml
- uses: actions/setup-dotnet@v4
  with:
    dotnet-version: '8.0.x'
    cache: true
    cache-dependency-path: '**/packages.lock.json'
- run: dotnet restore --locked-mode
```

### Unit tests + coverage
- **xUnit** (also NUnit / MSTest). Coverage via **coverlet** (`--collect:"XPlat Code Coverage"`).

```bash
dotnet test --no-restore --collect:"XPlat Code Coverage"
```

### Linters / formatters
- `dotnet format` (style + analyzers), Roslyn analyzers, optionally StyleCop.

```bash
dotnet format --verify-no-changes
```

### Artifact
A framework-dependent or self-contained publish output from `dotnet publish -c Release -o out`. With trimming/AOT you can ship a single native binary.

### Dockerfile pattern
Build with the **SDK** image, run on the **chiseled** ASP.NET runtime image. Chiseled images (`mcr.microsoft.com/dotnet/aspnet:8.0-jammy-chiseled`) are distroless-style: minimal, no shell, and run as a non-root user by default. For the smallest footprint use **trimming** (`PublishTrimmed`) or **Native AOT** (`PublishAot`, no JIT, no runtime) where your app supports it.

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY *.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:8.0-jammy-chiseled
WORKDIR /app
COPY --from=build /app .
# chiseled image already runs as non-root (UID 64198)
EXPOSE 8080
ENTRYPOINT ["dotnet","MyApp.dll"]
```

### Ready-to-paste build-and-test job

```yaml
build-and-test-dotnet:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-dotnet@v4
      with:
        dotnet-version: '8.0.x'
        cache: true
        cache-dependency-path: '**/packages.lock.json'
    - run: dotnet restore --locked-mode
    - run: dotnet format --verify-no-changes
    - run: dotnet build -c Release --no-restore
    - run: dotnet test -c Release --no-build --collect:"XPlat Code Coverage"
```

---

## 5. Node.js / TypeScript

### Build tools
- Package manager: **npm**, **pnpm**, or **yarn** (lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`).
- Node provisioned by `actions/setup-node@v4`, which caches the package manager's store. For pnpm, install it first with `pnpm/action-setup@v4`.

### Dependency install + caching
`setup-node`'s `cache` input keys on the lockfile and caches the global store (npm cache / pnpm store / yarn cache). Use a clean, reproducible install (`npm ci`).

```yaml
- uses: pnpm/action-setup@v4          # only if using pnpm
  with: { version: 9 }
- uses: actions/setup-node@v4
  with:
    node-version: '22'                # current LTS
    cache: pnpm                       # or: npm / yarn
- run: pnpm install --frozen-lockfile # npm ci / yarn install --immutable
```

### Unit tests + coverage
- **Vitest** (modern, fast, native ESM/TS) or **Jest**. Both support coverage out of the box.

```bash
pnpm vitest run --coverage     # or: jest --coverage
```

### Linters / formatters
- **ESLint** (lint, with `typescript-eslint`) and **Prettier** (format).

```bash
pnpm eslint . && pnpm prettier --check .
```

### Build + artifact
- **TypeScript** compiles with `tsc` (or a bundler such as esbuild/Vite/tsup) into `dist/`.
- Two deployment shapes:
  - **SPA / static frontend** (React/Vue/etc.): `vite build` produces a static `dist/` you serve from nginx (very close to the repo's current nginx pattern).
  - **Node server** (Express/Nest/Fastify): compile to `dist/` and run `node dist/main.js`.

### Dockerfile pattern
Multi-stage. Build with a full Node image, then copy only `dist/` and production `node_modules` (or static assets) into a slim runtime. Non-root.

```dockerfile
# Node server variant
FROM node:22-slim AS build
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY . .
RUN pnpm build                 # tsc -> dist/
RUN pnpm prune --prod

FROM node:22-slim
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
USER node
EXPOSE 3000
CMD ["node","dist/main.js"]
```

For a SPA, the runtime stage is `nginx:alpine` with `COPY --from=build /app/dist /usr/share/nginx/html`.

### Ready-to-paste build-and-test job

```yaml
build-and-test-node:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: pnpm/action-setup@v4
      with: { version: 9 }
    - uses: actions/setup-node@v4
      with:
        node-version: '22'
        cache: pnpm
    - run: pnpm install --frozen-lockfile
    - name: Lint + typecheck
      run: |
        pnpm eslint .
        pnpm tsc --noEmit
    - name: Test + coverage
      run: pnpm vitest run --coverage
    - name: Build
      run: pnpm build
```

---

## 6. Go

### Build tools
- The **go** toolchain: `go build`, `go test`, `go vet`.
- Go provisioned by `actions/setup-go@v5`, which caches the module cache and build cache automatically (keyed on `go.sum`). You can keep `cache: true` (default) or disable it and manage `actions/cache` manually.

### Dependency install + caching
```yaml
- uses: actions/setup-go@v5
  with:
    go-version: '1.23'
    cache: true                   # caches $GOMODCACHE and the build cache via go.sum
- run: go mod download
```

If managing the cache yourself:

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cache/go-build
      ~/go/pkg/mod
    key: go-${{ runner.os }}-${{ hashFiles('**/go.sum') }}
```

### Unit tests + coverage
- Built-in `go test` with the race detector and coverage profile.

```bash
go test -race -coverprofile=coverage.out ./...
go tool cover -func=coverage.out
```

### Linters / formatters
- **golangci-lint** (aggregates govet, staticcheck, gofmt/gofumpt, errcheck, etc.). Use the official action.

```yaml
- uses: golangci/golangci-lint-action@v6
  with: { version: latest }
```

### Artifact
A single statically linked binary. **CGO note:** set `CGO_ENABLED=0` to produce a fully static binary with no libc dependency. That is what lets you use `scratch` or distroless. If you need cgo (e.g. sqlite, certain DB drivers), you cannot use `scratch`; use a distroless or alpine base instead.

```bash
CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o app ./cmd/app
```

### Dockerfile pattern
Multi-stage. Compile a static binary, then copy it into a tiny image: `scratch` (nothing but the binary) or `gcr.io/distroless/static:nonroot` (adds CA certs, tzdata, and a non-root user). Distroless is the safer default.

```dockerfile
FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app ./cmd/app

FROM gcr.io/distroless/static:nonroot
COPY --from=build /app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
```

### Ready-to-paste build-and-test job

```yaml
build-and-test-go:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-go@v5
      with:
        go-version: '1.23'
        cache: true
    - uses: golangci/golangci-lint-action@v6
      with: { version: latest }
    - name: Test + coverage
      run: go test -race -coverprofile=coverage.out ./...
    - name: Build
      run: CGO_ENABLED=0 go build -ldflags="-s -w" -o app ./cmd/app
```

---

## 7. PHP and Rust (for completeness)

### PHP (Composer)
- **Build tool:** Composer (`composer.json` + `composer.lock`). PHP provisioned by `shivammathur/setup-php@v2`.
- **Caching:** `actions/cache` on `~/.composer/cache` (or `vendor/`) keyed on `composer.lock`.
- **Tests:** PHPUnit (`vendor/bin/phpunit`), coverage via Xdebug or PCOV.
- **Lint/static analysis:** PHP_CodeSniffer / PHP-CS-Fixer (style), PHPStan or Psalm (static analysis).
- **Artifact:** source plus a vendored `vendor/` from `composer install --no-dev --optimize-autoloader`.
- **Dockerfile:** `php:8.3-fpm-alpine` (or `php:8.3-cli` / php-apache), run as non-root, behind PHP-FPM + nginx for web apps.

```yaml
build-and-test-php:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: shivammathur/setup-php@v2
      with:
        php-version: '8.3'
        coverage: pcov
    - uses: actions/cache@v4
      with:
        path: ~/.composer/cache
        key: composer-${{ hashFiles('composer.lock') }}
    - run: composer install --no-interaction --prefer-dist
    - run: vendor/bin/phpstan analyse
    - run: vendor/bin/phpunit --coverage-clover coverage.xml
```

### Rust (Cargo)
- **Build tool:** Cargo (`Cargo.toml` + `Cargo.lock`). Toolchain via `dtolnay/rust-toolchain@stable`.
- **Caching:** `Swatinem/rust-cache@v2` caches the registry, git deps, and `target/` keyed on `Cargo.lock`.
- **Tests:** `cargo test`. Coverage via `cargo-llvm-cov`.
- **Lint/format:** `cargo clippy` (lint) and `cargo fmt --check` (format).
- **Artifact:** a single static binary. Build with the `musl` target (`x86_64-unknown-linux-musl`) for a fully static binary you can drop into `scratch` / distroless.
- **Dockerfile:** multi-stage, `rust:1` builder, copy the binary into `gcr.io/distroless/cc` or `scratch`, non-root.

```yaml
build-and-test-rust:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: dtolnay/rust-toolchain@stable
      with: { components: clippy, rustfmt }
    - uses: Swatinem/rust-cache@v2
    - run: cargo fmt --check
    - run: cargo clippy -- -D warnings
    - run: cargo test --all
    - run: cargo build --release
```

---

## Comparison table

| Language | Build tool | Test runner | Cache key strategy | Typical artifact | Base image (runtime) |
|----------|-----------|-------------|--------------------|------------------|----------------------|
| Java | Maven / Gradle | JUnit 5 (+JaCoCo) | `pom.xml` / `*.gradle*` (via setup-java) | fat jar / war | `eclipse-temurin:21-jre-alpine` or Jib |
| Python | pip / Poetry / uv | pytest (+cov) | `requirements*.txt` / `poetry.lock` / `uv.lock` | wheel or source | `python:3.12-slim` |
| Ruby | Bundler | RSpec / Minitest | `Gemfile.lock` (bundler-cache) | source (+ precompiled assets) | `ruby:3.3-slim` |
| .NET | dotnet CLI | xUnit (+coverlet) | `packages.lock.json` | publish output / native binary | `aspnet:8.0-*-chiseled` |
| Node / TS | npm / pnpm / yarn | Vitest / Jest | lockfile (via setup-node) | `dist/` (server) or static `dist/` (SPA) | `node:22-slim` or `nginx:alpine` |
| Go | go toolchain | `go test` | `go.sum` | static binary | `distroless/static:nonroot` or `scratch` |
| PHP | Composer | PHPUnit | `composer.lock` | source + `vendor/` | `php:8.3-fpm-alpine` |
| Rust | Cargo | `cargo test` | `Cargo.lock` (rust-cache) | static binary | `distroless/cc` or `scratch` |

---

## Monorepo vs polyrepo

- **Polyrepo:** one service per repository. Each repo carries its own copy of the pipeline (the repo-seed pattern). Simplest mental model and the closest fit to this lab. Branch -> environment mapping (`dev` / `qa` / `main`) applies per repo.
- **Monorepo:** many services in one repository. You want to build only what changed and fan out across services. Use **path filters** (`dorny/paths-filter` or `on.push.paths`) to skip untouched services, and a **build matrix** to run the shared build-and-test logic per service.

Matrix example for multiple services and/or language versions:

```yaml
strategy:
  fail-fast: false
  matrix:
    service: [api, worker, web]
    java: ['21', '17']     # test across LTS versions if needed
```

Each matrix leg produces its own image and (for the monorepo case) pushes to its own per-service ECR repository, while the deploy stage selects the right ECS service. The matrix keeps a single source of truth for the build steps instead of duplicating jobs.

---

## Dependency + SCA scanning per ecosystem

Software Composition Analysis (SCA) reads your **lockfiles** to find known-vulnerable dependencies. Each ecosystem has its own lockfile, and good tooling is lockfile-aware.

| Ecosystem | Lockfile(s) | Native audit | Cross-tool |
|-----------|-------------|--------------|-----------|
| Java | (resolved by Maven/Gradle) | OWASP Dependency-Check | Trivy, Snyk, Dependabot |
| Python | `requirements*.txt`, `poetry.lock`, `uv.lock` | `pip-audit` | Trivy, Snyk, Dependabot |
| Ruby | `Gemfile.lock` | `bundler-audit` | Trivy, Snyk, Dependabot |
| .NET | `packages.lock.json` | `dotnet list package --vulnerable` | Trivy, Snyk, Dependabot |
| Node / TS | `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock` | `npm audit` / `pnpm audit` | Trivy, Snyk, Dependabot |
| Go | `go.sum` | `govulncheck` | Trivy, Snyk, Dependabot |
| PHP | `composer.lock` | `composer audit` | Trivy, Snyk, Dependabot |
| Rust | `Cargo.lock` | `cargo audit` | Trivy, Snyk, Dependabot |

Cross-cutting tools used in this repo and how they fit:

- **Trivy:** scans both the filesystem (lockfiles, IaC) and the built **container image** (OS packages + app deps). Run it on `app:ci` right after `docker build`, like the existing Snyk container step.
- **Snyk:** the repo already wires `snyk/actions/docker` to scan the built image (gated on `SNYK_TOKEN`, currently `continue-on-error`). Snyk also has per-ecosystem `snyk test` for source dependencies.
- **Dependabot:** repo-level, language-aware. Add one `package-ecosystem` entry per stack in `.github/dependabot.yml` so it opens PRs to bump vulnerable/outdated deps and the GitHub Actions versions used by the pipeline.
- **SonarQube:** the existing `sonarqube-scan-action` step handles SAST and quality gates; it understands most of these languages directly.

Treat SCA the same way the repo treats container scanning: run it in `build-and-scan` so it gates the image before it is ever pushed to ECR.

---

## What stays the same regardless of language

The language only changes the **build-and-test** stage. The backbone of the repo's pipeline is identical for every stack:

1. **Build once, immutable image.** Whatever the language, the result is a single OCI image built in CI. It is tagged with the commit SHA on `dev`/`qa` and with a bumped `vX.Y.Z` semver tag on `main` (see the `Determine version / image tag` step). The image is never rebuilt per environment.
2. **Gates before promotion.** Unit tests, coverage, linters, SAST (SonarQube), and SCA/container scanning (Snyk/Trivy) all run in `build-and-scan`. PRs build and scan only (no AWS access); a failing gate blocks the merge.
3. **Push to a per-environment ECR via OIDC.** On a real push, the branch maps to an environment, role, and ECR repo (`dev` / `qa` / `prod`). Credentials come from short-lived **GitHub OIDC** tokens (`id-token: write`) assuming an env-scoped IAM role. No long-lived AWS keys.
4. **Deploy to ECS Fargate via OIDC.** The `deploy` job assumes the environment's role, renders the task definition with the new image (`amazon-ecs-render-task-definition`), and rolls it out with `amazon-ecs-deploy-task-definition` using `wait-for-service-stability: true`.
5. **Environment promotion through branches + GitHub Environments.** `dev` -> `qa` -> `main`(prod). The matching GitHub Environment carries the approval gate / wait timer, so promotion to prod can require a manual approval.

In short: swap the static-nginx build for your language's build-and-test job, keep the same artifact contract (an image that listens on the container port the ECS task definition expects), and the entire scan -> push -> deploy -> promote machinery works unchanged.

---

## Checklist: onboarding a new language to the pipeline

- [ ] Add a `build-and-test-<lang>` job (or fold the steps into `build-and-scan`) using the correct `setup-*` action and lockfile-keyed cache.
- [ ] Pin a current language/runtime version and an LTS where one exists.
- [ ] Run unit tests with coverage and publish the coverage report.
- [ ] Add linter/formatter and static analysis steps and make them fail the build.
- [ ] Produce the build artifact (jar / wheel / dist / binary) or compile inside a multi-stage Dockerfile.
- [ ] Write a multi-stage Dockerfile: small/distroless or slim runtime base, **non-root** user, `EXPOSE` the right port, add a `HEALTHCHECK` or rely on the ECS/ALB health check.
- [ ] Confirm the container listens on the port the ECS task definition / target group expects.
- [ ] Add the ecosystem to SCA: native audit (`pip-audit`, `npm audit`, `govulncheck`, etc.) plus Trivy/Snyk on the image.
- [ ] Add a `package-ecosystem` entry in `.github/dependabot.yml` (and keep the `github-actions` ecosystem entry).
- [ ] Confirm Sonar (or your SAST) supports the language and the quality gate is wired.
- [ ] Verify the rest of the pipeline is untouched: OIDC role assumption, per-env ECR push, ECS deploy, and environment promotion all still work.
