#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${ARGOCD_APP_NAME:-tech-stack}"
PROJECT_NAME="${ARGOCD_PROJECT:-default}"
DEST_NAMESPACE="${ARGOCD_DEST_NAMESPACE:-default}"
TARGET_REVISION="${ARGOCD_TARGET_REVISION:-HEAD}"
APP_PATH="${ARGOCD_APP_PATH:-manifests/k8s}"
TEKTON_NAMESPACE="${TEKTON_NAMESPACE:-default}"
DEPLOYMENT_NAME="${ARGOCD_DEPLOYMENT_NAME:-sample-node-app}"
IMAGE_REFERENCE="${IMAGE_REFERENCE:-}"
INSTALL_ARGOCD="false"
WAIT_ROLLOUT="true"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"
GITOPS_SYNC="true"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/start-argo.sh [options]

Creates/updates an ArgoCD Application for this repo, selects an image, and deploys to the cluster.

Image selection priority:
1) --image <ref>
2) IMAGE_REFERENCE env
3) latest successful Tekton PipelineRun param: image-reference
4) image currently in manifests/k8s/node-app/deployment.yaml

Options:
  --image <ref>             Full image reference (example: ghcr.io/org/app:sha123)
  --repo-url <url>          Git repository URL for ArgoCD source (default: git remote origin)
  --revision <rev>          Git revision/branch/tag to deploy (default: HEAD)
  --path <path>             Repo path for manifests (default: manifests/k8s)
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
  -h, --help                Show this help

Environment:
  IMAGE_REFERENCE           Same as --image
  ARGOCD_*                  Defaults for key options (see script variables)
  TEKTON_NAMESPACE          Default namespace for Tekton PipelineRun discovery
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
      die "deployment/$deployment_name not found in namespace $namespace within $timeout"
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
}

resolve_argocd_managed_deployments() {
  kubectl -n "$ARGOCD_NAMESPACE" get application "$APP_NAME" \
    -o jsonpath='{range .status.resources[*]}{.kind}{"\t"}{.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' '$1 == "Deployment" {print $2}'
}

extract_manifest_image() {
  local image_line
  image_line="$(awk '/image:/{print $2; exit}' "$ROOT_DIR/manifests/k8s/node-app/deployment.yaml" 2>/dev/null || true)"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

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

ensure_local_image_in_kind_nodes "$RESOLVED_IMAGE"

ensure_namespace "$DEST_NAMESPACE"
install_argocd_if_requested
ensure_argocd_crd
ensure_namespace "$ARGOCD_NAMESPACE"

log "applying ArgoCD Application $APP_NAME"
build_application_manifest | kubectl apply -f -

if [[ "$WAIT_ROLLOUT" == "true" ]]; then
  managed_deployments="$(resolve_argocd_managed_deployments || true)"
  if [[ -n "$managed_deployments" ]] && ! echo "$managed_deployments" | grep -Fxq "$DEPLOYMENT_NAME"; then
    if echo "$managed_deployments" | grep -Fxq "my-node-app"; then
      die "ArgoCD still manages deployment/my-node-app, but wait target is deployment/$DEPLOYMENT_NAME. Push updated manifests to repo and resync ArgoCD (or run with --deployment my-node-app / --no-wait)."
    fi
    die "ArgoCD resources do not include deployment/$DEPLOYMENT_NAME. Managed deployments: $(echo "$managed_deployments" | tr '\n' ' ' | sed 's/[[:space:]]*$//'). Use --deployment with a managed name or --no-wait."
  fi

  log "waiting for deployment to be created: deployment/$DEPLOYMENT_NAME (namespace=$DEST_NAMESPACE)"
  wait_for_deployment_exists "$DEST_NAMESPACE" "$DEPLOYMENT_NAME" "$WAIT_TIMEOUT"
  log "waiting for rollout: deployment/$DEPLOYMENT_NAME (namespace=$DEST_NAMESPACE)"
  kubectl -n "$DEST_NAMESPACE" rollout status "deployment/$DEPLOYMENT_NAME" --timeout="$WAIT_TIMEOUT"
fi

log "deployment flow completed"
log "help: ./scripts/k8s/start-argo.sh --help"
