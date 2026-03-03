#!/bin/bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
SECRET_NAME="${ARGOCD_PASSWORD_SECRET_NAME:-argocd-initial-admin-secret}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/argocd-password.sh [options]

Prints the ArgoCD admin password from Kubernetes secret data.

Options:
  --namespace <ns>    ArgoCD namespace (default: ARGOCD_NAMESPACE or argocd)
  --secret <name>     Secret name (default: ARGOCD_PASSWORD_SECRET_NAME or argocd-initial-admin-secret)
  -h, --help          Show this help
USAGE
}

die() {
  echo "[argocd-password] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      ARGOCD_NAMESPACE="$2"
      shift 2
      ;;
    --secret)
      [[ $# -ge 2 ]] || die "Missing value for --secret"
      SECRET_NAME="$2"
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

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

if ! kubectl -n "$ARGOCD_NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  die "Secret $SECRET_NAME not found in namespace $ARGOCD_NAMESPACE"
fi

encoded_password="$(kubectl -n "$ARGOCD_NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.password}')"
[[ -n "$encoded_password" ]] || die "password key missing in secret $SECRET_NAME"

if printf '%s' "$encoded_password" | base64 --decode >/dev/null 2>&1; then
  printf '%s' "$encoded_password" | base64 --decode
elif printf '%s' "$encoded_password" | base64 -d >/dev/null 2>&1; then
  printf '%s' "$encoded_password" | base64 -d
elif printf '%s' "$encoded_password" | base64 -D >/dev/null 2>&1; then
  printf '%s' "$encoded_password" | base64 -D
else
  die "Unable to decode base64 password with local base64 command"
fi

printf '\n'
