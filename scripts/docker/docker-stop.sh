#!/bin/bash
set -e

usage() {
  cat <<'USAGE'
Usage: ./scripts/docker/docker-stop.sh

Stops docker compose services.
Prefers `docker compose` and falls back to `docker-compose`.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

echo "[stop] starting..."

if ! command -v docker >/dev/null 2>&1; then
  echo "[stop] docker not found on PATH" >&2
  exit 127
fi

# Prefer the v2 plugin (`docker compose`), fallback to legacy `docker-compose`.
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "[stop] neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 127
fi

if [[ -f ".env" ]]; then
  echo "[stop] loading environment from .env"
  # shellcheck disable=SC1091
  source ".env"
else
  echo "[stop] .env not found, continuing with existing environment"
fi

echo "[stop] bringing down docker compose services..."
echo "[stop] command: ${COMPOSE[*]} down"
exec "${COMPOSE[@]}" down
