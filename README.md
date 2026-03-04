# Tech Stack Demo: Node.js + MongoDB + Tekton + ArgoCD + Observability

This repository contains a sample Node.js app, MongoDB dependencies, and a full Kubernetes workflow:
- build/test/push with Tekton
- deploy/sync with ArgoCD
- metrics/logs/traces with Prometheus/Thanos, Loki, Tempo, Grafana
- security controls with External Secrets + Kyverno + Cosign signing/verification

## What You Get

- Local app runtime with Docker Compose
- Kubernetes manifests split by concern (`apps`, `platform`, `gitops`, `tekton`, `observability`, `security`)
- Automated scripts for install/start/stop/promote/rollback
- GitOps overlays for `dev`, `staging`, `prod`

## Repository Layout

- `app.js`, `server.js`, `logger.js`: app runtime and structured logging
- `tests/`: unit + integration tests
- `manifests/apps/`: app workloads (`sample-node-app`)
- `manifests/platform/`: shared platform workloads (`mongo`, `mongo-express`)
- `manifests/gitops/`: base + overlays (`dev|staging|prod`)
- `manifests/tekton/`: tasks, pipeline, triggers, RBAC, runs
- `manifests/observability/`: OTel, Prometheus+Thanos, Loki, Tempo, Grafana
- `manifests/security/`: External Secrets + Kyverno policy manifests
- `scripts/`: lifecycle and utility scripts
- `docs/`: walkthroughs and change logs

## Prerequisites

Install these tools first:
- `docker`
- `kubectl`
- `helm`
- `git`
- `curl`
- optional: `jq`, `tkn`, `cosign`

Cluster assumptions:
- Working Kubernetes context (Docker Desktop Kubernetes or kind/minikube)
- Network egress enabled for pulling container images/charts

## Quick Local App (No Kubernetes)

1. Create env file:
```bash
cp .env.example .env
```

2. Start app + mongodb + mongo-express:
```bash
./scripts/docker/docker-start.sh
```

3. Stop:
```bash
./scripts/docker/docker-stop.sh
```

4. Run tests:
```bash
./scripts/tests/tests.sh
```

## Full Kubernetes Setup (Recommended Order)

### 1) Install CRD prerequisites

```bash
./scripts/prerequisites.sh
```

Flags:
- `--skip-tekton`
- `--skip-argocd`
- `--skip-security`
- `--skip-deps-check`

### 2) Start Tekton

```bash
./scripts/k8s/start-tekton.sh
```

Important env vars:
- `TEKTON_NAMESPACE` (default `default`)
- `TEKTON_REPO_URL` (defaults to git origin)
- `TEKTON_IMAGE_REFERENCE` (default derived from app manifest)
- `RUN_SONARQUBE=true|false`
- `RUN_INTEGRATION_TESTS=true|false` (default `false`)
- `INTEGRATION_TESTS_STRICT=true|false` (default `false`)
- `ARGOCD_AUTO_DEPLOY=true|false` (default `true`)
- `ARGOCD_NAMESPACE` (default `argocd`)
- `ARGOCD_APP_NAME` (default `tech-stack`)
- `COSIGN_SIGN_ENABLED=true|false` (default `true`; requires `secret/cosign-key`)

Notes:
- Tekton now patches ArgoCD app image immediately after successful build (`sync-argocd-image` task).
- Tekton signs the pushed image (`cosign-sign`) before ArgoCD sync when `COSIGN_SIGN_ENABLED=true`.
- Default path is optimized for speed: integration tests are off unless enabled.

### 3) Start ArgoCD app flow

```bash
./scripts/k8s/start-argo.sh --revision main --env dev
```

Useful flags:
- `--install-argocd`
- `--no-wait`
- `--notify-webhook-url <url>`
- `--rollback-mode kubernetes|gitops`
- `--skip-path-preflight` (not recommended)

### 4) Start observability stack

```bash
./scripts/k8s/start-observability.sh
```

### 5) Start security stack

```bash
./scripts/k8s/start-security.sh
```

Defaults:
- Kyverno image registry defaults to `ghcr.io` for pull reliability.

Useful flags:
- `--audit-policy` (policy in audit mode)
- `--vault-auth-mode token|approle|jwt` (default `approle`)
- `--vault-addr`, `--vault-path`, `--vault-version`
- `--vault-token-namespace`, `--vault-token-secret`, `--vault-token-key`
- `--vault-approle-role-id`, `--vault-approle-secret`, `--vault-approle-secret-key`
- `--vault-jwt-path`, `--vault-jwt-role`
- `--cosign-public-key-file <path>`

Vault bootstrap helpers:
- `./scripts/k8s/vault-bootstrap-token.sh`
- `./scripts/k8s/vault-bootstrap-approle.sh`
- `./scripts/k8s/vault-bootstrap-jwt.sh`

## Port Forwarding

One script for all common endpoints:

```bash
./scripts/port-forwarding.sh all
```

Single target examples:
```bash
./scripts/port-forwarding.sh tekton 9097
./scripts/port-forwarding.sh argocd 8080
./scripts/port-forwarding.sh grafana 3000
./scripts/port-forwarding.sh app 3000
```

## Access URLs

- Tekton Dashboard: `http://localhost:9097`
- ArgoCD UI: `https://localhost:8080`
- Grafana: `http://localhost:3000`
- App: `http://localhost:3000`
- Mongo Express: `http://localhost:8081`

Get ArgoCD admin password:
```bash
./scripts/k8s/argocd-password.sh
```

