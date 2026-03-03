#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
DELETE_NAMESPACE="true"
FORCE="false"

usage() {
  cat <<USAGE
Usage: ./scripts/k8s/stop-observability.sh [options]

Deletes OpenTelemetry, Prometheus+Thanos, Loki+Promtail, Tempo, and Grafana resources.

Options:
  --namespace <ns>       Namespace to clean (default: observability)
  --keep-namespace       Delete resources but keep namespace
  --force                Force remove namespace finalizers if stuck terminating
  -h, --help             Show this help

Environment:
  OBSERVABILITY_NAMESPACE   Same as --namespace
USAGE
}

log() {
  echo "[observability] $*"
}

die() {
  echo "[observability] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"
      shift 2
      ;;
    --keep-namespace)
      DELETE_NAMESPACE="false"
      shift
      ;;
    --force)
      FORCE="true"
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
  log "namespace '$NAMESPACE' not found; nothing to clean"
  exit 0
fi

log "deleting observability resources in namespace $NAMESPACE"
kubectl delete -k "$ROOT_DIR/manifests/observability" --ignore-not-found --wait=false --timeout=30s --request-timeout=30s >/dev/null 2>&1 || true

if [[ "$DELETE_NAMESPACE" == "true" ]]; then
  log "deleting namespace $NAMESPACE"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false --timeout=30s --request-timeout=30s >/dev/null 2>&1 || true

  if [[ "$FORCE" == "true" ]]; then
    state="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$state" == "Terminating" ]]; then
      log "force mode: removing namespace finalizers for $NAMESPACE"
      kubectl get namespace "$NAMESPACE" -o json \
        | sed 's/"finalizers": \[[^]]*\]/"finalizers": []/' \
        | kubectl replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f - >/dev/null 2>&1 || true
    fi
  fi
fi

log "cleanup complete"
log "help: ./scripts/k8s/stop-observability.sh --help"
