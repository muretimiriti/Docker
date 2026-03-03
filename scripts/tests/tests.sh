#!/bin/bash
set -e

echo "[tests] starting..."

if [[ -f ".env" ]]; then
  echo "[tests] loading environment from .env"
  # shellcheck disable=SC1091
  source ".env"
else
  echo "[tests] .env not found, continuing with existing environment"
fi

echo "[tests] node: $(node -v 2>/dev/null || echo 'not found')"
echo "[tests] npm:  $(npm -v 2>/dev/null || echo 'not found')"

echo "[tests] running test suite..."
echo "[tests] command: npm test"
npm test

echo "[tests] running perf check..."
echo "[tests] command: npm run perf"
npm run perf

echo "[tests] done."

