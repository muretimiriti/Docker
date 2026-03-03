#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENVIRONMENT="dev"
RELEASE_NAME="sample-node-app"
NAMESPACE="default"
IMAGE_TAG=""
DRY_RUN="false"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/start-helm-app.sh [options]

Deploy sample-node-app using Helm values overlays.

Options:
  --env <dev|staging|prod>   Values file to use (default: dev)
  --release <name>           Helm release name (default: sample-node-app)
  --namespace <ns>           Target namespace (default: default)
  --image-tag <tag>          Override image tag
  --dry-run                  Render/validate only
  -h, --help                 Show help
USAGE
}

log() { echo "[helm-app] $*"; }
die() { echo "[helm-app] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "Missing value for --env"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || die "Missing value for --release"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"
      shift 2
      ;;
    --image-tag)
      [[ $# -ge 2 ]] || die "Missing value for --image-tag"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
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

command -v helm >/dev/null 2>&1 || die "helm not found"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

chart_dir="$ROOT_DIR/charts/sample-node-app"
values_file="$chart_dir/values-${ENVIRONMENT}.yaml"
[[ -f "$values_file" ]] || die "Values file not found: $values_file"

args=(upgrade --install "$RELEASE_NAME" "$chart_dir" -n "$NAMESPACE" --create-namespace -f "$chart_dir/values.yaml" -f "$values_file")
if [[ -n "$IMAGE_TAG" ]]; then
  args+=(--set "image.tag=$IMAGE_TAG")
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "running helm dry-run"
  helm "${args[@]}" --dry-run
else
  log "deploying release $RELEASE_NAME to namespace $NAMESPACE"
  helm "${args[@]}"
fi
