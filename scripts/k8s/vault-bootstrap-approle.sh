#!/bin/bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_POLICY_NAME="${VAULT_POLICY_NAME:-external-secrets-read}"
VAULT_SECRET_PATH_PREFIX="${VAULT_SECRET_PATH_PREFIX:-kv/data/ci/*}"
VAULT_APPROLE_NAME="${VAULT_APPROLE_NAME:-external-secrets}"
VAULT_APPROLE_PATH="${VAULT_APPROLE_PATH:-approle}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-external-secrets}"
SECRET_NAME="${SECRET_NAME:-vault-approle}"
ROLE_ID_KEY="${ROLE_ID_KEY:-role-id}"
SECRET_ID_KEY="${SECRET_ID_KEY:-secret-id}"
UPDATE_STORE="true"
STORE_FILE="manifests/security/external-secrets/cluster-secret-store-vault-approle.yaml"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/vault-bootstrap-approle.sh [options]

Bootstraps Vault AppRole for External Secrets and stores role/secret IDs in Kubernetes.

Required env:
  VAULT_ADDR
  VAULT_TOKEN

Options:
  --policy-name <name>          Vault policy name (default: external-secrets-read)
  --secret-path-prefix <path>   Vault KV v2 data path pattern (default: kv/data/ci/*)
  --approle-name <name>         AppRole name (default: external-secrets)
  --approle-path <path>         AppRole auth mount path (default: approle)
  --secret-namespace <ns>       Kubernetes secret namespace (default: external-secrets)
  --secret-name <name>          Kubernetes secret name (default: vault-approle)
  --no-store-update             Do not update ClusterSecretStore file roleId placeholder
  --store-file <path>           ClusterSecretStore file to patch roleId
  -h, --help                    Show help
USAGE
}

log() { echo "[vault-approle] $*"; }
die() { echo "[vault-approle] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-name) VAULT_POLICY_NAME="$2"; shift 2 ;;
    --secret-path-prefix) VAULT_SECRET_PATH_PREFIX="$2"; shift 2 ;;
    --approle-name) VAULT_APPROLE_NAME="$2"; shift 2 ;;
    --approle-path) VAULT_APPROLE_PATH="$2"; shift 2 ;;
    --secret-namespace) SECRET_NAMESPACE="$2"; shift 2 ;;
    --secret-name) SECRET_NAME="$2"; shift 2 ;;
    --no-store-update) UPDATE_STORE="false"; shift ;;
    --store-file) STORE_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is required"
[[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is required"

export VAULT_ADDR VAULT_TOKEN

if ! vault auth list -format=json | jq -e ".\"${VAULT_APPROLE_PATH}/\"" >/dev/null 2>&1; then
  log "enabling AppRole auth at ${VAULT_APPROLE_PATH}/"
  vault auth enable -path="$VAULT_APPROLE_PATH" approle >/dev/null
fi

log "writing policy $VAULT_POLICY_NAME"
cat <<POLICY | vault policy write "$VAULT_POLICY_NAME" - >/dev/null
path "$VAULT_SECRET_PATH_PREFIX" {
  capabilities = ["read", "list"]
}
POLICY

log "configuring AppRole $VAULT_APPROLE_NAME"
vault write "auth/${VAULT_APPROLE_PATH}/role/${VAULT_APPROLE_NAME}" \
  token_policies="$VAULT_POLICY_NAME" \
  secret_id_num_uses=0 \
  secret_id_ttl=24h \
  token_ttl=1h \
  token_max_ttl=24h >/dev/null

role_id="$(vault read -field=role_id "auth/${VAULT_APPROLE_PATH}/role/${VAULT_APPROLE_NAME}/role-id")"
secret_id="$(vault write -f -field=secret_id "auth/${VAULT_APPROLE_PATH}/role/${VAULT_APPROLE_NAME}/secret-id")"

kubectl create namespace "$SECRET_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$SECRET_NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal="$ROLE_ID_KEY=$role_id" \
  --from-literal="$SECRET_ID_KEY=$secret_id" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [[ "$UPDATE_STORE" == "true" ]]; then
  [[ -f "$STORE_FILE" ]] || die "Store file not found: $STORE_FILE"
  sed "s|REPLACE_WITH_VAULT_ROLE_ID|$role_id|g" "$STORE_FILE" > "$STORE_FILE.tmp"
  mv "$STORE_FILE.tmp" "$STORE_FILE"
  log "patched roleId in $STORE_FILE"
fi

log "done"
