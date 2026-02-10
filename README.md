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

## Environment Variables

Primary variables:

- `PORT`: app port (default `3000`)
- `MONGO_URI`: Mongo connection string (required)

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

### SonarQube (Optional)

The SonarQube scan task is gated behind the pipeline param `run-sonarqube=true`.

It expects a secret named `sonarqube-credentials` with:

- `SONAR_HOST_URL`
- `SONAR_TOKEN`

If the secret is missing, the task will skip (so the pipeline still runs).

## Security Notes (Important)

- Do not commit real credentials. `.env` is ignored by git.
- The Tekton secret manifests under `manifests/tekton/secrets/` contain placeholders and are not safe to commit with real values.

## Scripts

- `./scripts/start.sh`: brings up Docker Compose (`up --build`)
- `./scripts/stop.sh`: brings down Docker Compose (`down`)
- `./scripts/tests.sh`: runs `npm test` and `npm run perf`

