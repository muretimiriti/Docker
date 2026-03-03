# Tech Stack Demo: Node.js + MongoDB + Docker + Tekton

This repository contains a small Express app backed by MongoDB, plus Docker Compose for local development and Tekton manifests for CI-style pipelines (clone, test, scan, build/push).

## Tech Stack

Application:

- Node.js (containerized)
- Express (HTTP server)
- Mongoose (MongoDB ODM)
- HTML templates served as static files (simple string substitution)

Data:

- MongoDB
- mongo-express (optional UI)

Local Dev / Packaging:

- Docker + Docker Compose
- `scripts/docker/docker-start.sh`, `scripts/docker/docker-stop.sh`, `scripts/tests/tests.sh`

CI/CD:

- Tekton Pipelines + Tekton Triggers (manifests in `manifests/tekton/`)
- Trivy SCA scan task (in-repo)
- Mongo integration-test gate before image build/push
- SonarQube scan task (in-repo, optional via pipeline param)
- ArgoCD deployment helper (`scripts/k8s/start-argo.sh`) with image auto-selection, smoke test, and optional auto-rollback
- Observability stack (`manifests/observability/`): OTel, Prometheus+Thanos, Loki, Tempo, Grafana

## Repo Layout

- `app.js`: Express app factory (routes, HTML escaping, validation)
- `server.js`: runtime entrypoint (Mongo connection + listen)
- `logger.js`: JSON structured logging with OTel trace IDs
- `models/`: Mongoose schemas
- `views/`: HTML templates (`register.html`, `profile.html`)
- `public/`: static assets (CSS)
- `tests/`: Node-native tests (`node --test ...`)
- `perf/`: lightweight perf check (`npm run perf`)
- `manifests/`: Kubernetes and Tekton YAML (see `manifests/README.md`)
- `manifests/environments/`: promotion config for `dev`, `staging`, `prod`
- `manifests/apps/`: app workloads (`sample-node-app`)
- `manifests/platform/`: platform workloads (`mongo`, `mongo-express`)
- `manifests/gitops/`: base + env overlays for ArgoCD
- `scripts/`: helper scripts to run and stop the stack

## Prerequisites

Local development:

- Docker Desktop (or Docker Engine)
- Docker Compose (either `docker compose` or legacy `docker-compose`)

Optional (non-Docker local run):

- Node.js + npm
- A reachable MongoDB instance

## Quickstart (Recommended): Docker Compose

1. Configure environment

- Copy `.env.example` to `.env` and adjust values as needed.

2. Start the stack

```bash
./scripts/docker/docker-start.sh
```

3. Open services

- App: `http://localhost:3000`
- Mongo Express: `http://localhost:8081`

4. Stop the stack.

```bash
./scripts/docker/docker-stop.sh
```

### Production-like Compose (Optional)

The compose file includes a production-like profile that runs the app without bind-mounts:

```bash
docker compose --profile prod up --build
```

## Run Without Docker (Optional)

Set `MONGO_URI` to a reachable MongoDB and run:

```bash
npm install
npm start
```

## Tests And Checks

Run unit/integration-style handler tests (no Mongo required):

```bash
npm test
```

Run Mongo integration tests:

```bash
npm run test:integration
```

Run the lightweight perf micro-benchmark:

```bash
npm run perf
```

Or run the project checks via script:

```bash
./scripts/tests/tests.sh
```

## Linting And Formatting

Lint:

```bash
npm run lint
```

Format:

```bash
npm run format
```

Format check:

```bash
npm run format:check
```

## Environment Variables

Primary variables:

- `PORT`: app port (default `3000`)
- `MONGO_URI`: Mongo connection string (required)

Optional update auth (recommended if you expose this publicly):

- `UPDATE_BASIC_AUTH_USER`
- `UPDATE_BASIC_AUTH_PASS`

Mongo init variables (used by the Mongo container in Compose):

- `MONGO_INITDB_ROOT_USERNAME`
- `MONGO_INITDB_ROOT_PASSWORD`
- `MONGO_INITDB_DATABASE`

mongo-express variables:

- `MONGO_EXPRESS_PORT` (default `8081`)
- `ME_CONFIG_MONGODB_URL` (defaults to a URL built from the Mongo init vars)
- `ME_CONFIG_BASICAUTH` (defaults to `false`)

See `.env.example` for the full list and defaults.

## Tekton / Kubernetes Manifests

All Kubernetes and Tekton YAML files are organized under `manifests/`.

- Apply order and notes: `manifests/README.md`
- Tekton pipeline: `manifests/tekton/pipeline/pipeline.yaml`
- Tekton triggers: `manifests/tekton/triggers/`
- Tekton tasks (in-repo): `manifests/tekton/tasks/`
- Walkthrough: `docs/tekton-walkthrough.md`

### Automated Tekton Setup

Use the setup script to install Tekton (pipelines/triggers/dashboard), create required secrets, and apply all Tekton manifests:

```bash
./scripts/k8s/start-tekton.sh
```

Required for registry push:

- A valid Docker login config at `$HOME/.docker/config.json` (or set `DOCKER_CONFIG_JSON` to another path).
- Default local registry flow uses `host.docker.internal:5000/sample-node-app`.
- Use `./scripts/k8s/registry-preload.sh --image host.docker.internal:5000/sample-node-app:<tag>` for Docker Desktop/kind preload.

Optional inputs:

- `SONAR_HOST_URL` + `SONAR_TOKEN` to create `sonarqube-credentials`
- `SSH_PRIVATE_KEY_PATH` + `SSH_KNOWN_HOSTS_PATH` to create `ssh-key` (for private SSH git clones)
- `TEKTON_NAMESPACE` to target a non-default namespace

