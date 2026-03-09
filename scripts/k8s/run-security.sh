
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
BOOTSTRAP_SECRET_NAME="${BOOTSTRAP_SECRET_NAME:-vault-bootstrap-token}"
BOOTSTRAP_SECRET_NS="${BOOTSTRAP_SECRET_NS:-external-secrets}"
COSIGN_TMP_KEY="${COSIGN_TMP_KEY:-/tmp/cosign-public.pub}"

log() { echo "[run-security] $*"; }
die() { echo "[run-security] ERROR: $*" >&2; exit 1; }

log "fetching bootstrap token from k8s secret '$BOOTSTRAP_SECRET_NAME'..."
VAULT_BOOTSTRAP_TOKEN=$(kubectl get secret "$BOOTSTRAP_SECRET_NAME" -n "$BOOTSTRAP_SECRET_NS" -o jsonpath='{.data.token}' | base64 -d) || die "could not read secret $BOOTSTRAP_SECRET_NAME from namespace $BOOTSTRAP_SECRET_NS"

log "fetching role-id from Vault..."
ROLE_ID=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_BOOTSTRAP_TOKEN" vault kv get -field=role-id kv/external-secrets/approle) || die "could not read role-id from Vault"
log "role-id fetched successfully"

log "fetching cosign public key from Vault..."
VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_BOOTSTRAP_TOKEN" vault kv get -field=public-key kv/external-secrets/cosign > "$COSIGN_TMP_KEY" || die "could not read cosign public key from Vault"
log "cosign public key written to $COSIGN_TMP_KEY"

trap 'rm -f "$COSIGN_TMP_KEY" && log "cleaned up temp cosign key"' EXIT

exec "$SCRIPT_DIR/start-security.sh" \
  --vault-addr "$VAULT_ADDR" \
  --vault-approle-role-id "$ROLE_ID" \
  --cosign-public-key-file "$COSIGN_TMP_KEY" \
  "$@"
