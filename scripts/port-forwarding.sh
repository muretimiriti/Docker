#!/bin/bash
set -euo pipefail

TARGET="${1:-all}"
LOCAL_PORT_OVERRIDE="${2:-}"

APP_NAMESPACE="${APP_NAMESPACE:-default}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"

usage() {
  cat <<USAGE
Usage: ./scripts/port-forwarding.sh [all|tekton|argocd|grafana|app|mongo-express|mongo] [local-port]

Port-forward platform and application services to localhost.

Arguments:
  target          Target to forward (default: all)
  local-port      Optional local port override (single-target mode only)

Environment:
  APP_NAMESPACE   Namespace for app services (default: default)
  ARGOCD_NAMESPACE Namespace for ArgoCD (default: argocd)
  OBS_NAMESPACE   Namespace for observability stack (default: observability)

Examples:
  ./scripts/port-forwarding.sh
  ./scripts/port-forwarding.sh all
  ./scripts/port-forwarding.sh tekton 9097
  ./scripts/port-forwarding.sh argocd 8080
  ./scripts/port-forwarding.sh grafana 3000
  ./scripts/port-forwarding.sh app 3000
USAGE
}

die() {
  echo "[port-forward] $*" >&2
  exit 1
}

log() {
  echo "[port-forward] $*"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 && "$p" -le 65535 ]]
}

service_exists() {
  local ns="$1"
  local svc="$2"
  kubectl -n "$ns" get svc "$svc" >/dev/null 2>&1
}

resolve_tekton_namespace() {
  if service_exists "tekton-dashboard" "tekton-dashboard"; then
    printf '%s\n' "tekton-dashboard"
  elif service_exists "tekton-pipelines" "tekton-dashboard"; then
    printf '%s\n' "tekton-pipelines"
  else
    return 1
  fi
}

forward_one() {
  local label="$1"
  local ns="$2"
  local svc="$3"
  local local_port="$4"
  local target_port="$5"
  local mode="${6:-foreground}"

  if ! valid_port "$local_port"; then
    die "Invalid local port: $local_port"
  fi

  if ! service_exists "$ns" "$svc"; then
    if [[ "$mode" == "background" ]]; then
      log "skipping $label: svc/$svc not found in namespace $ns"
      return 1
    fi
    die "Service $svc not found in namespace $ns"
  fi

  log "$label -> http://localhost:$local_port (namespace=$ns service=$svc targetPort=$target_port)"
  if [[ "$mode" == "background" ]]; then
    kubectl -n "$ns" port-forward "svc/$svc" "$local_port:$target_port" >/tmp/port-forward-"$label".log 2>&1 &
    return 0
  fi

  exec kubectl -n "$ns" port-forward "svc/$svc" "$local_port:$target_port"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

case "$TARGET" in
  tekton)
    [[ -z "$LOCAL_PORT_OVERRIDE" ]] || valid_port "$LOCAL_PORT_OVERRIDE" || die "Invalid local port: $LOCAL_PORT_OVERRIDE"
    TEKTON_NS="$(resolve_tekton_namespace)" || die "Service tekton-dashboard not found in tekton-dashboard or tekton-pipelines namespace"
    forward_one "tekton" "$TEKTON_NS" "tekton-dashboard" "${LOCAL_PORT_OVERRIDE:-9097}" "9097"
    ;;
  argocd)
    [[ -z "$LOCAL_PORT_OVERRIDE" ]] || valid_port "$LOCAL_PORT_OVERRIDE" || die "Invalid local port: $LOCAL_PORT_OVERRIDE"
    forward_one "argocd" "$ARGOCD_NAMESPACE" "argocd-server" "${LOCAL_PORT_OVERRIDE:-8080}" "443"
    ;;
  grafana)
    [[ -z "$LOCAL_PORT_OVERRIDE" ]] || valid_port "$LOCAL_PORT_OVERRIDE" || die "Invalid local port: $LOCAL_PORT_OVERRIDE"
    forward_one "grafana" "$OBS_NAMESPACE" "grafana" "${LOCAL_PORT_OVERRIDE:-3000}" "3000"
    ;;
  app)
    [[ -z "$LOCAL_PORT_OVERRIDE" ]] || valid_port "$LOCAL_PORT_OVERRIDE" || die "Invalid local port: $LOCAL_PORT_OVERRIDE"
    forward_one "app" "$APP_NAMESPACE" "sample-node-app" "${LOCAL_PORT_OVERRIDE:-3000}" "3000"
    ;;
  mongo-express)
    [[ -z "$LOCAL_PORT_OVERRIDE" ]] || valid_port "$LOCAL_PORT_OVERRIDE" || die "Invalid local port: $LOCAL_PORT_OVERRIDE"
    forward_one "mongo-express" "$APP_NAMESPACE" "mongo-express" "${LOCAL_PORT_OVERRIDE:-8081}" "8081"
    ;;
  mongo)
    [[ -z "$LOCAL_PORT_OVERRIDE" ]] || valid_port "$LOCAL_PORT_OVERRIDE" || die "Invalid local port: $LOCAL_PORT_OVERRIDE"
    forward_one "mongo" "$APP_NAMESPACE" "mongo" "${LOCAL_PORT_OVERRIDE:-27017}" "27017"
    ;;
  all)
    if [[ -n "$LOCAL_PORT_OVERRIDE" ]]; then
      die "local-port override is only supported for single-target mode"
    fi

    pids=()
    started=0

    if TEKTON_NS="$(resolve_tekton_namespace 2>/dev/null)"; then
      if forward_one "tekton" "$TEKTON_NS" "tekton-dashboard" "9097" "9097" "background"; then
        pids+=("$!")
        started=$((started + 1))
      fi
    else
      log "skipping tekton: dashboard service not found"
    fi

    if forward_one "argocd" "$ARGOCD_NAMESPACE" "argocd-server" "8080" "443" "background"; then
      pids+=("$!")
      started=$((started + 1))
    fi

    if forward_one "grafana" "$OBS_NAMESPACE" "grafana" "3000" "3000" "background"; then
      pids+=("$!")
      started=$((started + 1))
    fi

    if forward_one "app" "$APP_NAMESPACE" "sample-node-app" "3000" "3000" "background"; then
      pids+=("$!")
      started=$((started + 1))
    fi

    if forward_one "mongo-express" "$APP_NAMESPACE" "mongo-express" "8081" "8081" "background"; then
      pids+=("$!")
      started=$((started + 1))
    fi

    if forward_one "mongo" "$APP_NAMESPACE" "mongo" "27017" "27017" "background"; then
      pids+=("$!")
      started=$((started + 1))
    fi

    if [[ "$started" -eq 0 ]]; then
      die "No matching services found to port-forward"
    fi

    cleanup() {
      log "stopping all port-forward processes"
      for pid in "${pids[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
      done
    }

    trap cleanup INT TERM EXIT
    log "started $started port-forward(s); press Ctrl+C to stop"
    wait
    ;;
  *)
    die "Unknown target '$TARGET'. Use one of: all, tekton, argocd, grafana, app, mongo-express, mongo"
    ;;
esac
