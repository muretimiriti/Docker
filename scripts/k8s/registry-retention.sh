#!/bin/bash
set -euo pipefail

REPO="${REPO:-sample-node-app}"
REGISTRY_URL="${REGISTRY_URL:-http://localhost:5000}"
KEEP="${KEEP:-5}"
DRY_RUN="false"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/registry-retention.sh [options]

Deletes older local registry tags and keeps the newest N tags.
Requires registry API delete support.

Options:
  --repo <name>       Repository name (default: sample-node-app)
  --registry-url <u>  Registry URL (default: http://localhost:5000)
  --keep <n>          Number of recent tags to keep (default: 5)
  --dry-run           Show what would be deleted
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"; shift 2 ;;
    --registry-url)
      REGISTRY_URL="$2"; shift 2 ;;
    --keep)
      KEEP="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

tags_json="$(curl -fsS "$REGISTRY_URL/v2/$REPO/tags/list")"
tags="$(echo "$tags_json" | jq -r '.tags[]?' | sort -r)"

count=0
while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  count=$((count + 1))
  if (( count <= KEEP )); then
    continue
  fi

  digest="$(curl -fsSI -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "$REGISTRY_URL/v2/$REPO/manifests/$tag" | awk -F': ' '/Docker-Content-Digest/ {gsub("\r", "", $2); print $2; exit}')"

  if [[ -z "$digest" ]]; then
    echo "[registry-retention] could not resolve digest for tag=$tag"
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[registry-retention] dry-run delete tag=$tag digest=$digest"
    continue
  fi

  echo "[registry-retention] deleting tag=$tag digest=$digest"
  curl -fsS -X DELETE "$REGISTRY_URL/v2/$REPO/manifests/$digest" >/dev/null || true
done <<<"$tags"

echo "[registry-retention] done"
