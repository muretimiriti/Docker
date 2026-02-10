#!/bin/bash
set -e

echo "[run] starting..."

if ! command -v docker >/dev/null 2>&1; then
  echo "[run] docker not found on PATH" >&2
  exit 127
fi

# Prefer the v2 plugin (`docker compose`), fallback to legacy `docker-compose`.
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "[run] neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 127
fi

if [[ -f ".env" ]]; then
  echo "[run] loading environment from .env"
  # shellcheck disable=SC1091
  source ".env"
else
  echo "[run] .env not found, continuing with existing environment"
fi

echo "[run] bringing up docker compose services..."
echo "[run] command: ${COMPOSE[*]} up --build"
exec "${COMPOSE[@]}" up --build
