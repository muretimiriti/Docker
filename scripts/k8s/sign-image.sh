#!/bin/bash
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-}"
KEY_REF="${COSIGN_KEY_REF:-}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/sign-image.sh --image <image-ref> [--key <cosign-key-ref>]

Signs a container image with cosign.

Options:
  --image <ref>     Required image reference (including tag or digest)
  --key <ref>       Cosign key reference (default: env COSIGN_KEY_REF)
  -h, --help        Show this help

Environment:
  COSIGN_KEY_REF    Key reference if --key is not provided
USAGE
}

die() {
  echo "[cosign] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      [[ $# -ge 2 ]] || die "Missing value for --image"
      IMAGE_REF="$2"
      shift 2
      ;;
    --key)
      [[ $# -ge 2 ]] || die "Missing value for --key"
      KEY_REF="$2"
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

command -v cosign >/dev/null 2>&1 || die "cosign not found on PATH"
[[ -n "$IMAGE_REF" ]] || die "--image is required"
[[ -n "$KEY_REF" ]] || die "--key is required (or set COSIGN_KEY_REF)"

echo "[cosign] signing image: $IMAGE_REF"
cosign sign --yes --key "$KEY_REF" "$IMAGE_REF"
echo "[cosign] done"
