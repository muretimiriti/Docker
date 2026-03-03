#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENVIRONMENT="dev"
TARGET_COMMIT=""
AUTO_PUSH="false"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-tech-stack}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/gitops-rollback.sh [options]

Performs a GitOps-native rollback by reverting commit(s) and refreshing ArgoCD.

Options:
  --env <dev|staging|prod>    Environment overlay to inspect (default: dev)
  --commit <sha>              Explicit commit to revert (default: last commit touching env overlay)
  --push                      Push rollback commit to origin/<current-branch>
  --argocd-namespace <ns>     ArgoCD namespace (default: argocd)
  --app-name <name>           ArgoCD application name (default: tech-stack)
  -h, --help                  Show help
USAGE
}

log() { echo "[gitops-rollback] $*"; }
die() { echo "[gitops-rollback] $*" >&2; exit 1; }

overlay_file() {
  local env="$1"
  printf '%s\n' "$ROOT_DIR/manifests/gitops/overlays/$env/kustomization.yaml"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "Missing value for --env"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --commit)
      [[ $# -ge 2 ]] || die "Missing value for --commit"
      TARGET_COMMIT="$2"
      shift 2
      ;;
    --push)
      AUTO_PUSH="true"
      shift
      ;;
    --argocd-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --argocd-namespace"
      ARGOCD_NAMESPACE="$2"
      shift 2
      ;;
    --app-name)
      [[ $# -ge 2 ]] || die "Missing value for --app-name"
      ARGOCD_APP_NAME="$2"
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

case "$ENVIRONMENT" in
  dev|staging|prod) ;;
  *) die "Unsupported environment '$ENVIRONMENT'" ;;
esac

command -v git >/dev/null 2>&1 || die "git not found"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  die "Working tree is dirty. Commit/stash changes before rollback."
fi

file_path="$(overlay_file "$ENVIRONMENT")"
[[ -f "$file_path" ]] || die "Overlay file not found: $file_path"

if [[ -z "$TARGET_COMMIT" ]]; then
  TARGET_COMMIT="$(git -C "$ROOT_DIR" log -n 1 --format=%H -- "$file_path" 2>/dev/null || true)"
fi
[[ -n "$TARGET_COMMIT" ]] || die "Unable to resolve commit to revert"

git -C "$ROOT_DIR" rev-parse --verify "${TARGET_COMMIT}^{commit}" >/dev/null 2>&1 || die "Invalid commit: $TARGET_COMMIT"

log "reverting commit $TARGET_COMMIT"
git -C "$ROOT_DIR" revert --no-edit "$TARGET_COMMIT"

if [[ "$AUTO_PUSH" == "true" ]]; then
  current_branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  log "pushing rollback commit to origin/$current_branch"
  git -C "$ROOT_DIR" push origin "$current_branch"
fi

if kubectl -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" >/dev/null 2>&1; then
  log "refreshing ArgoCD application $ARGOCD_APP_NAME"
  kubectl -n "$ARGOCD_NAMESPACE" annotate application "$ARGOCD_APP_NAME" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
fi

log "rollback commit created successfully"
