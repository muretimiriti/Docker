#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${ARGOCD_APP_NAME:-tech-stack}"
PROJECT_NAME="${ARGOCD_PROJECT:-default}"
DEST_NAMESPACE="${ARGOCD_DEST_NAMESPACE:-default}"
TARGET_REVISION="${ARGOCD_TARGET_REVISION:-HEAD}"
APP_PATH="${ARGOCD_APP_PATH:-manifests/gitops/overlays/dev}"
TEKTON_NAMESPACE="${TEKTON_NAMESPACE:-default}"
DEPLOYMENT_NAME="${ARGOCD_DEPLOYMENT_NAME:-sample-node-app}"
IMAGE_REFERENCE="${IMAGE_REFERENCE:-}"
INSTALL_ARGOCD="false"
WAIT_ROLLOUT="true"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"
GITOPS_SYNC="true"
NOTIFY_WEBHOOK_URL="${ARGO_NOTIFY_WEBHOOK_URL:-}"
ENVIRONMENT="${ARGOCD_ENVIRONMENT:-}"
SMOKE_TEST_ENABLED="true"
SMOKE_PATH="${SMOKE_PATH:-/healthz}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-120s}"
AUTO_ROLLBACK_ON_FAILURE="true"
ROLLBACK_MODE="${ARGOCD_ROLLBACK_MODE:-kubernetes}"
SKIP_PATH_PREFLIGHT="false"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/start-argo.sh [options]

Creates/updates an ArgoCD Application for this repo, selects an image, and deploys to the cluster.

Image selection priority:
1) --image <ref>
2) IMAGE_REFERENCE env
3) latest successful Tekton PipelineRun param: image-reference
4) image currently in manifests/apps/sample-node-app/deployment.yaml

Options:
  --image <ref>             Full image reference (example: ghcr.io/org/app:sha123)
  --repo-url <url>          Git repository URL for ArgoCD source (default: git remote origin)
  --revision <rev>          Git revision/branch/tag to deploy (default: HEAD)
  --path <path>             Repo path for manifests (default: manifests/gitops/overlays/dev)
  --env <dev|staging|prod>  Use environment config from manifests/environments/<env>.env
  --app-name <name>         ArgoCD Application name (default: tech-stack)
  --project <name>          ArgoCD project name (default: default)
  --argocd-namespace <ns>   Namespace where ArgoCD runs (default: argocd)
  --dest-namespace <ns>     Namespace for workload deployment (default: default)
  --tekton-namespace <ns>   Namespace used to discover PipelineRuns (default: default)
  --deployment <name>       Deployment to verify rollout for (default: sample-node-app)
  --install-argocd          Install ArgoCD core manifests into argocd namespace
  --no-sync                 Disable ArgoCD automated sync policy
  --no-wait                 Do not wait for deployment rollout
  --wait-timeout <dur>      Rollout wait timeout (default: 180s)
  --notify-webhook-url <u>  Optional webhook URL for deploy success/failure notifications
  --smoke-path <path>       HTTP path for post-deploy smoke test (default: /healthz)
  --skip-smoke              Skip post-deploy smoke test
  --no-auto-rollback        Disable rollback when rollout/smoke test fails
  --rollback-mode <mode>    Rollback mode: kubernetes|gitops (default: kubernetes)
  --skip-path-preflight     Skip git revision/path existence check before apply
  -h, --help                Show this help

Environment:
  IMAGE_REFERENCE           Same as --image
  ARGOCD_*                  Defaults for key options (see script variables)
  TEKTON_NAMESPACE          Default namespace for Tekton PipelineRun discovery
  ARGO_NOTIFY_WEBHOOK_URL   Same as --notify-webhook-url
  ARGOCD_ENVIRONMENT        Same as --env
  ARGOCD_ROLLBACK_MODE      Same as --rollback-mode
USAGE
}

log() {
  echo "[argocd] $*"
}

die() {
  echo "[argocd] $*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd not found on PATH"
  fi
}

notify() {
  local status="$1"
  local message="$2"
  [[ -n "$NOTIFY_WEBHOOK_URL" ]] || return 0

  if command -v curl >/dev/null 2>&1; then
    curl -fsS -X POST "$NOTIFY_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"component\":\"argocd\",\"app\":\"$APP_NAME\",\"status\":\"$status\",\"message\":\"$message\"}" >/dev/null || true
  fi
}

