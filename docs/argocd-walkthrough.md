# ArgoCD Walkthrough (Image Pick + Deploy)

This document shows how to deploy this repo to Kubernetes with ArgoCD using the helper script in `scripts/argocd.sh`.

The script can:

- create/update an ArgoCD `Application`
- pick an image automatically
- deploy workloads from `manifests/k8s/`
- wait for rollout of `my-node-app`

## Prerequisites

- Kubernetes cluster reachable via `kubectl`
- A Git repo URL ArgoCD can access (HTTPS or SSH)
- ArgoCD installed, or allow the script to install it with `--install-argocd`
- A valid container image for the Node app

Optional but recommended:

- Tekton pipeline runs available in your cluster so the script can auto-pick the latest successful `image-reference`

## Image Selection Logic

The script resolves the deploy image in this order:

1. `--image <ref>`
2. `IMAGE_REFERENCE` environment variable
3. latest successful Tekton `PipelineRun` param `image-reference`
4. fallback image in `manifests/k8s/node-app/deployment.yaml`

## 1) Basic Deploy

Run:

```bash
./scripts/argocd.sh --repo-url <your-repo-url>
```

If ArgoCD is not installed yet:

```bash
./scripts/argocd.sh --repo-url <your-repo-url> --install-argocd
```

## 2) Deploy A Specific Image

```bash
./scripts/argocd.sh \
  --repo-url <your-repo-url> \
  --image ghcr.io/<org>/<repo>:<tag>
```

Equivalent environment variable:

```bash
IMAGE_REFERENCE=ghcr.io/<org>/<repo>:<tag> \
./scripts/argocd.sh --repo-url <your-repo-url>
```

## 3) Common Options

- `--revision <branch|tag|sha>`: Git revision ArgoCD should track
- `--path <repo-path>`: source path inside repo (default: `manifests/k8s`)
- `--dest-namespace <ns>`: workload namespace (default: `default`)
- `--app-name <name>`: ArgoCD application name (default: `tech-stack`)
- `--argocd-namespace <ns>`: ArgoCD control namespace (default: `argocd`)
- `--no-sync`: disable automated sync policy
- `--no-wait`: skip rollout wait
- `--wait-timeout <dur>`: rollout timeout (default: `180s`)

## 4) Verify Deployment

Check application resource:

```bash
kubectl -n argocd get applications.argoproj.io
kubectl -n argocd get application tech-stack -o yaml
```

Check workloads:

```bash
kubectl -n default get deploy,svc,pods
kubectl -n default rollout status deployment/my-node-app
```

Check final image in deployment:

```bash
kubectl -n default get deployment my-node-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

## 5) Notes About Manifests

- ArgoCD points to `manifests/k8s/`.
- `manifests/k8s/kustomization.yaml` is used so image overrides are applied through kustomize.
- The script sets image override in the ArgoCD `Application.spec.source.kustomize.images` field.

## Troubleshooting

- `applications.argoproj.io not found`:
  - install ArgoCD first, or rerun with `--install-argocd`
- Image not found/pull errors:
  - verify registry credentials in the cluster and image tag correctness
- No Tekton image discovered:
  - pass `--image` explicitly or set `IMAGE_REFERENCE`
- App not syncing:
  - inspect the ArgoCD application events:

```bash
kubectl -n argocd describe application tech-stack
```

## Access ArgoCD Tools

### ArgoCD Web UI

Port-forward the ArgoCD API/UI service:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open:

- `https://localhost:8080`

Default login:

- username: `admin`
- password command:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

### ArgoCD Application Status via kubectl

```bash
kubectl -n argocd get applications.argoproj.io
kubectl -n argocd get application tech-stack -o yaml
```
