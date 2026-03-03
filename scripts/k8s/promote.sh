#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FROM_ENV="dev"
TO_ENV="staging"
IMAGE_TAG=""
AUTO_COMMIT="false"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/promote.sh [options]

Promotes the sample-node-app image tag between environment overlays:
  manifests/gitops/overlays/dev/kustomization.yaml
  manifests/gitops/overlays/staging/kustomization.yaml
  manifests/gitops/overlays/prod/kustomization.yaml

Options:
  --from <env>        Source env overlay (dev|staging|prod). Default: dev
  --to <env>          Target env overlay (dev|staging|prod). Default: staging
  --tag <tag>         Explicit image tag. If omitted, reads source overlay tag.
  --commit            Create a git commit with the promotion update.
  -h, --help          Show this help
USAGE
}

log() {
  echo "[promote] $*"
}

die() {
  echo "[promote] $*" >&2
  exit 1
}

overlay_file() {
  local env="$1"
  printf '%s\n' "$ROOT_DIR/manifests/gitops/overlays/$env/kustomization.yaml"
}

read_value() {
  local file="$1"
  local key="$2"
  awk -F'[:=]' -v k="$key" '
    {
      gsub(/[[:space:]]+/, "", $1);
      if ($1 == k) {
        value=$2;
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value);
        print value;
        exit;
      }
    }
  ' "$file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -ge 2 ]] || die "Missing value for --from"
      FROM_ENV="$2"
      shift 2
      ;;
    --to)
      [[ $# -ge 2 ]] || die "Missing value for --to"
      TO_ENV="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "Missing value for --tag"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --commit)
      AUTO_COMMIT="true"
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

case "$FROM_ENV" in dev|staging|prod) ;; *) die "Unsupported --from env: $FROM_ENV" ;; esac
case "$TO_ENV" in dev|staging|prod) ;; *) die "Unsupported --to env: $TO_ENV" ;; esac
[[ "$FROM_ENV" != "$TO_ENV" ]] || die "--from and --to must be different"

src_file="$(overlay_file "$FROM_ENV")"
dst_file="$(overlay_file "$TO_ENV")"
[[ -f "$src_file" ]] || die "Source overlay not found: $src_file"
[[ -f "$dst_file" ]] || die "Target overlay not found: $dst_file"

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="$(read_value "$src_file" "newTag")"
fi
[[ -n "$IMAGE_TAG" ]] || die "Unable to resolve image tag (use --tag)"

log "promoting image tag '$IMAGE_TAG' from $FROM_ENV to $TO_ENV"

awk -v tag="$IMAGE_TAG" '
  /^([[:space:]]*)newTag:/ {
    indent="";
    match($0, /^([[:space:]]*)/, m);
    if (m[1] != "") indent=m[1];
    print indent "newTag: " tag;
    next;
  }
  { print }
' "$dst_file" > "$dst_file.tmp"
mv "$dst_file.tmp" "$dst_file"

# Keep optional env helper files in sync when present.
dst_env_file="$ROOT_DIR/manifests/environments/$TO_ENV.env"
if [[ -f "$dst_env_file" ]]; then
  awk -F'=' -v tag="$IMAGE_TAG" '
    BEGIN { OFS="=" }
    $1 == "IMAGE_TAG" { $2 = tag }
    { print }
  ' "$dst_env_file" > "$dst_env_file.tmp"
  mv "$dst_env_file.tmp" "$dst_env_file"
fi

if [[ "$AUTO_COMMIT" == "true" ]]; then
  git -C "$ROOT_DIR" add "$dst_file"
  git -C "$ROOT_DIR" commit -m "chore: promote sample-node-app to $TO_ENV ($IMAGE_TAG)"
  log "created commit for promotion"
fi

log "done"
log "next: ./scripts/k8s/start-argo.sh --env $TO_ENV"
