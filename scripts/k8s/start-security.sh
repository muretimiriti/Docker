#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

INSTALL_ESO="true"
INSTALL_KYVERNO="true"
APPLY_SECURITY_MANIFESTS="true"
ENFORCE_POLICY="true"
VAULT_ADDR="${VAULT_ADDR:-https://vault.vault.svc.cluster.local:8200}"
VAULT_PATH="${VAULT_PATH:-kv}"
VAULT_VERSION="${VAULT_VERSION:-v2}"
VAULT_TOKEN_SECRET_NAMESPACE="${VAULT_TOKEN_SECRET_NAMESPACE:-external-secrets}"
VAULT_TOKEN_SECRET_NAME="${VAULT_TOKEN_SECRET_NAME:-vault-token}"
VAULT_TOKEN_SECRET_KEY="${VAULT_TOKEN_SECRET_KEY:-token}"
COSIGN_PUBLIC_KEY_FILE="${COSIGN_PUBLIC_KEY_FILE:-}"
ESO_HELM_RELEASE="${ESO_HELM_RELEASE:-external-secrets}"
KYVERNO_HELM_RELEASE="${KYVERNO_HELM_RELEASE:-kyverno}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/start-security.sh [options]

Installs External Secrets Operator + Kyverno and applies security manifests.

Options:
  --skip-install-eso           Do not install External Secrets Operator
  --skip-install-kyverno       Do not install Kyverno
  --skip-apply                 Do not apply manifests/security
  --audit-policy               Set Kyverno verify policy to Audit (default: Enforce)
  --vault-addr <url>           Vault server URL
  --vault-path <path>          Vault KV mount path (default: kv)
  --vault-version <v1|v2>      Vault engine version (default: v2)
  --vault-token-namespace <ns> Namespace containing vault token secret
  --vault-token-secret <name>  Secret name for Vault token
  --vault-token-key <key>      Secret key holding Vault token
  --cosign-public-key-file <f> File path for cosign public key; creates kyverno/cosign-public-key
  -h, --help                   Show help

Environment:
  VAULT_ADDR
  VAULT_PATH
  VAULT_VERSION
  VAULT_TOKEN_SECRET_NAMESPACE
  VAULT_TOKEN_SECRET_NAME
  VAULT_TOKEN_SECRET_KEY
  COSIGN_PUBLIC_KEY_FILE
  ESO_HELM_RELEASE
  KYVERNO_HELM_RELEASE
USAGE
}

log() { echo "[security] $*"; }
die() { echo "[security] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install-eso)
      INSTALL_ESO="false"
      shift
      ;;
    --skip-install-kyverno)
      INSTALL_KYVERNO="false"
      shift
      ;;
    --skip-apply)
      APPLY_SECURITY_MANIFESTS="false"
      shift
      ;;
    --audit-policy)
      ENFORCE_POLICY="false"
      shift
      ;;
    --vault-addr)
      [[ $# -ge 2 ]] || die "Missing value for --vault-addr"
      VAULT_ADDR="$2"
      shift 2
      ;;
    --vault-path)
      [[ $# -ge 2 ]] || die "Missing value for --vault-path"
      VAULT_PATH="$2"
      shift 2
      ;;
    --vault-version)
      [[ $# -ge 2 ]] || die "Missing value for --vault-version"
      VAULT_VERSION="$2"
      shift 2
      ;;
    --vault-token-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --vault-token-namespace"
      VAULT_TOKEN_SECRET_NAMESPACE="$2"
      shift 2
      ;;
    --vault-token-secret)
      [[ $# -ge 2 ]] || die "Missing value for --vault-token-secret"
      VAULT_TOKEN_SECRET_NAME="$2"
      shift 2
      ;;
    --vault-token-key)
      [[ $# -ge 2 ]] || die "Missing value for --vault-token-key"
      VAULT_TOKEN_SECRET_KEY="$2"
      shift 2
      ;;
    --cosign-public-key-file)
      [[ $# -ge 2 ]] || die "Missing value for --cosign-public-key-file"
      COSIGN_PUBLIC_KEY_FILE="$2"
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
kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach Kubernetes cluster"

if [[ "$INSTALL_ESO" == "true" ]]; then
  command -v helm >/dev/null 2>&1 || die "helm not found (required to install External Secrets Operator)"
  log "installing External Secrets Operator via Helm"
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update external-secrets >/dev/null 2>&1 || true
  helm upgrade --install "$ESO_HELM_RELEASE" external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace \
    --set installCRDs=true >/dev/null
fi

if [[ "$INSTALL_KYVERNO" == "true" ]]; then
  command -v helm >/dev/null 2>&1 || die "helm not found (required to install Kyverno)"
  log "installing Kyverno via Helm"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update kyverno >/dev/null 2>&1 || true
  helm upgrade --install "$KYVERNO_HELM_RELEASE" kyverno/kyverno \
    --namespace kyverno \
    --create-namespace >/dev/null
fi

if [[ -n "$COSIGN_PUBLIC_KEY_FILE" ]]; then
  [[ -f "$COSIGN_PUBLIC_KEY_FILE" ]] || die "Cosign public key file not found: $COSIGN_PUBLIC_KEY_FILE"
  kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kyverno create secret generic cosign-public-key \
    --from-file=cosign.pub="$COSIGN_PUBLIC_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "applied kyverno/cosign-public-key secret"
fi

if [[ "$APPLY_SECURITY_MANIFESTS" == "true" ]]; then
  tmp_store="$(mktemp)"
  awk -v addr="$VAULT_ADDR" -v path="$VAULT_PATH" -v ver="$VAULT_VERSION" \
      -v ns="$VAULT_TOKEN_SECRET_NAMESPACE" -v sec="$VAULT_TOKEN_SECRET_NAME" -v key="$VAULT_TOKEN_SECRET_KEY" '
    { gsub("https://vault.vault.svc.cluster.local:8200", addr) }
    { gsub("path: kv", "path: " path) }
    { gsub("version: v2", "version: " ver) }
    { gsub("name: vault-token", "name: " sec) }
    { gsub("key: token", "key: " key) }
    { gsub("namespace: external-secrets", "namespace: " ns) }
    { print }
  ' "$ROOT_DIR/manifests/security/external-secrets/cluster-secret-store-vault.yaml" > "$tmp_store"

  kubectl apply -f "$tmp_store"
  rm -f "$tmp_store"

  kubectl apply -f "$ROOT_DIR/manifests/security/external-secrets/tekton-secrets.externalsecret.yaml"

  if [[ "$ENFORCE_POLICY" == "true" ]]; then
    kubectl apply -f "$ROOT_DIR/manifests/security/kyverno/verify-cosign-policy.yaml"
  else
    sed 's/validationFailureAction: Enforce/validationFailureAction: Audit/' \
      "$ROOT_DIR/manifests/security/kyverno/verify-cosign-policy.yaml" | kubectl apply -f -
  fi
fi

log "security setup complete"
