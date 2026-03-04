#!/bin/bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
JWT_PATH="${JWT_PATH:-jwt}"
JWT_ROLE_NAME="${JWT_ROLE_NAME:-external-secrets}"
JWT_POLICY_NAME="${JWT_POLICY_NAME:-external-secrets-read}"
JWT_BOUND_AUDIENCE="${JWT_BOUND_AUDIENCE:-vault}"
JWT_USER_CLAIM="${JWT_USER_CLAIM:-sub}"
JWT_OIDC_DISCOVERY_URL="${JWT_OIDC_DISCOVERY_URL:-}"
JWT_BOUND_ISSUER="${JWT_BOUND_ISSUER:-}"
SECRET_PATH_PREFIX="${SECRET_PATH_PREFIX:-kv/data/ci/*}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/vault-bootstrap-jwt.sh [options]

Bootstraps Vault JWT auth for External Secrets (OIDC/JWT mode).

Required env:
  VAULT_ADDR
  VAULT_TOKEN
  JWT_OIDC_DISCOVERY_URL
  JWT_BOUND_ISSUER

Options:
  --jwt-path <path>               Vault JWT auth path (default: jwt)
  --jwt-role <name>               JWT role name (default: external-secrets)
  --jwt-policy <name>             Vault policy name (default: external-secrets-read)
  --jwt-bound-audience <aud>      Bound audience (default: vault)
  --jwt-user-claim <claim>        User claim (default: sub)
  --oidc-discovery-url <url>      OIDC discovery URL
  --bound-issuer <issuer>         JWT issuer
  --secret-path-prefix <path>     Vault KV v2 data path pattern (default: kv/data/ci/*)
  -h, --help                      Show help
USAGE
}

log() { echo "[vault-jwt] $*"; }
die() { echo "[vault-jwt] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jwt-path) JWT_PATH="$2"; shift 2 ;;
    --jwt-role) JWT_ROLE_NAME="$2"; shift 2 ;;
    --jwt-policy) JWT_POLICY_NAME="$2"; shift 2 ;;
    --jwt-bound-audience) JWT_BOUND_AUDIENCE="$2"; shift 2 ;;
    --jwt-user-claim) JWT_USER_CLAIM="$2"; shift 2 ;;
    --oidc-discovery-url) JWT_OIDC_DISCOVERY_URL="$2"; shift 2 ;;
    --bound-issuer) JWT_BOUND_ISSUER="$2"; shift 2 ;;
    --secret-path-prefix) SECRET_PATH_PREFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is required"
[[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is required"
[[ -n "$JWT_OIDC_DISCOVERY_URL" ]] || die "JWT_OIDC_DISCOVERY_URL is required"
[[ -n "$JWT_BOUND_ISSUER" ]] || die "JWT_BOUND_ISSUER is required"

export VAULT_ADDR VAULT_TOKEN

if ! vault auth list -format=json | jq -e ".\"${JWT_PATH}/\"" >/dev/null 2>&1; then
  log "enabling JWT auth at ${JWT_PATH}/"
  vault auth enable -path="$JWT_PATH" jwt >/dev/null
fi

log "configuring JWT auth backend"
vault write "auth/${JWT_PATH}/config" \
  oidc_discovery_url="$JWT_OIDC_DISCOVERY_URL" \
  bound_issuer="$JWT_BOUND_ISSUER" >/dev/null

log "writing policy $JWT_POLICY_NAME"
cat <<POLICY | vault policy write "$JWT_POLICY_NAME" - >/dev/null
path "$SECRET_PATH_PREFIX" {
  capabilities = ["read", "list"]
}
POLICY

log "writing JWT role $JWT_ROLE_NAME"
vault write "auth/${JWT_PATH}/role/${JWT_ROLE_NAME}" \
  role_type="jwt" \
  user_claim="$JWT_USER_CLAIM" \
  bound_audiences="$JWT_BOUND_AUDIENCE" \
  token_policies="$JWT_POLICY_NAME" \
  token_ttl=1h \
  token_max_ttl=24h >/dev/null

log "done"
