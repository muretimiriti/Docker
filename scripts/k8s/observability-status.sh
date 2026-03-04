#!/bin/bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
APP_NAMESPACE="${APP_NAMESPACE:-default}"
APP_LABEL="${APP_LABEL:-sample-node-app}"
WINDOW="${WINDOW:-15m}"
REQUIRE_TRACES="${REQUIRE_TRACES:-true}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/observability-status.sh [options]

Checks observability completeness by verifying:
- Core observability pods are Running
- Thanos returns metrics
- Loki returns logs for app pods
- Tempo reports received spans (optional)

Options:
  --namespace <ns>        Observability namespace (default: observability)
  --app-namespace <ns>    Application namespace for logs query (default: default)
  --app-label <name>      App name prefix label used in logs query (default: sample-node-app)
  --window <dur>          Loki query window (default: 15m)
  --allow-no-traces       Do not fail when no traces are ingested yet
  -h, --help              Show help
USAGE
}

log() { echo "[observability-status] $*"; }
die() { echo "[observability-status] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"
      shift 2
      ;;
    --app-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --app-namespace"
      APP_NAMESPACE="$2"
      shift 2
      ;;
    --app-label)
      [[ $# -ge 2 ]] || die "Missing value for --app-label"
      APP_LABEL="$2"
      shift 2
      ;;
    --window)
      [[ $# -ge 2 ]] || die "Missing value for --window"
      WINDOW="$2"
      shift 2
      ;;
    --allow-no-traces)
      REQUIRE_TRACES="false"
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

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v rg >/dev/null 2>&1 || die "rg not found"
kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach cluster"

log "checking observability pods"
for app in grafana loki otel-collector prometheus tempo thanos-query; do
  ready="$(kubectl -n "$NAMESPACE" get deploy "$app" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ "${ready:-0}" != "0" ]] || die "deployment/$app is not ready in namespace $NAMESPACE"
done
promtail_ready="$(kubectl -n "$NAMESPACE" get daemonset promtail -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
[[ "${promtail_ready:-0}" != "0" ]] || die "daemonset/promtail has no ready pods in namespace $NAMESPACE"

cleanup_pf() {
  [[ -n "${PF_THANOS:-}" ]] && kill "$PF_THANOS" >/dev/null 2>&1 || true
  [[ -n "${PF_LOKI:-}" ]] && kill "$PF_LOKI" >/dev/null 2>&1 || true
  [[ -n "${PF_TEMPO:-}" ]] && kill "$PF_TEMPO" >/dev/null 2>&1 || true
}
trap cleanup_pf EXIT

log "querying Thanos for metrics"
kubectl -n "$NAMESPACE" port-forward svc/thanos-query 19090:9090 >/tmp/pf-thanos.log 2>&1 &
PF_THANOS=$!
sleep 2
thanos_resp="$(curl -fsS 'http://127.0.0.1:19090/api/v1/query?query=up')"
printf '%s' "$thanos_resp" | rg -q '"status":"success"' || die "Thanos query did not return success"
thanos_points="$(printf '%s' "$thanos_resp" | rg -o '"metric"' | wc -l | tr -d ' ')"
[[ "$thanos_points" != "0" ]] || die "Thanos returned zero metric series"

log "querying Loki for app logs"
kubectl -n "$NAMESPACE" port-forward svc/loki 13100:3100 >/tmp/pf-loki.log 2>&1 &
PF_LOKI=$!
sleep 2
loki_resp="$(curl -fsS --get 'http://127.0.0.1:13100/loki/api/v1/query' --data-urlencode "query=count_over_time({namespace=\"${APP_NAMESPACE}\",pod=~\"${APP_LABEL}.*\"}[${WINDOW}])")"
printf '%s' "$loki_resp" | rg -q '"status":"success"' || die "Loki query did not return success"
loki_points="$(printf '%s' "$loki_resp" | rg -o '"value"' | wc -l | tr -d ' ')"
[[ "$loki_points" != "0" ]] || die "Loki returned zero log points for app label ${APP_LABEL}"

log "checking Tempo traces ingestion"
kubectl -n "$NAMESPACE" port-forward svc/tempo 13200:3200 >/tmp/pf-tempo.log 2>&1 &
PF_TEMPO=$!
sleep 2
tempo_metric_line="$(curl -fsS 'http://127.0.0.1:13200/metrics' | rg '^tempo_distributor_spans_received_total' | head -n 1 || true)"
if [[ -z "$tempo_metric_line" ]]; then
  die "Tempo metric tempo_distributor_spans_received_total not found"
fi
tempo_value="$(printf '%s\n' "$tempo_metric_line" | awk '{print $2}' | head -n 1)"
if [[ "$REQUIRE_TRACES" == "true" ]]; then
  awk -v v="$tempo_value" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }' || die "Tempo span counter is zero"
fi

log "ok: metrics=$thanos_points logs=$loki_points spans_total=${tempo_value}"
