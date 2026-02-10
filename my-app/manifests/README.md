# Manifests

All Kubernetes and Tekton YAML lives under `my-app/manifests/`:

- `my-app/manifests/k8s/`: runtime workloads (mongo, mongo-express, node-app)
- `my-app/manifests/tekton/`: CI pipeline, triggers, tasks, RBAC, and PVCs

## Apply Order (Typical)

Tekton prerequisites (namespaces/CRDs assumed installed already):

1. `my-app/manifests/tekton/rbac/rbac.yaml`
2. Secrets (replace placeholders, do not commit real values):
   - `my-app/manifests/tekton/secrets/docker-credentials.yaml`
   - `my-app/manifests/tekton/secrets/git-ssh-secret.yaml`
3. PVCs:
   - `my-app/manifests/tekton/pvc/cache-pvc.yaml`
4. Tasks:
   - `my-app/manifests/tekton/tasks/*.yaml`
5. Pipeline:
   - `my-app/manifests/tekton/pipeline/pipeline.yaml`
6. Triggers:
   - `my-app/manifests/tekton/triggers/trigger-binding.yaml`
   - `my-app/manifests/tekton/triggers/trigger-template.yaml`
   - `my-app/manifests/tekton/triggers/event-listener.yaml`

Manual run (example):

- `my-app/manifests/tekton/runs/pipelinerun.yaml`

Runtime workloads:

- `my-app/manifests/k8s/**`

