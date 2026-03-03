# CI/CD Hardening Playbook

## 1) Reliable Tekton Runs

`manifests/tekton/pipeline/pipeline.yaml` now includes:
- task retries for clone/test/scan/build
- finally notification step (`notification-webhook-url` param)

`scripts/k8s/start-tekton.sh` now includes:
- retry wrappers for remote Tekton install/apply operations
- PipelineRun timeouts (`pipeline/tasks/finally`)
- optional `NOTIFICATION_WEBHOOK_URL`

## 2) Reliable Argo Deploy

`scripts/k8s/start-argo.sh` now includes:
- optional `--notify-webhook-url`
- clear failure extraction from Argo Application status
- optional `--env dev|staging|prod` to load deployment defaults

## 3) Promotion Flow (dev -> staging -> prod)

Environment files:
- `manifests/environments/dev.env`
- `manifests/environments/staging.env`
- `manifests/environments/prod.env`

Promote image tag:

```bash
./scripts/k8s/promote.sh --from dev --to staging
./scripts/k8s/promote.sh --from staging --to prod
```

Deploy env:

```bash
./scripts/k8s/start-argo.sh --env staging
./scripts/k8s/start-argo.sh --env prod
```

Promotion governance:
- `scripts/k8s/promote.sh` now supports:
  - `--verify-push` (ensures local branch is pushed before updating overlays)
  - required approval for `staging` and `prod` (`--approved`)
  - prechecks for latest Tekton success + smoke probe against source env

## 4) Security Scaffolding

- External Secrets examples: `manifests/security/external-secrets/`
- Cosign policy example (Kyverno): `manifests/security/kyverno/`
- Image signing helper: `./scripts/k8s/sign-image.sh --image <ref> --key <key-ref>`

Enforced security path:
- `./scripts/k8s/start-security.sh` installs External Secrets Operator + Kyverno
- applies `manifests/security` resources with Vault backend settings
- applies Kyverno cosign verification policy in `Enforce` mode by default (`--audit-policy` for audit)

## 5) Health Summary

Use:

```bash
./scripts/k8s/cicd-status.sh
```

Optional webhook:

```bash
./scripts/k8s/cicd-status.sh --webhook-url https://example/hooks/cicd
```

## 6) GitOps Rollback

Use GitOps-native rollback (revert commit + refresh Argo) instead of `kubectl rollout undo`:

```bash
./scripts/k8s/gitops-rollback.sh --env dev --push
```