argocd_failure_message() {
  kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" \
    -o jsonpath='{.status.operationState.message}' 2>/dev/null || true
}

is_local_registry_image() {
  local image_ref="$1"
  [[ "$image_ref" =~ ^(host\.docker\.internal|localhost):[0-9]+/ ]]
}

ensure_local_image_in_kind_nodes() {
  local image_ref="$1"
  local alt_ref node node_list

  is_local_registry_image "$image_ref" || return 0
  require_command docker

  if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
    if [[ "$image_ref" =~ ^host\.docker\.internal:5000/(.+)$ ]]; then
      alt_ref="localhost:5000/${BASH_REMATCH[1]}"
      log "pulling image via localhost mirror: $alt_ref"
      docker pull "$alt_ref" >/dev/null
      docker tag "$alt_ref" "$image_ref"
    else
      log "pulling image: $image_ref"
      docker pull "$image_ref" >/dev/null
    fi
  fi

  node_list="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$node"; then
      continue
    fi
    log "loading image into node: $node"
    docker save "$image_ref" | docker exec -i "$node" ctr -n k8s.io images import - >/dev/null
  done <<<"$node_list"
}

duration_to_seconds() {
  local value="$1"
  if [[ "$value" =~ ^([0-9]+)s$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$value" =~ ^([0-9]+)m$ ]]; then
    printf '%s\n' "$((BASH_REMATCH[1] * 60))"
    return
  fi
  if [[ "$value" =~ ^([0-9]+)h$ ]]; then
    printf '%s\n' "$((BASH_REMATCH[1] * 3600))"
    return
  fi
  die "Unsupported duration format '$value'. Use Ns, Nm, or Nh (example: 180s, 3m)"
}

wait_for_deployment_exists() {
  local namespace="$1"
  local deployment_name="$2"
  local timeout="$3"
  local timeout_seconds elapsed

  timeout_seconds="$(duration_to_seconds "$timeout")"
  elapsed=0

  while ! kubectl -n "$namespace" get deployment "$deployment_name" >/dev/null 2>&1; do
    if (( elapsed >= timeout_seconds )); then
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
}

run_smoke_test() {
  local namespace="$1"
  local deployment_name="$2"
  local path="$3"
  local timeout="$4"
  local timeout_seconds
  local job_name

  timeout_seconds="$(duration_to_seconds "$timeout")"
  job_name="smoke-${deployment_name}-$(date +%s)"

  kubectl -n "$namespace" create job "$job_name" --image=curlimages/curl:8.10.1 \
    -- sh -c "curl -fsS \"http://${deployment_name}:3001${path}\" >/dev/null" >/dev/null

  if ! kubectl -n "$namespace" wait --for=condition=complete "job/$job_name" --timeout="${timeout_seconds}s" >/dev/null 2>&1; then
    kubectl -n "$namespace" logs "job/$job_name" >/dev/null 2>&1 || true
    kubectl -n "$namespace" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi

  kubectl -n "$namespace" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
  return 0
}

rollback_deployment() {
  local namespace="$1"
  local deployment_name="$2"
  if [[ "$AUTO_ROLLBACK_ON_FAILURE" == "true" ]]; then
    if [[ "$ROLLBACK_MODE" == "gitops" ]]; then
      log "rollback mode is gitops; skipping kubectl rollout undo. Use ./scripts/k8s/gitops-rollback.sh for GitOps-native rollback."
      return 0
    fi
    log "rolling back deployment/$deployment_name with kubectl rollout undo"
    kubectl -n "$namespace" rollout undo "deployment/$deployment_name" >/dev/null 2>&1 || true
  fi
}

ensure_gitops_source_path_exists() {
  [[ "$SKIP_PATH_PREFLIGHT" == "false" ]] || return 0

  require_command git
  local source_remote resolved_ref
  source_remote="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)"

  if [[ -z "$source_remote" || "$source_remote" != "$REPO_URL" ]]; then
    log "skipping git path preflight because repoURL does not match local origin"
    return 0
  fi

  git -C "$ROOT_DIR" fetch --quiet origin >/dev/null 2>&1 || true

  if [[ "$TARGET_REVISION" == "HEAD" ]]; then
    resolved_ref="origin/HEAD"
  elif git -C "$ROOT_DIR" rev-parse --verify "origin/${TARGET_REVISION}^{commit}" >/dev/null 2>&1; then
    resolved_ref="origin/${TARGET_REVISION}"
  elif git -C "$ROOT_DIR" rev-parse --verify "${TARGET_REVISION}^{commit}" >/dev/null 2>&1; then
    resolved_ref="${TARGET_REVISION}"
  else
    die "Unable to resolve target revision '$TARGET_REVISION' locally. Push/fetch it first or pass --skip-path-preflight."
  fi

  if ! git -C "$ROOT_DIR" cat-file -e "${resolved_ref}:${APP_PATH}" 2>/dev/null; then
    die "Path '$APP_PATH' is missing in revision '$TARGET_REVISION' (${resolved_ref}). Push the path to that revision or change --revision/--path."
  fi
}

resolve_argocd_managed_deployments() {
  kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" \
    -o jsonpath='{range .status.resources[*]}{.kind}{"\t"}{.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '$1 == "Deployment" {print $2}'
}

extract_manifest_image() {
  local deployment_file image_line
  deployment_file="$ROOT_DIR/manifests/apps/sample-node-app/deployment.yaml"
  if [[ ! -f "$deployment_file" ]]; then
    deployment_file="$ROOT_DIR/manifests/k8s/node-app/deployment.yaml"
  fi
  image_line="$(awk '/image:/{print $2; exit}' "$deployment_file" 2>/dev/null || true)"
  printf '%s\n' "${image_line:-}"
}

resolve_latest_tekton_image() {
  local names pr_name status image_ref build_push_run
  names="$(kubectl -n "$TEKTON_NAMESPACE" get pipelineruns.tekton.dev --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  [[ -n "$names" ]] || return 0

  local -a arr=()
  while IFS= read -r pr_name; do
    [[ -n "$pr_name" ]] || continue
    arr+=("$pr_name")
  done <<<"$names"

  for ((idx=${#arr[@]} - 1; idx >= 0; idx--)); do
    pr_name="${arr[$idx]}"
    status="$(kubectl -n "$TEKTON_NAMESPACE" get pipelinerun "$pr_name" -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || true)"
    [[ "$status" == "True" ]] || continue

    # Prefer exact tagged image produced by the build-push TaskRun result.
    build_push_run="${pr_name}-build-push"
    image_ref="$(kubectl -n "$TEKTON_NAMESPACE" get taskrun "$build_push_run" -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}' 2>/dev/null || true)"
    if [[ -n "$image_ref" ]]; then
      printf '%s\n' "$image_ref"
      return 0
    fi

    # Fallback: pipeline param (base image name, often without tag).
    image_ref="$(kubectl -n "$TEKTON_NAMESPACE" get pipelinerun "$pr_name" -o jsonpath='{.spec.params[?(@.name=="image-reference")].value}' 2>/dev/null || true)"
    if [[ -n "$image_ref" ]]; then
      printf '%s\n' "$image_ref"
      return 0
    fi
  done
}

infer_repo_url() {
  git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true
}

ensure_namespace() {
  local ns="$1"
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    log "creating namespace $ns"
    kubectl create namespace "$ns"
  fi
}

install_argocd_if_requested() {
  [[ "$INSTALL_ARGOCD" == "true" ]] || return 0
  ensure_namespace "$ARGOCD_NAMESPACE"
  log "installing ArgoCD core components in namespace $ARGOCD_NAMESPACE"
  # Use server-side apply to avoid client-side last-applied annotation bloat on large CRDs.
  kubectl apply --server-side -n "$ARGOCD_NAMESPACE" -f "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
}

ensure_argocd_crd() {
  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$INSTALL_ARGOCD" != "true" ]]; then
    die "ArgoCD CRD applications.argoproj.io not found; rerun with --install-argocd"
  fi

  log "waiting for ArgoCD CRD applications.argoproj.io"
  kubectl wait --for=condition=Established --timeout=240s crd/applications.argoproj.io
}

build_application_manifest() {
  local sync_policy_block
  if [[ "$GITOPS_SYNC" == "true" ]]; then
    sync_policy_block="$(cat <<'EOF'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
)"
  else
    sync_policy_block=""
  fi

  local image_name image_tag image_no_digest image_tail
  image_no_digest="${RESOLVED_IMAGE%@*}"
  image_tail="${image_no_digest##*/}"
  if [[ "$image_tail" == *:* ]]; then
    image_name="${image_no_digest%:*}"
    image_tag="${image_no_digest##*:}"
  else
    image_name="$image_no_digest"
    image_tag="latest"
  fi

  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${PROJECT_NAME}
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: ${APP_PATH}
    kustomize:
      images:
        - ${image_name}=${image_name}:${image_tag} 
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEST_NAMESPACE}
${sync_policy_block}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      [[ $# -ge 2 ]] || die "Missing value for --image"
      IMAGE_REFERENCE="$2"
      shift 2
      ;;
    --repo-url)
      [[ $# -ge 2 ]] || die "Missing value for --repo-url"
      REPO_URL="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || die "Missing value for --revision"
      TARGET_REVISION="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || die "Missing value for --path"
      APP_PATH="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "Missing value for --env"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --app-name)
      [[ $# -ge 2 ]] || die "Missing value for --app-name"
      APP_NAME="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "Missing value for --project"
      PROJECT_NAME="$2"
      shift 2
      ;;
    --argocd-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --argocd-namespace"
      ARGOCD_NAMESPACE="$2"
      shift 2
      ;;
    --dest-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --dest-namespace"
      DEST_NAMESPACE="$2"
      shift 2
      ;;
    --tekton-namespace)
      [[ $# -ge 2 ]] || die "Missing value for --tekton-namespace"
      TEKTON_NAMESPACE="$2"
      shift 2
      ;;
    --deployment)
      [[ $# -ge 2 ]] || die "Missing value for --deployment"
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    --install-argocd)
      INSTALL_ARGOCD="true"
      shift
      ;;
    --no-sync)
      GITOPS_SYNC="false"
      shift
      ;;
    --no-wait)
      WAIT_ROLLOUT="false"
      shift
      ;;
    --wait-timeout)
      [[ $# -ge 2 ]] || die "Missing value for --wait-timeout"
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --notify-webhook-url)
      [[ $# -ge 2 ]] || die "Missing value for --notify-webhook-url"
      NOTIFY_WEBHOOK_URL="$2"
      shift 2
      ;;
    --smoke-path)
      [[ $# -ge 2 ]] || die "Missing value for --smoke-path"
      SMOKE_PATH="$2"
      shift 2
      ;;
    --skip-smoke)
      SMOKE_TEST_ENABLED="false"
      shift
      ;;
    --no-auto-rollback)
      AUTO_ROLLBACK_ON_FAILURE="false"
      shift
      ;;
    --rollback-mode)
      [[ $# -ge 2 ]] || die "Missing value for --rollback-mode"
      ROLLBACK_MODE="$2"
      shift 2
      ;;
    --skip-path-preflight)
      SKIP_PATH_PREFLIGHT="true"
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

case "$ROLLBACK_MODE" in
  kubernetes|gitops) ;;
  *) die "Unsupported --rollback-mode '$ROLLBACK_MODE' (use kubernetes|gitops)" ;;
esac

if [[ -n "$ENVIRONMENT" ]]; then
  case "$ENVIRONMENT" in
    dev|staging|prod) ;;
    *) die "Unsupported environment '$ENVIRONMENT' (use dev|staging|prod)" ;;
  esac

  APP_PATH="manifests/gitops/overlays/${ENVIRONMENT}"
  env_file="$ROOT_DIR/manifests/environments/${ENVIRONMENT}.env"
  [[ -f "$env_file" ]] || die "Environment config not found: $env_file"

  # shellcheck disable=SC1090
  source "$env_file"

  [[ "${DEST_NAMESPACE}" == "${ARGOCD_DEST_NAMESPACE:-default}" ]] && DEST_NAMESPACE="${DEPLOY_NAMESPACE:-$DEST_NAMESPACE}"
  [[ "$TARGET_REVISION" == "${ARGOCD_TARGET_REVISION:-HEAD}" ]] && TARGET_REVISION="${TARGET_GIT_REVISION:-$TARGET_REVISION}"
  if [[ -z "$IMAGE_REFERENCE" && -n "${IMAGE_BASE:-}" && -n "${IMAGE_TAG:-}" ]]; then
    IMAGE_REFERENCE="${IMAGE_BASE}:${IMAGE_TAG}"
  fi
fi

require_command kubectl

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; verify your kubectl context"
fi

if [[ -z "${REPO_URL:-}" ]]; then
  REPO_URL="$(infer_repo_url)"
fi
[[ -n "${REPO_URL:-}" ]] || die "Unable to determine repo URL; pass --repo-url"

if [[ -z "$IMAGE_REFERENCE" ]]; then
  IMAGE_REFERENCE="$(resolve_latest_tekton_image || true)"
fi
if [[ -z "$IMAGE_REFERENCE" ]]; then
  IMAGE_REFERENCE="$(extract_manifest_image)"
fi
[[ -n "$IMAGE_REFERENCE" ]] || die "Unable to resolve image reference; pass --image"

RESOLVED_IMAGE="$IMAGE_REFERENCE"

log "repoURL=$REPO_URL"
log "targetRevision=$TARGET_REVISION"
log "path=$APP_PATH"
log "selected image=$RESOLVED_IMAGE"
log "rollbackMode=$ROLLBACK_MODE"

ensure_gitops_source_path_exists

ensure_local_image_in_kind_nodes "$RESOLVED_IMAGE"

ensure_namespace "$DEST_NAMESPACE"
install_argocd_if_requested
ensure_argocd_crd
ensure_namespace "$ARGOCD_NAMESPACE"

log "applying ArgoCD Application $APP_NAME"
build_application_manifest | kubectl apply -f -

if [[ "$WAIT_ROLLOUT" == "true" ]]; then
  failure_message=""
  managed_deployments="$(resolve_argocd_managed_deployments || true)"
  if [[ -n "$managed_deployments" ]] && ! echo "$managed_deployments" | grep -Fxq "$DEPLOYMENT_NAME"; then
    if echo "$managed_deployments" | grep -Fxq "my-node-app"; then
      die "ArgoCD still manages deployment/my-node-app, but wait target is deployment/$DEPLOYMENT_NAME. Push updated manifests to repo and resync ArgoCD (or run with --deployment my-node-app / --no-wait)."
    fi
    die "ArgoCD resources do not include deployment/$DEPLOYMENT_NAME. Managed deployments: $(echo "$managed_deployments" | tr '\n' ' ' | sed 's/[[:space:]]*$//'). Use --deployment with a managed name or --no-wait."
  fi

  log "waiting for deployment to be created: deployment/$DEPLOYMENT_NAME (namespace=$DEST_NAMESPACE)"
  if ! wait_for_deployment_exists "$DEST_NAMESPACE" "$DEPLOYMENT_NAME" "$WAIT_TIMEOUT"; then
    failure_message="$(argocd_failure_message)"
    notify "failed" "${failure_message:-deployment was not created in time}"
    die "${failure_message:-deployment/$DEPLOYMENT_NAME not created in time}"
  fi
  log "waiting for rollout: deployment/$DEPLOYMENT_NAME (namespace=$DEST_NAMESPACE)"
  if ! kubectl -n "$DEST_NAMESPACE" rollout status "deployment/$DEPLOYMENT_NAME" --timeout="$WAIT_TIMEOUT"; then
    failure_message="$(argocd_failure_message)"
    rollback_deployment "$DEST_NAMESPACE" "$DEPLOYMENT_NAME"
    notify "failed" "${failure_message:-rollout failed}"
    die "${failure_message:-rollout failed for deployment/$DEPLOYMENT_NAME}"
  fi

  if [[ "$SMOKE_TEST_ENABLED" == "true" ]]; then
    log "running smoke test: http://${DEPLOYMENT_NAME}:3001${SMOKE_PATH}"
    if ! run_smoke_test "$DEST_NAMESPACE" "$DEPLOYMENT_NAME" "$SMOKE_PATH" "$SMOKE_TIMEOUT"; then
      rollback_deployment "$DEST_NAMESPACE" "$DEPLOYMENT_NAME"
      notify "failed" "smoke test failed for deployment/$DEPLOYMENT_NAME"
      die "smoke test failed for deployment/$DEPLOYMENT_NAME (path=$SMOKE_PATH)"
    fi
  fi
fi

log "deployment flow completed"
notify "succeeded" "deployment flow completed for $APP_NAME"
log "help: ./scripts/k8s/start-argo.sh --help"