## CI/CD Behavior

Pipeline key flow:
- clone source
- restore cache
- unit test
- optional integration test
- SCA scan
- optional SonarQube
- build + push image (kaniko)
- sign image (cosign, optional but enabled by default)
- patch ArgoCD app image + trigger sync
- summary notification

This means ArgoCD can deploy the new image immediately after Tekton build succeeds.
With signing enabled, ArgoCD sync runs only after the signature step succeeds.

## Pre-merge Policy Gates

GitHub Actions enforces:
- app CI (`lint`, `test`, `perf`, `audit`)
- policy gates:
  - `kustomize build` on GitOps overlays (`dev|staging|prod`) plus security/observability
  - `kubeconform` schema validation
  - `conftest` policy checks (`policy/conftest`)
  - `kyverno test` checks (`policy/kyverno`)

## GitOps Promotion and Rollback

Promote image tag between env overlays:
```bash
./scripts/k8s/promote.sh --from dev --to staging --approved --verify-push
./scripts/k8s/promote.sh --from staging --to prod --approved --verify-push
```

GitOps-native rollback:
```bash
./scripts/k8s/gitops-rollback.sh --env dev --push
```

## Observability Usage

- Metrics: Grafana datasource `Thanos`
- Logs: Grafana datasource `Loki`
- Traces: Grafana datasource `Tempo`

If logs are empty in Grafana, check:
- `promtail` pods running in `observability`
- app pods exist and produce stdout logs
- Loki datasource is healthy in Grafana

## Security Lifecycle

Start:
```bash
./scripts/k8s/start-security.sh
```

Stop:
```bash
./scripts/k8s/stop-security.sh
```

Full cleanup including namespaces:
```bash
./scripts/k8s/stop-security.sh --delete-namespaces --force
```

### Where Secrets Are Stored

- Source of truth: **Vault KV** (`kv/ci/*`) accessed through External Secrets Operator.
- In-cluster synced secrets:
  - `default/docker-credentials`
  - `default/sonarqube-credentials`
  - `default/cosign-key`
- Auth bootstrap secrets (depending on mode):
  - token mode: `external-secrets/vault-token`
  - approle mode: `external-secrets/vault-approle`
- Kyverno public key secret (optional helper): `kyverno/cosign-public-key`

Important:
- Kubernetes Secrets are runtime copies created by External Secrets; do not treat Git manifests as secret storage.
- For strict signed-image enforcement, provide a real cosign public key file to `start-security.sh`.

## Teardown / Cleanup

Stop Tekton + ArgoCD:
```bash
./scripts/k8s/k8s-stop.sh
```

Force cleanup of stuck Tekton PVC finalizers:
```bash
./scripts/k8s/k8s-stop.sh --force
```

Stop observability:
```bash
./scripts/k8s/stop-observability.sh
```

Delete failed Tekton runs quickly:
```bash
./scripts/k8s/cleanup-failed-tekton-pipelines.sh
```

## Troubleshooting

### ArgoCD shows `revision HEAD must be resolved`

Cause:
- app references a revision/path not present in remote git.

Fix:
```bash
git push origin main
./scripts/k8s/start-argo.sh --revision main --env dev
```

### Tekton run hangs/slow on tests

Use fast default path (integration off):
```bash
RUN_INTEGRATION_TESTS=false ./scripts/k8s/start-tekton.sh --skip-install
```

Enable integration only when needed:
```bash
RUN_INTEGRATION_TESTS=true INTEGRATION_TESTS_STRICT=true ./scripts/k8s/start-tekton.sh --skip-install
```

### Kyverno pods stuck `ImagePullBackOff`

Use stable registry override:
```bash
./scripts/k8s/start-security.sh --kyverno-image-registry ghcr.io
```

### prerequisites security conflict with Helm

`prerequisites.sh` applies security CRDs with server-side apply + force-conflicts to avoid both SSA manager conflicts and oversized annotation errors.

### New image fails with `ImagePullBackOff` after Tekton build

Cause:
- New local-registry tag is not yet available on cluster nodes.

Fix:
```bash
./scripts/k8s/registry-preload.sh --image host.docker.internal:5000/sample-node-app:<tag>
kubectl -n default rollout restart deployment/sample-node-app
kubectl -n default rollout status deployment/sample-node-app
```

## Script Catalog

All scripts support `--help`.

Docker:
- `./scripts/docker/docker-start.sh`
- `./scripts/docker/docker-stop.sh`

Core K8s:
- `./scripts/prerequisites.sh`
- `./scripts/port-forwarding.sh`

Tekton:
- `./scripts/k8s/start-tekton.sh`
- `./scripts/k8s/cleanup-failed-tekton-pipelines.sh`

ArgoCD/GitOps:
- `./scripts/k8s/start-argo.sh`
- `./scripts/k8s/promote.sh`
- `./scripts/k8s/gitops-rollback.sh`
- `./scripts/k8s/argocd-password.sh`

Observability:
- `./scripts/k8s/start-observability.sh`
- `./scripts/k8s/stop-observability.sh`

Security:
- `./scripts/k8s/start-security.sh`
- `./scripts/k8s/stop-security.sh`
- `./scripts/k8s/sign-image.sh`
- `./scripts/k8s/vault-bootstrap-token.sh`
- `./scripts/k8s/vault-bootstrap-approle.sh`
- `./scripts/k8s/vault-bootstrap-jwt.sh`

Global teardown/status:
- `./scripts/k8s/k8s-stop.sh`
- `./scripts/k8s/cicd-status.sh`
