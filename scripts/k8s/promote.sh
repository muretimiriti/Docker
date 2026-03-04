#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FROM_ENV="dev"
TO_ENV="staging"
IMAGE_TAG=""
AUTO_COMMIT="false"
REQUIRE_CHECKS="true"
REQUIRE_APPROVAL="auto"
APPROVED="false"
TEKTON_NAMESPACE="${TEKTON_NAMESPACE:-default}"
SMOKE_PATH="${SMOKE_PATH:-/healthz}"
VERIFY_PUSH="false"

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
  --verify-push       Ensure current branch is pushed before promotion update.
  --skip-checks       Skip Tekton+smoke prechecks.
  --require-approval  Always require explicit --approved flag.
  --approved          Mark promotion as approved for guarded envs.
  --smoke-path <p>    Smoke path used by precheck (default: /healthz).
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

read_env_value() {
  local file="$1"
  local key="$2"
  awk -F'=' -v k="$key" '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1);
      if ($1 == k) {
        value=$2;
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value);
        print value;
        exit;
      }
    }
  ' "$file"
}

require_clean_git_state() {
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    die "Working tree is dirty. Commit/stash changes before promotion."
  fi
}

verify_branch_is_pushed() {
  local branch local_sha remote_sha
  branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  local_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  git -C "$ROOT_DIR" fetch --quiet origin "$branch" >/dev/null 2>&1 || true
  remote_sha="$(git -C "$ROOT_DIR" rev-parse "origin/$branch" 2>/dev/null || true)"
  [[ -n "$remote_sha" ]] || die "origin/$branch not found; push branch first"
  [[ "$local_sha" == "$remote_sha" ]] || die "Local branch is ahead/behind origin/$branch. Push/pull before promotion."
}

ensure_latest_tekton_succeeded() {
  local latest_name status
  latest_name="$(kubectl -n "$TEKTON_NAMESPACE" get pipelineruns.tekton.dev --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  [[ -n "$latest_name" ]] || die "No Tekton PipelineRuns found in namespace $TEKTON_NAMESPACE"
  status="$(kubectl -n "$TEKTON_NAMESPACE" get pipelinerun "$latest_name" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
  [[ "$status" == "True" ]] || die "Latest Tekton PipelineRun '$latest_name' is not successful"
  log "Tekton precheck passed with PipelineRun $latest_name"
}

run_smoke_check() {
  local namespace="$1"
  local service_name="$2"
  local path="$3"
  local job_name="promote-smoke-${service_name}-$(date +%s)"

  kubectl -n "$namespace" create job "$job_name" --image=curlimages/curl:8.10.1 \
    -- sh -c "curl -fsS \"http://${service_name}:3001${path}\" >/dev/null" >/dev/null

  if ! kubectl -n "$namespace" wait --for=condition=complete "job/$job_name" --timeout=90s >/dev/null 2>&1; then
    kubectl -n "$namespace" logs "job/$job_name" >/dev/null 2>&1 || true
    kubectl -n "$namespace" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
    die "Smoke precheck failed against http://${service_name}:3001${path} in namespace $namespace"
  fi

  kubectl -n "$namespace" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
  log "Smoke precheck passed for $service_name ($namespace)"
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
    --verify-push)
      VERIFY_PUSH="true"
      shift
      ;;
    --skip-checks)
      REQUIRE_CHECKS="false"
      shift
      ;;
    --require-approval)
      REQUIRE_APPROVAL="true"
      shift
      ;;
    --approved)
      APPROVED="true"
      shift
      ;;
    --smoke-path)
      [[ $# -ge 2 ]] || die "Missing value for --smoke-path"
      SMOKE_PATH="$2"
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

case "$FROM_ENV" in dev|staging|prod) ;; *) die "Unsupported --from env: $FROM_ENV" ;; esac
case "$TO_ENV" in dev|staging|prod) ;; *) die "Unsupported --to env: $TO_ENV" ;; esac
[[ "$FROM_ENV" != "$TO_ENV" ]] || die "--from and --to must be different"

if [[ "$REQUIRE_APPROVAL" == "auto" ]]; then
  if [[ "$TO_ENV" == "staging" || "$TO_ENV" == "prod" ]]; then
    REQUIRE_APPROVAL="true"
  else
    REQUIRE_APPROVAL="false"
  fi
fi
case "$REQUIRE_APPROVAL" in true|false) ;; *) die "Invalid approval mode" ;; esac

command -v git >/dev/null 2>&1 || die "git not found on PATH"
require_clean_git_state

if [[ "$VERIFY_PUSH" == "true" ]]; then
  verify_branch_is_pushed
fi

src_file="$(overlay_file "$FROM_ENV")"
dst_file="$(overlay_file "$TO_ENV")"
[[ -f "$src_file" ]] || die "Source overlay not found: $src_file"
[[ -f "$dst_file" ]] || die "Target overlay not found: $dst_file"

if [[ "$REQUIRE_APPROVAL" == "true" && "$APPROVED" != "true" ]]; then
  die "Promotion to '$TO_ENV' requires explicit approval. Re-run with --approved."
fi

src_env_file="$ROOT_DIR/manifests/environments/$FROM_ENV.env"
if [[ "$REQUIRE_CHECKS" == "true" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
  ensure_latest_tekton_succeeded
  src_ns="default"
  if [[ -f "$src_env_file" ]]; then
    src_ns="$(read_env_value "$src_env_file" "DEPLOY_NAMESPACE")"
    src_ns="${src_ns:-default}"
  fi
  run_smoke_check "$src_ns" "sample-node-app" "$SMOKE_PATH"
fi

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
  [[ -f "$dst_env_file" ]] && git -C "$ROOT_DIR" add "$dst_env_file"
  git -C "$ROOT_DIR" commit -m "chore: promote sample-node-app to $TO_ENV ($IMAGE_TAG)"
  log "created commit for promotion"
fi

log "done"
log "next: ./scripts/k8s/start-argo.sh --env $TO_ENV"
