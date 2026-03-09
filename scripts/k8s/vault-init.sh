
#!/bin/bash
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { echo "[init-vault] $*"; }

# Port-forward if needed
if ! curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
  log "starting port-forward..."
  kubectl port-forward svc/vault -n vault 8200:8200 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null' EXIT
  sleep 3
fi

log "enabling secrets engine..."
vault secrets enable -path=kv kv-v2 2>/dev/null || log "kv already enabled"
vault auth enable approle 2>/dev/null || log "approle already enabled"

log "writing policies..."
vault policy write external-secrets - <<EOF
path "kv/data/ci/*" { capabilities = ["read", "list"] }
path "kv/metadata/ci/*" { capabilities = ["read", "list"] }
EOF

vault policy write bootstrap-reader - <<EOF
path "kv/*" { capabilities = ["read", "list"] }
EOF

log "creating approle..."
vault write auth/approle/role/external-secrets token_policies="external-secrets" token_ttl=1h token_max_ttl=4h

ROLE_ID=$(vault read -field=role_id auth/approle/role/external-secrets/role-id)
SECRET_ID=$(vault write -field=secret_id -f auth/approle/role/external-secrets/secret-id)
log "role-id: $ROLE_ID"

log "storing secrets in Vault KV..."
vault kv put kv/external-secrets/approle role-id="$ROLE_ID" secret-id="$SECRET_ID"
vault kv put kv/external-secrets/cosign public-key="$(cat "$ROOT_DIR/cosign.pub")" private-key="$(cat "$ROOT_DIR/cosign.key")"
vault kv put kv/ci/cosign private_key_pem="$(cat "$ROOT_DIR/cosign.key")" password=""
vault kv put kv/ci/docker-config config_json='{"auths":{}}'
vault kv put kv/ci/sonarqube host_url="http://your-sonarqube-url" token="your-sonarqube-token"

log "creating bootstrap token..."
NEW_TOKEN=$(vault token create -policy=bootstrap-reader -ttl=8760h -display-name=bootstrap-reader -no-default-policy -format=json | jq -r '.auth.client_token')

log "saving secrets to Kubernetes..."
kubectl delete secret vault-bootstrap-token -n external-secrets --ignore-not-found
kubectl create secret generic vault-bootstrap-token --namespace external-secrets --from-literal=token=$NEW_TOKEN

kubectl delete secret vault-approle -n external-secrets --ignore-not-found
kubectl create secret generic vault-approle --namespace external-secrets --from-literal=secret-id=$SECRET_ID

log "Vault init complete! Run ./scripts/k8s/run-security.sh"
