#!/bin/bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_POLICY_NAME="${VAULT_POLICY_NAME:-external-secrets-read}"
VAULT_SECRET_PATH_PREFIX="${VAULT_SECRET_PATH_PREFIX:-kv/data/ci/*}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-external-secrets}"
SECRET_NAME="${SECRET_NAME:-vault-token}"
TOKEN_TTL="${TOKEN_TTL:-24h}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/vault-bootstrap-token.sh [options]

Creates a scoped Vault token for External Secrets and stores it in Kubernetes.

Required env:
  VAULT_ADDR
  VAULT_TOKEN

Options:
  --policy-name <name>         Policy name (default: external-secrets-read)
  --secret-path-prefix <path>  Vault KV path glob (default: kv/data/ci/*)
  --secret-namespace <ns>      Secret namespace (default: external-secrets)
  --secret-name <name>         Secret name (default: vault-token)
  --token-ttl <ttl>            Token TTL (default: 24h)
  -h, --help                   Show help
USAGE
}

log() { echo "[vault-token] $*"; }
die() { echo "[vault-token] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-name) VAULT_POLICY_NAME="$2"; shift 2 ;;
    --secret-path-prefix) VAULT_SECRET_PATH_PREFIX="$2"; shift 2 ;;
    --secret-namespace) SECRET_NAMESPACE="$2"; shift 2 ;;
    --secret-name) SECRET_NAME="$2"; shift 2 ;;
    --token-ttl) TOKEN_TTL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
[[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is required"
[[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is required"

export VAULT_ADDR VAULT_TOKEN

cat <<POLICY | vault policy write "$VAULT_POLICY_NAME" - >/dev/null
path "$VAULT_SECRET_PATH_PREFIX" {
  capabilities = ["read", "list"]
}
POLICY

scoped_token="$(vault token create -policy="$VAULT_POLICY_NAME" -period="$TOKEN_TTL" -field=token)"

kubectl create namespace "$SECRET_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$SECRET_NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=token="$scoped_token" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "done"