Useful flags:

- `--skip-install`: skip Tekton Pipelines/Triggers/Dashboard install (if already installed)
- `--skip-dashboard`: skip Tekton Dashboard UI install
- `--skip-triggers`: skip trigger manifests
- `--namespace <name>`: override namespace for this run

Tekton Dashboard UI (if installed):

```bash
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097
```

Then open `http://localhost:9097`.

### SonarQube (Optional)

The SonarQube scan task is gated behind the pipeline param `run-sonarqube=true`.

It expects a secret named `sonarqube-credentials` with:

- `SONAR_HOST_URL`
- `SONAR_TOKEN`

If the secret is missing, the task will skip (so the pipeline still runs).

### ArgoCD Deploy (Image Pick + Cluster Deploy)

Use the ArgoCD script to select an image and deploy using a GitOps `Application`:

```bash
./scripts/k8s/start-argo.sh --repo-url <your-repo-url>
```

Environment deploy (promotion-aware):

```bash
./scripts/k8s/start-argo.sh --env dev
./scripts/k8s/start-argo.sh --env staging
./scripts/k8s/start-argo.sh --env prod
```

Image selection priority:

- `--image <ref>`
- `IMAGE_REFERENCE` env var
- latest successful Tekton `build-push` TaskRun result `IMAGE_URL` (tagged image)
- fallback to latest successful Tekton `PipelineRun` param `image-reference`
- fallback to `manifests/apps/sample-node-app/deployment.yaml` image

Useful flags:

- `--install-argocd`: installs ArgoCD in `argocd` namespace before applying the app
- `--dest-namespace <name>`: target namespace for workloads
- `--revision <branch|tag|sha>`: Git revision for ArgoCD source
- `--no-wait`: skip rollout wait
- `--notify-webhook-url <url>`: send deploy success/failure notifications
- `--env <dev|staging|prod>`: deploy from `manifests/gitops/overlays/<env>` and load defaults from `manifests/environments/<env>.env`
- `--smoke-path <path>`: post-deploy smoke check path (default `/healthz`)
- `--skip-smoke`: disable post-deploy smoke check
- `--no-auto-rollback`: disable rollback when rollout/smoke fails
- `--rollback-mode gitops`: disables `rollout undo` and expects GitOps rollback flow
- `--skip-path-preflight`: bypass remote revision/path check (not recommended)

Default ArgoCD app path is `manifests/gitops/overlays/dev`.

Promotion command:

```bash
./scripts/k8s/promote.sh --from dev --to staging
./scripts/k8s/promote.sh --from staging --to prod
```

Guarded promotion (checks + approval + pushed branch verification):

```bash
./scripts/k8s/promote.sh --from dev --to staging --verify-push --approved
./scripts/k8s/promote.sh --from staging --to prod --verify-push --approved
```

GitOps-native rollback:

```bash
./scripts/k8s/gitops-rollback.sh --env dev --push
```

ArgoCD Web UI access:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; echo
```

Then open `https://localhost:8080` and log in as `admin`.

### Observability (OTel + Thanos + Loki + Grafana)

Start the observability stack:

```bash
./scripts/k8s/start-observability.sh
```

Then open Grafana:

```bash
./scripts/port-forwarding.sh grafana 3000
```

Open `http://localhost:3000`.

Provisioned Grafana datasources:

- `Thanos` (metrics)
- `Loki` (logs)
- `Tempo` (traces)

Default Grafana credentials:

- user: `admin`
- password: `admin`

## Security Notes (Important)

- Do not commit real credentials. `.env` is ignored by git.
- The Tekton secret manifests under `manifests/tekton/secrets/` contain placeholders and are not safe to commit with real values.
- Security manifests are under `manifests/security/`.
- Install and enforce ESO + Kyverno + cosign verification with:

```bash
./scripts/k8s/start-security.sh \
  --vault-addr https://vault.example.com \
  --vault-token-namespace external-secrets \
  --vault-token-secret vault-token \
  --cosign-public-key-file ./cosign.pub
```

- Use `--audit-policy` if you want policy in audit mode; default is enforce mode.

## Scripts

- `./scripts/docker/docker-start.sh`: brings up Docker Compose (`up --build`)
- `./scripts/docker/docker-stop.sh`: brings down Docker Compose (`down`)
- `./scripts/tests/tests.sh`: runs `npm test`, `npm run test:integration`, and `npm run perf`
- `./scripts/k8s/start-tekton.sh`: automates Tekton install + manifests + secret setup
- `./scripts/k8s/start-argo.sh`: picks image, creates/updates ArgoCD `Application`, and deploys to cluster
- `./scripts/k8s/promote.sh`: promotes image tags between `dev -> staging -> prod` environment configs
- `./scripts/k8s/gitops-rollback.sh`: GitOps-native rollback (revert + optional push + Argo refresh)
- `./scripts/k8s/cicd-status.sh`: prints Tekton + ArgoCD health summary and can notify a webhook
- `./scripts/k8s/sign-image.sh`: signs container images with Cosign
- `./scripts/k8s/start-security.sh`: installs External Secrets + Kyverno and applies enforceable security manifests
- `./scripts/k8s/registry-preload.sh`: preloads local images into Docker Desktop/kind nodes
- `./scripts/k8s/registry-retention.sh`: prunes old local registry tags while keeping newest N
- `./scripts/k8s/start-observability.sh`: deploys OTel, Prometheus+Thanos, Loki, Tempo, and Grafana
- `./scripts/k8s/start-helm-app.sh`: deploys sample-node-app with Helm values (`dev|staging|prod`)
