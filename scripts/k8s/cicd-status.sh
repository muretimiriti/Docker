#!/bin/bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-tech-stack}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/cicd-status.sh [options]

Checks the latest Tekton PipelineRun and ArgoCD Application status and prints a concise summary.
Optionally sends the summary to a webhook.

Options:
  --namespace <ns>          Tekton workload namespace (default: default)
  --argocd-namespace <ns>   ArgoCD namespace (default: argocd)
  --app <name>              ArgoCD app name (default: tech-stack)
  --webhook-url <url>       Optional webhook URL for status notification
  -h, --help                Show this help
USAGE
}

log() {
  echo "[cicd-status] $*"
}

die() {
  echo "[cicd-status] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"
      shift 2
      ;;
    --argocd-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --argocd-namespace"
      ARGOCD_NAMESPACE="$2"
      shift 2
      ;;
    --app)
      [[ $# -ge 2 ]] || die "Missing value for --app"
      APP_NAME="$2"
      shift 2
      ;;
    --webhook-url)
      [[ $# -ge 2 ]] || die "Missing value for --webhook-url"
      WEBHOOK_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

latest_run="$(kubectl -n "$NAMESPACE" get pipelineruns.tekton.dev --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
run_status="unknown"
run_message=""
if [[ -n "$latest_run" ]]; then
  run_status="$(kubectl -n "$NAMESPACE" get pipelinerun "$latest_run" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || true)"
  run_message="$(kubectl -n "$NAMESPACE" get pipelinerun "$latest_run" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' 2>/dev/null || true)"
fi

argo_sync="unknown"
argo_health="unknown"
argo_message=""
if kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" >/dev/null 2>&1; then
  argo_sync="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  argo_health="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  argo_message="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
fi

summary="tekton_run=${latest_run:-none};tekton_status=${run_status:-unknown};argocd_sync=${argo_sync:-unknown};argocd_health=${argo_health:-unknown}"
log "$summary"
[[ -n "$run_message" ]] && log "tekton_message=$run_message"
[[ -n "$argo_message" ]] && log "argocd_message=$argo_message"

if [[ -n "$WEBHOOK_URL" ]] && command -v curl >/dev/null 2>&1; then
  payload="$(cat <<JSON
{"summary":"$summary","tektonRun":"${latest_run:-}","tektonStatus":"${run_status:-}","tektonMessage":"${run_message:-}","argocdSync":"${argo_sync:-}","argocdHealth":"${argo_health:-}","argocdMessage":"${argo_message:-}"}
JSON
)"
  curl -fsS -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" -d "$payload" >/dev/null || true
fi
