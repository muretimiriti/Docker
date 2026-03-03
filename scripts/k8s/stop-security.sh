#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REMOVE_MANIFESTS="true"
REMOVE_ESO="true"
REMOVE_KYVERNO="true"
DELETE_NAMESPACES="false"
FORCE="false"

ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
ESO_HELM_RELEASE="${ESO_HELM_RELEASE:-external-secrets}"
KYVERNO_HELM_RELEASE="${KYVERNO_HELM_RELEASE:-kyverno}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/stop-security.sh [options]

Cleans up security stack resources:
- custom manifests under manifests/security
- External Secrets Operator Helm release
- Kyverno Helm release

Options:
  --skip-manifests         Do not delete manifests/security resources
  --skip-eso               Do not uninstall External Secrets Operator
  --skip-kyverno           Do not uninstall Kyverno
  --delete-namespaces      Delete external-secrets and kyverno namespaces
  --force                  Force-remove namespace finalizers if terminating
  --eso-namespace <ns>     External Secrets namespace (default: external-secrets)
  --kyverno-namespace <ns> Kyverno namespace (default: kyverno)
  --eso-release <name>     External Secrets Helm release (default: external-secrets)
  --kyverno-release <name> Kyverno Helm release (default: kyverno)
  -h, --help               Show this help

Environment:
  ESO_NAMESPACE
  KYVERNO_NAMESPACE
  ESO_HELM_RELEASE
  KYVERNO_HELM_RELEASE
USAGE
}

log() { echo "[security-stop] $*"; }
die() { echo "[security-stop] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-manifests)
      REMOVE_MANIFESTS="false"
      shift
      ;;
    --skip-eso)
      REMOVE_ESO="false"
      shift
      ;;
    --skip-kyverno)
      REMOVE_KYVERNO="false"
      shift
      ;;
    --delete-namespaces)
      DELETE_NAMESPACES="true"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --eso-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --eso-namespace"
      ESO_NAMESPACE="$2"
      shift 2
      ;;
    --kyverno-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --kyverno-namespace"
      KYVERNO_NAMESPACE="$2"
      shift 2
      ;;
    --eso-release)
      [[ $# -ge 2 ]] || die "Missing value for --eso-release"
      ESO_HELM_RELEASE="$2"
      shift 2
      ;;
    --kyverno-release)
      [[ $# -ge 2 ]] || die "Missing value for --kyverno-release"
      KYVERNO_HELM_RELEASE="$2"
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

if [[ "$REMOVE_MANIFESTS" == "false" && "$REMOVE_ESO" == "false" && "$REMOVE_KYVERNO" == "false" && "$DELETE_NAMESPACES" == "false" ]]; then
  die "Nothing to do"
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach Kubernetes cluster"

if [[ "$REMOVE_MANIFESTS" == "true" ]]; then
  log "deleting security manifests"
  kubectl delete -k "$ROOT_DIR/manifests/security" --ignore-not-found --wait=false --timeout=30s --request-timeout=30s >/dev/null 2>&1 || true
fi

if [[ "$REMOVE_ESO" == "true" ]]; then
  if command -v helm >/dev/null 2>&1; then
    if helm -n "$ESO_NAMESPACE" status "$ESO_HELM_RELEASE" >/dev/null 2>&1; then
      log "uninstalling ESO Helm release $ESO_HELM_RELEASE from $ESO_NAMESPACE"
      helm -n "$ESO_NAMESPACE" uninstall "$ESO_HELM_RELEASE" >/dev/null || true
    else
      log "ESO release $ESO_HELM_RELEASE not found in $ESO_NAMESPACE"
    fi
  else
    log "helm not found; skipping ESO Helm uninstall"
  fi
fi

if [[ "$REMOVE_KYVERNO" == "true" ]]; then
  if command -v helm >/dev/null 2>&1; then
    if helm -n "$KYVERNO_NAMESPACE" status "$KYVERNO_HELM_RELEASE" >/dev/null 2>&1; then
      log "uninstalling Kyverno Helm release $KYVERNO_HELM_RELEASE from $KYVERNO_NAMESPACE"
      helm -n "$KYVERNO_NAMESPACE" uninstall "$KYVERNO_HELM_RELEASE" >/dev/null || true
    else
      log "Kyverno release $KYVERNO_HELM_RELEASE not found in $KYVERNO_NAMESPACE"
    fi
  else
    log "helm not found; skipping Kyverno Helm uninstall"
  fi
fi

if [[ "$DELETE_NAMESPACES" == "true" ]]; then
  for ns in "$ESO_NAMESPACE" "$KYVERNO_NAMESPACE"; do
    log "deleting namespace $ns"
    kubectl delete namespace "$ns" --ignore-not-found --wait=false --timeout=30s --request-timeout=30s >/dev/null 2>&1 || true

    if [[ "$FORCE" == "true" ]]; then
      phase="$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "$phase" == "Terminating" ]]; then
        log "force mode: clearing finalizers for namespace $ns"
        kubectl get namespace "$ns" -o json \
          | sed 's/"finalizers": \[[^]]*\]/"finalizers": []/' \
          | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
      fi
    fi
  done
fi

log "cleanup complete"
log "help: ./scripts/k8s/stop-security.sh --help"
