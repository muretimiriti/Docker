# Status (This Branch)

Updated on 2026-02-10.

## App Changes

- Stored XSS mitigated by escaping user-controlled fields when rendering `profile.html` (`my-app/app.js`).
- Added basic request validation (rejects invalid ObjectIds and missing required fields).
- Update route runs validators for Mongoose updates (`runValidators: true`).
- Added `/healthz`.
- Split runtime entrypoint from app construction (`my-app/server.js` uses `my-app/app.js`) to make testing easier.

## Testing And Performance

- Tests are runnable via `npm test` (Node-native `node:test` based tests).
- Added a lightweight performance micro-benchmark via `npm run perf` (template render/escape hot path).

## Docker / Compose

- Docker Compose env wiring uses `.env` interpolation and `env_file`.
- `.env` should not be committed; `my-app/.env.example` is provided as a template.
- Dockerfile runs `node server.js` (production-friendly) and local dev uses `npm run dev` (nodemon).

## Tekton / CI

- EventListener manifest is valid (`spec.triggers` structure fixed) in `my-app/manifests/tekton/triggers/event-listener.yaml`.
- PipelineRun now references the existing pipeline in `my-app/manifests/tekton/runs/pipelinerun.yaml`.
- `show-readme` task prints the repository README in `my-app/manifests/tekton/tasks/show-readme.yaml` and is invoked from `my-app/manifests/tekton/pipeline/pipeline.yaml`.
- Added in-repo tasks:
  - Trivy SCA scan: `my-app/manifests/tekton/tasks/trivy-sca-scan.yaml`
  - Node tests: `my-app/manifests/tekton/tasks/npm-test.yaml`
  - SonarQube scan (optional): `my-app/manifests/tekton/tasks/sonarqube-scan.yaml` (enabled with pipeline param `run-sonarqube=true`)
- Added cross-run cache support:
  - Cache PVC manifest: `my-app/manifests/tekton/pvc/cache-pvc.yaml` (`tekton-cache-pvc`)
  - Pipeline, TriggerTemplate, and manual PipelineRun mount the `cache` workspace.
- Triggered and manual PipelineRuns now set `serviceAccountName: tekton-triggers-sa`.
