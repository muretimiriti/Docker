#!/bin/bash
# =============================================================================
# vault-startup.sh — Full Vault + ExternalSecrets recovery script
# Run this after every Minikube restart to restore Vault state
# Usage: ./vault-startup.sh [--sonar-url <url>] [--sonar-token <token>] [--cosign-password <pass>]
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# CONFIG — edit these defaults or pass as flags
# --------------------------------------------------------------------------
VAULT_ROOT_TOKEN="root"
VAULT_NAMESPACE="vault"
VAULT_PORT="8200"
COSIGN_KEY_FILE="cosign.key"
COSIGN_PASSWORD=""
SONAR_HOST_URL="http://sonarqube:9000"
SONAR_TOKEN=""
DOCKER_CONFIG="${HOME}/.docker/config.json"
EXTERNAL_SECRETS_NAMESPACE="external-secrets"
K8S_SECRET_NAMESPACE="default"
COSIGN_PUB_FILE="cosign.pub"

# --------------------------------------------------------------------------
# COLORS
# --------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[vault-startup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[vault-startup]${NC} $*"; }
error()   { echo -e "${RED}[vault-startup]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

# --------------------------------------------------------------------------
# PARSE FLAGS
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --sonar-url)       SONAR_HOST_URL="$2"; shift 2 ;;
    --sonar-token)     SONAR_TOKEN="$2"; shift 2 ;;
    --cosign-password) COSIGN_PASSWORD="$2"; shift 2 ;;
    --cosign-key)      COSIGN_KEY_FILE="$2"; shift 2 ;;
    --cosign-pub)      COSIGN_PUB_FILE="$2"; shift 2 ;;
    --docker-config)   DOCKER_CONFIG="$2"; shift 2 ;;
    *) error "Unknown flag: $1"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------
# STEP 1 — Check Minikube and kubectl
# --------------------------------------------------------------------------
section "Step 1 — Checking cluster health"

if ! kubectl get nodes &>/dev/null; then
  error "kubectl cannot reach cluster. Run: minikube start --memory=4096 --cpus=4"
  exit 1
fi
log "Cluster is reachable ✅"
kubectl get nodes

# --------------------------------------------------------------------------
# STEP 2 — Ensure Vault is installed
# --------------------------------------------------------------------------
section "Step 2 — Ensuring Vault is installed"

if ! kubectl get pods -n ${VAULT_NAMESPACE} &>/dev/null; then
  warn "Vault namespace not found — installing Vault via Helm..."
  helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
  helm repo update

  helm install vault hashicorp/vault \
    --namespace ${VAULT_NAMESPACE} \
    --create-namespace \
    --set "server.dev.enabled=true" \
    --set "server.dev.devRootToken=${VAULT_ROOT_TOKEN}" \
    --set "injector.enabled=false"
