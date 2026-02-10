# Status (This Branch)

Updated on 2026-02-10.

## App Changes

- Stored XSS mitigated by escaping user-controlled fields when rendering `profile.html` (`app.js`).
- Added basic request validation (rejects invalid ObjectIds and missing required fields).
- Update route runs validators for Mongoose updates (`runValidators: true`).
- Added `/healthz`.
- Split runtime entrypoint from app construction (`server.js` uses `app.js`) to make testing easier.

## Testing And Performance

- Tests are runnable via `npm test` (Node-native `node:test` based tests).
- Added a lightweight performance micro-benchmark via `npm run perf` (template render/escape hot path).

## Docker / Compose

- Docker Compose env wiring uses `.env` interpolation and `env_file`.
- `.env` should not be committed; `.env.example` is provided as a template.
- Dockerfile runs `node server.js` (production-friendly) and local dev uses `npm run dev` (nodemon).

## Tekton / CI

- EventListener manifest is valid (`spec.triggers` structure fixed) in `manifests/tekton/triggers/event-listener.yaml`.
- PipelineRun now references the existing pipeline in `manifests/tekton/runs/pipelinerun.yaml`.
- `show-readme` task prints the repository README in `manifests/tekton/tasks/show-readme.yaml` and is invoked from `manifests/tekton/pipeline/pipeline.yaml`.
- Added in-repo tasks:
  - Trivy SCA scan: `manifests/tekton/tasks/trivy-sca-scan.yaml`
  - Node tests: `manifests/tekton/tasks/npm-test.yaml`
  - SonarQube scan (optional): `manifests/tekton/tasks/sonarqube-scan.yaml` (enabled with pipeline param `run-sonarqube=true`)
- Added cross-run cache support:
  - Cache PVC manifest: `manifests/tekton/pvc/cache-pvc.yaml` (`tekton-cache-pvc`)
  - Pipeline, TriggerTemplate, and manual PipelineRun mount the `cache` workspace.
- Triggered and manual PipelineRuns now set `serviceAccountName: tekton-triggers-sa`.
