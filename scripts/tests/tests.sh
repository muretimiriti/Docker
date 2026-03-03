#!/bin/bash
set -e

RUN_PERF="true"

usage() {
  cat <<'USAGE'
Usage: ./scripts/tests/tests.sh [options]

Runs unit tests, integration tests, and perf checks.

Options:
  --skip-perf        Skip perf check
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-perf)
      RUN_PERF="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[tests] unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

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

echo "[tests] running integration suite..."
echo "[tests] command: npm run test:integration"
npm run test:integration

if [[ "$RUN_PERF" == "true" ]]; then
  echo "[tests] running perf check..."
  echo "[tests] command: npm run perf"
  npm run perf
else
  echo "[tests] skipping perf check (--skip-perf)"
fi

echo "[tests] done."
