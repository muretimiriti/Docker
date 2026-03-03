#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

STOP_TEKTON="true"
STOP_ARGOCD="true"

TEKTON_NAMESPACE="${TEKTON_NAMESPACE:-default}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-tech-stack}"

TEKTON_PIPELINES_RELEASE_URL="${TEKTON_PIPELINES_RELEASE_URL:-https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml}"
TEKTON_TRIGGERS_RELEASE_URL="${TEKTON_TRIGGERS_RELEASE_URL:-https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml}"
TEKTON_TRIGGERS_INTERCEPTORS_URL="${TEKTON_TRIGGERS_INTERCEPTORS_URL:-https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml}"
TEKTON_DASHBOARD_RELEASE_URL="${TEKTON_DASHBOARD_RELEASE_URL:-https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/k8s-stop.sh [options]

Deletes Tekton and ArgoCD resources from the cluster.

Options:
  --skip-tekton        Do not clean up Tekton resources
  --skip-argocd        Do not clean up ArgoCD resources
  -h, --help           Show this help message

Environment:
  TEKTON_NAMESPACE                 Namespace where pipeline workloads were applied (default: default)
  ARGOCD_NAMESPACE                 Namespace where ArgoCD is installed (default: argocd)
  ARGOCD_APP_NAME                  ArgoCD Application name to delete first (default: tech-stack)
  TEKTON_PIPELINES_RELEASE_URL     Tekton Pipelines release manifest URL
  TEKTON_TRIGGERS_RELEASE_URL      Tekton Triggers release manifest URL
  TEKTON_TRIGGERS_INTERCEPTORS_URL Tekton Triggers interceptors manifest URL
  TEKTON_DASHBOARD_RELEASE_URL     Tekton Dashboard release manifest URL
  ARGOCD_INSTALL_URL               ArgoCD install manifest URL
USAGE
}

log() {
  echo "[k8s-stop] $*"
}

die() {
  echo "[k8s-stop] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tekton)
      STOP_TEKTON="false"
      shift
      ;;
    --skip-argocd)
      STOP_ARGOCD="false"
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

if [[ "$STOP_TEKTON" == "false" && "$STOP_ARGOCD" == "false" ]]; then
  die "Nothing to do; both Tekton and ArgoCD cleanup are skipped"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

delete_manifest_if_present() {
  local manifest="$1"
  local ns="${2:-}"
  if [[ -n "$ns" ]]; then
    kubectl -n "$ns" delete -f "$manifest" --ignore-not-found >/dev/null 2>&1 || true
  else
    kubectl delete -f "$manifest" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

delete_url_manifest() {
  local url="$1"
  local ns="${2:-}"
  if [[ -n "$ns" ]]; then
    kubectl -n "$ns" delete -f "$url" --ignore-not-found >/dev/null 2>&1 || true
  else
    kubectl delete -f "$url" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

cleanup_tekton() {
  log "cleaning Tekton app resources from namespace $TEKTON_NAMESPACE"

  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/triggers/event-listener.yaml" "$TEKTON_NAMESPACE"
  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/triggers/trigger-template.yaml" "$TEKTON_NAMESPACE"
  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/triggers/trigger-binding.yaml" "$TEKTON_NAMESPACE"
  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/pipeline/pipeline.yaml" "$TEKTON_NAMESPACE"
  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/tasks/" "$TEKTON_NAMESPACE"
  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/pvc/cache-pvc.yaml" "$TEKTON_NAMESPACE"
  delete_manifest_if_present "$ROOT_DIR/manifests/tekton/rbac/rbac.yaml" "$TEKTON_NAMESPACE"

  kubectl -n "$TEKTON_NAMESPACE" delete pipelinerun --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$TEKTON_NAMESPACE" delete taskrun --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$TEKTON_NAMESPACE" delete secret docker-credentials sonarqube-credentials ssh-key --ignore-not-found >/dev/null 2>&1 || true

  log "removing Tekton control-plane manifests"
  delete_url_manifest "$TEKTON_DASHBOARD_RELEASE_URL"
  delete_url_manifest "$TEKTON_TRIGGERS_INTERCEPTORS_URL"
  delete_url_manifest "$TEKTON_TRIGGERS_RELEASE_URL"
  delete_url_manifest "$TEKTON_PIPELINES_RELEASE_URL"

  kubectl delete namespace tekton-dashboard --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace tekton-pipelines-resolvers --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace tekton-pipelines --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

cleanup_argocd() {
  log "cleaning ArgoCD resources from namespace $ARGOCD_NAMESPACE"

  kubectl -n "$ARGOCD_NAMESPACE" delete application.argoproj.io "$ARGOCD_APP_NAME" --ignore-not-found >/dev/null 2>&1 || true
  delete_url_manifest "$ARGOCD_INSTALL_URL" "$ARGOCD_NAMESPACE"
  kubectl delete namespace "$ARGOCD_NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

log "starting cleanup (tekton=$STOP_TEKTON, argocd=$STOP_ARGOCD)"

if [[ "$STOP_TEKTON" == "true" ]]; then
  cleanup_tekton
else
  log "skipping Tekton cleanup"
fi

if [[ "$STOP_ARGOCD" == "true" ]]; then
  cleanup_argocd
else
  log "skipping ArgoCD cleanup"
fi

log "cleanup complete"
