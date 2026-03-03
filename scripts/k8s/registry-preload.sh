#!/bin/bash
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/registry-preload.sh --image <image-ref>

Preloads an image into Docker Desktop kind nodes (desktop-worker/control-plane)
so Kubernetes can run it without relying on external registry reachability.
USAGE
}

die() {
  echo "[registry-preload] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      [[ $# -ge 2 ]] || die "Missing value for --image"
      IMAGE_REF="$2"
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

[[ -n "$IMAGE_REF" ]] || die "--image is required"
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  if [[ "$IMAGE_REF" =~ ^host\.docker\.internal:5000/(.+)$ ]]; then
    alt_ref="localhost:5000/${BASH_REMATCH[1]}"
    docker pull "$alt_ref" >/dev/null
    docker tag "$alt_ref" "$IMAGE_REF"
  else
    docker pull "$IMAGE_REF" >/dev/null
  fi
fi

nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
while IFS= read -r node; do
  [[ -n "$node" ]] || continue
  if docker ps --format '{{.Names}}' | grep -Fxq "$node"; then
    echo "[registry-preload] loading $IMAGE_REF into $node"
    docker save "$IMAGE_REF" | docker exec -i "$node" ctr -n k8s.io images import - >/dev/null
  fi
done <<<"$nodes"

echo "[registry-preload] done"