else
  VAULT_STATUS=$(kubectl get pods -n ${VAULT_NAMESPACE} vault-0 \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  if [[ "$VAULT_STATUS" != "Running" ]]; then
    warn "Vault pod not running (status: $VAULT_STATUS) — reinstalling..."
    helm uninstall vault -n ${VAULT_NAMESPACE} 2>/dev/null || true
    kubectl delete pvc -n ${VAULT_NAMESPACE} --all 2>/dev/null || true
    sleep 5

    helm install vault hashicorp/vault \
      --namespace ${VAULT_NAMESPACE} \
      --create-namespace \
      --set "server.dev.enabled=true" \
      --set "server.dev.devRootToken=${VAULT_ROOT_TOKEN}" \
      --set "injector.enabled=false"
  else
    log "Vault pod already running ✅"
  fi
fi

# --------------------------------------------------------------------------
# STEP 3 — Wait for Vault pod
# --------------------------------------------------------------------------
section "Step 3 — Waiting for Vault pod to be ready"

log "Waiting for vault-0 (up to 3 minutes)..."
kubectl wait --for=condition=ready pod/vault-0 \
  -n ${VAULT_NAMESPACE} --timeout=180s

kubectl get pods -n ${VAULT_NAMESPACE}
log "Vault pod is ready ✅"

# --------------------------------------------------------------------------
# STEP 4 — Port-forward Vault
# --------------------------------------------------------------------------
section "Step 4 — Starting Vault port-forward"

# Kill any existing port-forwards on 8200
pkill -f "port-forward.*${VAULT_PORT}" 2>/dev/null || true
lsof -ti:${VAULT_PORT} | xargs kill -9 2>/dev/null || true
sleep 3

kubectl port-forward svc/vault ${VAULT_PORT}:${VAULT_PORT} \
  -n ${VAULT_NAMESPACE} &
PF_PID=$!
sleep 5

export VAULT_ADDR="http://127.0.0.1:${VAULT_PORT}"
export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"

# Verify connection
if ! vault status &>/dev/null; then
  error "Cannot connect to Vault at ${VAULT_ADDR}"
  error "Port-forward PID: ${PF_PID}"
  exit 1
fi

log "Vault is reachable ✅"
vault status

# --------------------------------------------------------------------------
# STEP 5 — Configure Vault secrets engine
# --------------------------------------------------------------------------
section "Step 5 — Configuring Vault KV secrets engine"

vault secrets enable -path=secret kv-v2 2>/dev/null && \
  log "KV-v2 secrets engine enabled at secret/" || \
  log "KV-v2 secrets engine already enabled ✅"

# --------------------------------------------------------------------------
# STEP 6 — Push all secrets to Vault
# --------------------------------------------------------------------------
section "Step 6 — Pushing secrets to Vault"

# COSIGN
if [[ -f "$COSIGN_KEY_FILE" ]]; then
  vault kv put secret/ci/cosign \
    private_key_pem="$(cat ${COSIGN_KEY_FILE})" \
    password="${COSIGN_PASSWORD}"
  log "cosign secret pushed ✅"
else
  warn "cosign.key not found — skipping cosign secret (run: cosign generate-key-pair)"
fi

# DOCKER CREDENTIALS
if [[ -f "$DOCKER_CONFIG" ]]; then
  vault kv put secret/ci/docker-config \
    config_json="$(cat ${DOCKER_CONFIG})"
  log "docker-config secret pushed ✅"
else
  warn "Docker config not found at ${DOCKER_CONFIG} — skipping"
fi

# SONARQUBE
if [[ -n "$SONAR_TOKEN" ]]; then
  vault kv put secret/ci/sonarqube \
    host_url="${SONAR_HOST_URL}" \
    token="${SONAR_TOKEN}"
  log "sonarqube secret pushed ✅"
else
  warn "SONAR_TOKEN not provided — skipping sonarqube secret"
  warn "Re-run with: --sonar-url <url> --sonar-token <token>"
fi

# Verify
log "Verifying secrets in Vault..."
vault kv list secret/ci/ || warn "No secrets found at secret/ci/"

# --------------------------------------------------------------------------
# STEP 7 — Configure AppRole auth
# --------------------------------------------------------------------------
section "Step 7 — Configuring Vault AppRole auth"

vault auth enable approle 2>/dev/null && \
  log "AppRole auth enabled ✅" || \
  log "AppRole auth already enabled ✅"

# Create policy
vault policy write external-secrets-policy - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
EOF
log "external-secrets-policy created ✅"

# Create role
vault write auth/approle/role/external-secrets \
  token_policies="external-secrets-policy" \
  token_ttl=24h \
  token_max_ttl=48h
log "AppRole role created ✅"

# Get credentials
ROLE_ID=$(vault read -field=role_id auth/approle/role/external-secrets/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/external-secrets/secret-id)

log "Role ID:   ${ROLE_ID}"
log "Secret ID: ${SECRET_ID}"

# --------------------------------------------------------------------------
# STEP 8 — Update Kubernetes secret for AppRole
# --------------------------------------------------------------------------
section "Step 8 — Updating Kubernetes vault-approle secret"

kubectl delete secret vault-approle \
  -n ${EXTERNAL_SECRETS_NAMESPACE} 2>/dev/null || true

kubectl create secret generic vault-approle \
  --namespace=${EXTERNAL_SECRETS_NAMESPACE} \
  --from-literal=secret-id="${SECRET_ID}"

log "vault-approle secret created in ${EXTERNAL_SECRETS_NAMESPACE} ✅"

# --------------------------------------------------------------------------
# STEP 9 — Patch all CRD ownership labels (prevents Helm errors)
# --------------------------------------------------------------------------
section "Step 9 — Patching CRD ownership labels"

log "Patching External Secrets CRDs..."
for crd in $(kubectl get crd 2>/dev/null | grep external-secrets.io | awk '{print $1}'); do
  kubectl label crd $crd app.kubernetes.io/managed-by=Helm --overwrite &>/dev/null
  kubectl annotate crd $crd \
    meta.helm.sh/release-name=external-secrets \
    meta.helm.sh/release-namespace=external-secrets \
    --overwrite &>/dev/null
done
log "External Secrets CRDs patched ✅"

log "Patching Kyverno CRDs..."
for crd in $(kubectl get crd 2>/dev/null | grep -E "kyverno.io|wgpolicyk8s.io" | awk '{print $1}'); do
  kubectl label crd $crd app.kubernetes.io/managed-by=Helm --overwrite &>/dev/null
  kubectl annotate crd $crd \
    meta.helm.sh/release-name=kyverno \
    meta.helm.sh/release-namespace=kyverno \
    --overwrite &>/dev/null
done
log "Kyverno CRDs patched ✅"

# --------------------------------------------------------------------------
# STEP 10 — Run security setup script
# --------------------------------------------------------------------------
section "Step 10 — Running security setup"

if [[ -f "$COSIGN_PUB_FILE" ]]; then
  COSIGN_FLAG="--cosign-public-key-file ${COSIGN_PUB_FILE}"
else
  COSIGN_FLAG=""
  warn "cosign.pub not found — running without cosign public key flag"
fi

./scripts/k8s/start-security.sh \
  ${COSIGN_FLAG} \
  --vault-approle-role-id "${ROLE_ID}" \
  --vault-approle-secret-id "${SECRET_ID}"

# --------------------------------------------------------------------------
# STEP 11 — Force ExternalSecrets resync
# --------------------------------------------------------------------------
section "Step 11 — Forcing ExternalSecrets resync"

sleep 10  # Give external-secrets time to pick up new config

for es in cosign-key docker-credentials sonarqube-credentials; do
  kubectl annotate externalsecret ${es} \
    force-sync=$(date +%s) --overwrite \
    -n ${K8S_SECRET_NAMESPACE} 2>/dev/null && \
    log "Annotated ${es} ✅" || \
    warn "${es} not found — skipping"
done

log "Waiting 15 seconds for sync..."
sleep 15

kubectl get externalsecret -n ${K8S_SECRET_NAMESPACE}

# --------------------------------------------------------------------------
# DONE
# --------------------------------------------------------------------------
section "Setup Complete"

echo ""
log "Vault is running at: http://127.0.0.1:${VAULT_PORT}"
log "Vault token: ${VAULT_ROOT_TOKEN}"
log ""
log "To use Vault CLI in any terminal:"
echo "  export VAULT_ADDR=http://127.0.0.1:${VAULT_PORT}"
echo "  export VAULT_TOKEN=${VAULT_ROOT_TOKEN}"
echo ""
log "To restart port-forward after terminal close:"
echo "  kubectl port-forward svc/vault ${VAULT_PORT}:${VAULT_PORT} -n ${VAULT_NAMESPACE} &"
echo ""

# Show final status
kubectl get secret cosign-key docker-credentials -n ${K8S_SECRET_NAMESPACE} 2>/dev/null || \
  warn "Some secrets not yet created — check ExternalSecret status above"

kubectl get clustersecretstore vault-backend 2>/dev/null || true