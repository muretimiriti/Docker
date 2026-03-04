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
VAULT_AUTH_MODE="${VAULT_AUTH_MODE:-approle}"
VAULT_APPROLE_ROLE_ID="${VAULT_APPROLE_ROLE_ID:-}"
VAULT_APPROLE_SECRET_NAME="${VAULT_APPROLE_SECRET_NAME:-vault-approle}"
VAULT_APPROLE_SECRET_KEY="${VAULT_APPROLE_SECRET_KEY:-secret-id}"
VAULT_JWT_PATH="${VAULT_JWT_PATH:-jwt}"
VAULT_JWT_ROLE="${VAULT_JWT_ROLE:-external-secrets}"
COSIGN_PUBLIC_KEY_FILE="${COSIGN_PUBLIC_KEY_FILE:-}"
ESO_HELM_RELEASE="${ESO_HELM_RELEASE:-external-secrets}"
KYVERNO_HELM_RELEASE="${KYVERNO_HELM_RELEASE:-kyverno}"
KYVERNO_IMAGE_REGISTRY="${KYVERNO_IMAGE_REGISTRY:-ghcr.io}"

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
  --vault-auth-mode <mode>     Vault auth mode: token|approle|jwt (default: approle)
  --vault-approle-role-id <id> Vault AppRole roleId (required for approle mode unless pre-patched manifest)
  --vault-approle-secret <name> Kubernetes secret with AppRole secret-id (default: vault-approle)
  --vault-approle-secret-key <k> Secret key for AppRole secret-id (default: secret-id)
  --vault-jwt-path <path>      Vault JWT auth mount path (default: jwt)
  --vault-jwt-role <role>      Vault JWT role (default: external-secrets)
  --cosign-public-key-file <f> File path for cosign public key; creates kyverno/cosign-public-key
  --kyverno-image-registry <r> Kyverno image registry (default: ghcr.io)
  -h, --help                   Show help

