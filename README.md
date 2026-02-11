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
- `scripts/start.sh`, `scripts/stop.sh`, `scripts/tests.sh`

CI/CD:

- Tekton Pipelines + Tekton Triggers (manifests in `manifests/tekton/`)
- Trivy SCA scan task (in-repo)
- SonarQube scan task (in-repo, optional via pipeline param)
- ArgoCD deployment helper (`scripts/argocd.sh`) with image auto-selection

## Repo Layout

- `app.js`: Express app factory (routes, HTML escaping, validation)
- `server.js`: runtime entrypoint (Mongo connection + listen)
- `models/`: Mongoose schemas
- `views/`: HTML templates (`register.html`, `profile.html`)
- `public/`: static assets (CSS)
- `tests/`: Node-native tests (`node --test ...`)
- `perf/`: lightweight perf check (`npm run perf`)
- `manifests/`: Kubernetes and Tekton YAML (see `manifests/README.md`)
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
./scripts/start.sh
```

3. Open services

- App: `http://localhost:3000`
- Mongo Express: `http://localhost:8081`

4. Stop the stack

```bash
./scripts/stop.sh
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

Run the lightweight perf micro-benchmark:

```bash
npm run perf
```

Or run the project checks via script:

```bash
./scripts/tests.sh
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
./scripts/tekton.sh
```

Required for registry push:

- A valid Docker login config at `$HOME/.docker/config.json` (or set `DOCKER_CONFIG_JSON` to another path).

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
./scripts/argocd.sh --repo-url <your-repo-url>
```

Image selection priority:

- `--image <ref>`
- `IMAGE_REFERENCE` env var
- latest successful Tekton `PipelineRun` param `image-reference`
- fallback to `manifests/k8s/node-app/deployment.yaml` image

Useful flags:

- `--install-argocd`: installs ArgoCD in `argocd` namespace before applying the app
- `--dest-namespace <name>`: target namespace for workloads
- `--revision <branch|tag|sha>`: Git revision for ArgoCD source
- `--no-wait`: skip rollout wait

Default ArgoCD app path is `manifests/k8s`, which now includes a `kustomization.yaml` so image overrides are applied cleanly.

ArgoCD Web UI access:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; echo
```

Then open `https://localhost:8080` and log in as `admin`.

## Security Notes (Important)

- Do not commit real credentials. `.env` is ignored by git.
- The Tekton secret manifests under `manifests/tekton/secrets/` contain placeholders and are not safe to commit with real values.

## Scripts

- `./scripts/start.sh`: brings up Docker Compose (`up --build`)
- `./scripts/stop.sh`: brings down Docker Compose (`down`)
- `./scripts/tests.sh`: runs `npm test` and `npm run perf`
- `./scripts/tekton.sh`: automates Tekton install + manifests + secret setup
- `./scripts/argocd.sh`: picks image, creates/updates ArgoCD `Application`, and deploys to cluster
