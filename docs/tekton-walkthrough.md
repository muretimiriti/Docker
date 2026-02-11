# Tekton Walkthrough (Pipeline + Triggers)

This document shows how to apply the Tekton manifests in this repo, what secrets you need, and how to run the pipeline either manually or via Triggers/EventListener.

## What You Get

- A Tekton Pipeline that:
  - clones the repo
  - runs `npm test`
  - runs Trivy SCA scan on the source tree
  - optionally runs SonarQube scan (gated by param)
  - builds/pushes an image using Kaniko
- Triggers that can create `PipelineRun`s on webhook events
- A persistent cache PVC for npm/trivy/sonar caches

Manifests live under `manifests/tekton/`.

## Prerequisites

- Kubernetes cluster (Minikube, Kind, EKS, etc.)
- Tekton Pipelines installed (CRDs + controllers)
- Tekton Triggers installed (if you want webhooks)
- A container registry account to push images to (Docker Hub, ECR, GCR, etc.)

## 1) Apply RBAC

```bash
kubectl apply -f manifests/tekton/rbac/rbac.yaml
```

## 2) Create Secrets

### 2.1 Docker registry credentials (required for Kaniko push)

Kaniko expects a Docker `config.json` containing auth.

Create a secret named `docker-credentials` with a key `config.json`:

```bash
kubectl create secret generic docker-credentials \
  --from-file=config.json=$HOME/.docker/config.json
```

The repo also includes a placeholder manifest at:

- `manifests/tekton/secrets/docker-credentials.yaml`

Do not commit real credentials to git.

### 2.2 SonarQube credentials (optional)

Only required if you set the pipeline param `run-sonarqube=true`.

Create:

```bash
kubectl create secret generic sonarqube-credentials \
  --from-literal=SONAR_HOST_URL="https://your-sonarqube-host" \
  --from-literal=SONAR_TOKEN="your-token"
```

## 3) Create PVCs (Cache)

```bash
kubectl apply -f manifests/tekton/pvc/cache-pvc.yaml
```

This provides a persistent cache across `PipelineRun`s:

- npm cache (`/workspace/cache/npm`)
- trivy cache (`/workspace/cache/trivy`)
- sonar cache (`/workspace/cache/sonar`)

## 4) Apply Tasks (Vendored)

These tasks are included in-repo so the pipeline doesn't rely on cluster catalog versions.

```bash
kubectl apply -f manifests/tekton/tasks/
```

Key tasks:

- `git-clone` (`manifests/tekton/tasks/git-clone.yaml`)
- `npm-test` (`manifests/tekton/tasks/npm-test.yaml`)
- `trivy-sca-scan` (`manifests/tekton/tasks/trivy-sca-scan.yaml`)
- `sonarqube-scan` (`manifests/tekton/tasks/sonarqube-scan.yaml`)
- `kaniko` (`manifests/tekton/tasks/kaniko.yaml`)
- `show-readme` (`manifests/tekton/tasks/show-readme.yaml`)

## 5) Apply the Pipeline

```bash
kubectl apply -f manifests/tekton/pipeline/pipeline.yaml
```

## 6) Run Manually (PipelineRun)

Edit `manifests/tekton/runs/pipelinerun.yaml`:

- set `spec.params.repo-url`
- set `spec.params.image-reference`
- optionally set `spec.params.run-sonarqube: "true"`

Apply:

```bash
kubectl apply -f manifests/tekton/runs/pipelinerun.yaml
```

## 7) Run via Triggers (EventListener)

### 7.1 Apply triggers

```bash
kubectl apply -f manifests/tekton/triggers/trigger-binding.yaml
kubectl apply -f manifests/tekton/triggers/trigger-template.yaml
kubectl apply -f manifests/tekton/triggers/event-listener.yaml
```

### 7.2 Expose the EventListener

For local clusters you can port-forward:

```bash
kubectl port-forward svc/el-event-listener 8080:8080
```

Then configure a webhook pointing to:

- `http://<your-host>:8080`

### 7.3 Manual trigger (curl)

If you want to manually test without GitHub:

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"repository":{"clone_url":"https://github.com/REPLACE_ME/REPLACE_ME.git"},"after":"local"}'
```

## Notes

- The pipeline uses `serviceAccountName: tekton-triggers-sa` in the `PipelineRun` specs.
- For real production use, do not keep secret manifests in git; use external secrets or sealed secrets.

## Access Tekton Tools

### Tekton Dashboard UI

If Tekton Dashboard is installed, port-forward and open it locally:

```bash
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097
```

Open:

- `http://localhost:9097`

### Tekton Triggers EventListener Endpoint

To reach the EventListener webhook endpoint locally:

```bash
kubectl -n default port-forward svc/el-event-listener 8080:8080
```

Then use:

- `http://localhost:8080`