Environment:
  VAULT_ADDR
  VAULT_PATH
  VAULT_VERSION
  VAULT_TOKEN_SECRET_NAMESPACE
  VAULT_TOKEN_SECRET_NAME
  VAULT_TOKEN_SECRET_KEY
  VAULT_AUTH_MODE
  VAULT_APPROLE_ROLE_ID
  VAULT_APPROLE_SECRET_NAME
  VAULT_APPROLE_SECRET_KEY
  VAULT_JWT_PATH
  VAULT_JWT_ROLE
  COSIGN_PUBLIC_KEY_FILE
  ESO_HELM_RELEASE
  KYVERNO_HELM_RELEASE
  KYVERNO_IMAGE_REGISTRY
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
    --vault-auth-mode)
      [[ $# -ge 2 ]] || die "Missing value for --vault-auth-mode"
      VAULT_AUTH_MODE="$2"
      shift 2
      ;;
    --vault-approle-role-id)
      [[ $# -ge 2 ]] || die "Missing value for --vault-approle-role-id"
      VAULT_APPROLE_ROLE_ID="$2"
      shift 2
      ;;
    --vault-approle-secret)
      [[ $# -ge 2 ]] || die "Missing value for --vault-approle-secret"
      VAULT_APPROLE_SECRET_NAME="$2"
      shift 2
      ;;
    --vault-approle-secret-key)
      [[ $# -ge 2 ]] || die "Missing value for --vault-approle-secret-key"
      VAULT_APPROLE_SECRET_KEY="$2"
      shift 2
      ;;
    --vault-jwt-path)
      [[ $# -ge 2 ]] || die "Missing value for --vault-jwt-path"
      VAULT_JWT_PATH="$2"
      shift 2
      ;;
    --vault-jwt-role)
      [[ $# -ge 2 ]] || die "Missing value for --vault-jwt-role"
      VAULT_JWT_ROLE="$2"
      shift 2
      ;;
    --cosign-public-key-file)
      [[ $# -ge 2 ]] || die "Missing value for --cosign-public-key-file"
      COSIGN_PUBLIC_KEY_FILE="$2"
      shift 2
      ;;
    --kyverno-image-registry)
      [[ $# -ge 2 ]] || die "Missing value for --kyverno-image-registry"
      KYVERNO_IMAGE_REGISTRY="$2"
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
  log "installing Kyverno via Helm (image registry=$KYVERNO_IMAGE_REGISTRY)"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update kyverno >/dev/null 2>&1 || true
  helm upgrade --install "$KYVERNO_HELM_RELEASE" kyverno/kyverno \
    --namespace kyverno \
    --create-namespace \
    --set global.image.registry="$KYVERNO_IMAGE_REGISTRY" >/dev/null
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
  case "$VAULT_AUTH_MODE" in
    token|approle|jwt) ;;
    *) die "Unsupported vault auth mode '$VAULT_AUTH_MODE' (use token|approle|jwt)" ;;
  esac

  tmp_store="$(mktemp)"
  store_source=""
  case "$VAULT_AUTH_MODE" in
    token)
      store_source="$ROOT_DIR/manifests/security/external-secrets/cluster-secret-store-vault-token.yaml"
      awk -v addr="$VAULT_ADDR" -v path="$VAULT_PATH" -v ver="$VAULT_VERSION" \
          -v ns="$VAULT_TOKEN_SECRET_NAMESPACE" -v sec="$VAULT_TOKEN_SECRET_NAME" -v key="$VAULT_TOKEN_SECRET_KEY" '
        { gsub("https://vault.vault.svc.cluster.local:8200", addr) }
        { gsub("path: kv", "path: " path) }
        { gsub("version: v2", "version: " ver) }
        { gsub("name: vault-token", "name: " sec) }
        { gsub("key: token", "key: " key) }
        { gsub("namespace: external-secrets", "namespace: " ns) }
        { print }
      ' "$store_source" > "$tmp_store"
      ;;
    approle)
      store_source="$ROOT_DIR/manifests/security/external-secrets/cluster-secret-store-vault-approle.yaml"
      awk -v addr="$VAULT_ADDR" -v path="$VAULT_PATH" -v ver="$VAULT_VERSION" \
          -v role_id="$VAULT_APPROLE_ROLE_ID" -v sec="$VAULT_APPROLE_SECRET_NAME" -v key="$VAULT_APPROLE_SECRET_KEY" '
        { gsub("https://vault.vault.svc.cluster.local:8200", addr) }
        { gsub("path: kv", "path: " path) }
        { gsub("version: v2", "version: " ver) }
        { if (role_id != "") gsub("REPLACE_WITH_VAULT_ROLE_ID", role_id) }
        { gsub("name: vault-approle", "name: " sec) }
        { gsub("key: secret-id", "key: " key) }
        { print }
      ' "$store_source" > "$tmp_store"
      if grep -q "REPLACE_WITH_VAULT_ROLE_ID" "$tmp_store"; then
        die "approle mode requires --vault-approle-role-id (or pre-patch manifests/security/external-secrets/cluster-secret-store-vault-approle.yaml)"
      fi
      ;;
    jwt)
      store_source="$ROOT_DIR/manifests/security/external-secrets/cluster-secret-store-vault-jwt.yaml"
      awk -v addr="$VAULT_ADDR" -v path="$VAULT_PATH" -v ver="$VAULT_VERSION" \
          -v jwt_path="$VAULT_JWT_PATH" -v jwt_role="$VAULT_JWT_ROLE" '
        { gsub("https://vault.vault.svc.cluster.local:8200", addr) }
        { gsub("path: kv", "path: " path) }
        { gsub("version: v2", "version: " ver) }
        { gsub("path: jwt", "path: " jwt_path) }
        { gsub("role: external-secrets", "role: " jwt_role) }
        { print }
      ' "$store_source" > "$tmp_store"
      ;;
  esac

  kubectl apply -f "$tmp_store"
  rm -f "$tmp_store"

  kubectl apply -f "$ROOT_DIR/manifests/security/external-secrets/tekton-secrets.externalsecret.yaml"

  if [[ "$ENFORCE_POLICY" == "true" && -z "$COSIGN_PUBLIC_KEY_FILE" ]]; then
    die "Enforce mode requires --cosign-public-key-file so verify policy can embed a real public key"
  fi

  policy_file="$(mktemp)"
  cp "$ROOT_DIR/manifests/security/kyverno/verify-cosign-policy.yaml" "$policy_file"
  if [[ -n "$COSIGN_PUBLIC_KEY_FILE" ]]; then
    pem_body="$(sed 's/[\\/&]/\\&/g' "$COSIGN_PUBLIC_KEY_FILE" | sed ':a;N;$!ba;s/\n/\\n                      /g')"
    sed -i '' "s/REPLACE_WITH_COSIGN_PUBLIC_KEY/$pem_body/g" "$policy_file"
  fi

  if [[ "$ENFORCE_POLICY" == "true" ]]; then
    kubectl apply -f "$policy_file"
  else
    sed -e 's/validationFailureAction: Enforce/validationFailureAction: Audit/' \
        -e 's/mutateDigest: true/mutateDigest: false/' \
      "$policy_file" | kubectl apply -f -
  fi

  rm -f "$policy_file"
fi

log "security setup complete"
