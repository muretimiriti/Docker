#!/bin/bash
set -euo pipefail

NAMESPACE="${TEKTON_NAMESPACE:-default}"
DRY_RUN="false"

usage() {
  cat <<USAGE
Usage: ./scripts/k8s/cleanup-failed-tekton-pipelines.sh [options]

Deletes failed Tekton PipelineRuns and their related TaskRuns/Pods.

Options:
  --namespace <name>   Namespace to target (default: TEKTON_NAMESPACE or default)
  --dry-run            Print what would be deleted without deleting
  -h, --help           Show this help
USAGE
}

log() {
  echo "[tekton-cleanup] $*"
}

die() {
  echo "[tekton-cleanup] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
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

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  die "Namespace not found: $NAMESPACE"
fi

failed_runs="$(kubectl -n "$NAMESPACE" get pipelineruns.tekton.dev \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].status,REASON:.status.conditions[0].reason \
  --no-headers 2>/dev/null | awk '$2 == "False" {print $1}')"

if [[ -z "$failed_runs" ]]; then
  log "No failed PipelineRuns found in namespace $NAMESPACE"
  exit 0
fi

count="$(echo "$failed_runs" | wc -l | tr -d ' ')"
log "Found $count failed PipelineRun(s) in namespace $NAMESPACE"

while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue

  log "Cleaning PipelineRun: $pr"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] kubectl -n $NAMESPACE delete taskrun -l tekton.dev/pipelineRun=$pr"
    log "[dry-run] kubectl -n $NAMESPACE delete pod -l tekton.dev/pipelineRun=$pr"
    log "[dry-run] kubectl -n $NAMESPACE delete pipelinerun $pr"
  else
    kubectl -n "$NAMESPACE" delete taskrun -l "tekton.dev/pipelineRun=$pr" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete pod -l "tekton.dev/pipelineRun=$pr" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete pipelinerun "$pr" --ignore-not-found >/dev/null 2>&1 || true
    log "Deleted failed PipelineRun $pr"
  fi
done <<< "$failed_runs"

log "Cleanup complete"
log "help: ./scripts/k8s/cleanup-failed-tekton-pipelines.sh --help"
