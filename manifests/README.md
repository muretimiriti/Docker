# Manifests

All Kubernetes and Tekton YAML lives under `manifests/`:

- `manifests/k8s/`: runtime workloads (mongo, mongo-express, node-app)
- `manifests/tekton/`: CI pipeline, triggers, tasks, RBAC, and PVCs

## Apply Order (Typical)

Tekton prerequisites (namespaces/CRDs assumed installed already):

1. `manifests/tekton/rbac/rbac.yaml`
2. Secrets (replace placeholders, do not commit real values):
   - `manifests/tekton/secrets/docker-credentials.yaml`
   - `manifests/tekton/secrets/git-ssh-secret.yaml`
3. PVCs:
   - `manifests/tekton/pvc/cache-pvc.yaml`
4. Tasks:
   - `manifests/tekton/tasks/*.yaml`
5. Pipeline:
   - `manifests/tekton/pipeline/pipeline.yaml`
6. Triggers:
   - `manifests/tekton/triggers/trigger-binding.yaml`
   - `manifests/tekton/triggers/trigger-template.yaml`
   - `manifests/tekton/triggers/event-listener.yaml`

Manual run (example):

- `manifests/tekton/runs/pipelinerun.yaml`

Runtime workloads:

- `manifests/k8s/**`

## Tekton Walkthrough

See `docs/tekton-walkthrough.md` for a step-by-step guide (secrets, PVC, manual runs, triggers/webhooks).
