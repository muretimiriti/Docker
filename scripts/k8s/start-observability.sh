#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log() {
  echo "[observability] $*"
}

die() {
  echo "[observability] $*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<USAGE
Usage: ./scripts/k8s/start-observability.sh

Applies OpenTelemetry Collector, Prometheus+Thanos, Loki+Promtail, Tempo, and Grafana.
USAGE
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

log "applying observability stack"
kubectl apply -k "$ROOT_DIR/manifests/observability"

log "waiting for deployments"
kubectl -n observability rollout status deployment/otel-collector --timeout=240s
kubectl -n observability rollout status deployment/prometheus --timeout=240s
kubectl -n observability rollout status deployment/thanos-query --timeout=240s
kubectl -n observability rollout status deployment/loki --timeout=240s
kubectl -n observability rollout status deployment/tempo --timeout=240s
kubectl -n observability rollout status deployment/grafana --timeout=240s

log "setup complete"
log "grafana: kubectl -n observability port-forward svc/grafana 3000:3000"
log "thanos query: kubectl -n observability port-forward svc/thanos-query 9090:9090"
log "help: ./scripts/k8s/start-observability.sh --help"
