#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${TEKTON_NAMESPACE:-default}"
INSTALL_TEKTON="true"
APPLY_TRIGGERS="true"
INSTALL_DASHBOARD="true"

usage() {
  cat <<'USAGE'
Usage: ./scripts/tekton.sh [options]

Automates Tekton setup for this repository:
- Optionally installs Tekton Pipelines + Triggers + Dashboard UI
- Applies RBAC, PVC, Tasks, Pipeline, and Triggers manifests
- Creates/updates required Kubernetes secrets from local/env values

Options:
  --skip-install         Skip installing Tekton Pipelines/Triggers/Dashboard
  --skip-dashboard       Install Pipelines/Triggers but skip Tekton Dashboard UI install
  --skip-triggers        Do not apply trigger manifests
  --namespace <name>     Kubernetes namespace to target (default: TEKTON_NAMESPACE or default)
  -h, --help             Show this help message

Environment:
  TEKTON_NAMESPACE       Namespace for all kubectl operations (default: default)
  DOCKER_CONFIG_JSON     Path to docker config.json (default: $DOCKER_CONFIG/config.json or $HOME/.docker/config.json)
  SONAR_HOST_URL         If set with SONAR_TOKEN, creates sonarqube-credentials secret
  SONAR_TOKEN            If set with SONAR_HOST_URL, creates sonarqube-credentials secret
  SSH_PRIVATE_KEY_PATH   Optional path to private key for ssh-key secret
  SSH_KNOWN_HOSTS_PATH   Optional path to known_hosts for ssh-key secret
USAGE
}

log() {
  echo "[tekton] $*"
}

die() {
  echo "[tekton] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-install)
      INSTALL_TEKTON="false"
      shift
      ;;
    --skip-dashboard)
      INSTALL_DASHBOARD="false"
      shift
      ;;
    --skip-triggers)
      APPLY_TRIGGERS="false"
      shift
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "Missing value for --namespace"
      NAMESPACE="$2"
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

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! kubectl version --client >/dev/null 2>&1; then
  die "kubectl is not usable; verify your installation"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

k() {
  kubectl -n "$NAMESPACE" "$@"
}

apply_manifest() {
  local file_path="$1"
  log "applying ${file_path#"$ROOT_DIR"/}"
  k apply -f "$file_path"
}

wait_for_tekton_crds() {
  log "waiting for Tekton CRDs"
  kubectl wait --for=condition=Established --timeout=240s crd/pipelines.tekton.dev
  kubectl wait --for=condition=Established --timeout=240s crd/tasks.tekton.dev
  kubectl wait --for=condition=Established --timeout=240s crd/pipelineruns.tekton.dev
  kubectl wait --for=condition=Established --timeout=240s crd/eventlisteners.triggers.tekton.dev
  kubectl wait --for=condition=Established --timeout=240s crd/triggers.triggers.tekton.dev
  kubectl wait --for=condition=Established --timeout=240s crd/triggertemplates.triggers.tekton.dev
}

install_tekton_components() {
  log "installing Tekton Pipelines (latest)"
  kubectl apply -f "https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml"

  log "installing Tekton Triggers (latest)"
  kubectl apply -f "https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml"

  log "installing Tekton Triggers interceptors (latest)"
  kubectl apply -f "https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml"

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    log "installing Tekton Dashboard UI (latest)"
    kubectl apply -f "https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml"
  else
    log "skipping Tekton Dashboard UI install"
  fi

  wait_for_tekton_crds
}

ensure_namespace() {
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "creating namespace $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
  fi
}

resolve_docker_config_path() {
  if [[ -n "${DOCKER_CONFIG_JSON:-}" ]]; then
    printf '%s\n' "$DOCKER_CONFIG_JSON"
    return
  fi

  if [[ -n "${DOCKER_CONFIG:-}" ]]; then
    printf '%s\n' "$DOCKER_CONFIG/config.json"
    return
  fi

  printf '%s\n' "$HOME/.docker/config.json"
}

ensure_docker_secret() {
  local docker_config
  docker_config="$(resolve_docker_config_path)"

  if [[ ! -f "$docker_config" ]]; then
    die "docker config.json not found at $docker_config (set DOCKER_CONFIG_JSON to override)"
  fi

  log "creating/updating secret docker-credentials from $docker_config"
  k create secret generic docker-credentials \
    --from-file=config.json="$docker_config" \
    --dry-run=client -o yaml | k apply -f -
}

ensure_sonarqube_secret_if_configured() {
  local host="${SONAR_HOST_URL:-}"
  local token="${SONAR_TOKEN:-}"

  if [[ -z "$host" && -z "$token" ]]; then
    log "skipping sonarqube-credentials (SONAR_HOST_URL/SONAR_TOKEN not provided)"
    return
  fi

  if [[ -z "$host" || -z "$token" ]]; then
    die "Both SONAR_HOST_URL and SONAR_TOKEN must be set to create sonarqube-credentials"
  fi

  log "creating/updating secret sonarqube-credentials"
  k create secret generic sonarqube-credentials \
    --from-literal=SONAR_HOST_URL="$host" \
    --from-literal=SONAR_TOKEN="$token" \
    --dry-run=client -o yaml | k apply -f -
}

ensure_ssh_secret_if_configured() {
  local private_key_path="${SSH_PRIVATE_KEY_PATH:-}"
  local known_hosts_path="${SSH_KNOWN_HOSTS_PATH:-}"

  if [[ -z "$private_key_path" && -z "$known_hosts_path" ]]; then
    log "skipping ssh-key secret (SSH_PRIVATE_KEY_PATH/SSH_KNOWN_HOSTS_PATH not provided)"
    return
  fi

  [[ -n "$private_key_path" ]] || die "SSH_PRIVATE_KEY_PATH is required when creating ssh-key secret"
  [[ -n "$known_hosts_path" ]] || die "SSH_KNOWN_HOSTS_PATH is required when creating ssh-key secret"
  [[ -f "$private_key_path" ]] || die "SSH private key file not found: $private_key_path"
  [[ -f "$known_hosts_path" ]] || die "known_hosts file not found: $known_hosts_path"

  log "creating/updating secret ssh-key"
  k create secret generic ssh-key \
    --type=kubernetes.io/ssh-auth \
    --from-file=ssh-privatekey="$private_key_path" \
    --from-file=known_hosts="$known_hosts_path" \
    --dry-run=client -o yaml | k apply -f -

  log "annotating ssh-key for github.com"
  k annotate secret ssh-key tekton.dev/git-0=github.com --overwrite
}

log "starting setup (namespace=$NAMESPACE, install_tekton=$INSTALL_TEKTON, install_dashboard=$INSTALL_DASHBOARD, apply_triggers=$APPLY_TRIGGERS)"

ensure_namespace

if [[ "$INSTALL_TEKTON" == "true" ]]; then
  install_tekton_components
else
  log "skipping Tekton component install"
fi

ensure_docker_secret
ensure_sonarqube_secret_if_configured
ensure_ssh_secret_if_configured

apply_manifest "$ROOT_DIR/manifests/tekton/rbac/rbac.yaml"
apply_manifest "$ROOT_DIR/manifests/tekton/pvc/cache-pvc.yaml"

log "applying Tekton tasks"
k apply -f "$ROOT_DIR/manifests/tekton/tasks/"

apply_manifest "$ROOT_DIR/manifests/tekton/pipeline/pipeline.yaml"

if [[ "$APPLY_TRIGGERS" == "true" ]]; then
  log "applying Tekton triggers"
  k apply -f "$ROOT_DIR/manifests/tekton/triggers/trigger-binding.yaml"
  k apply -f "$ROOT_DIR/manifests/tekton/triggers/trigger-template.yaml"
  k apply -f "$ROOT_DIR/manifests/tekton/triggers/event-listener.yaml"
else
  log "skipping trigger manifests"
fi

log "setup complete"
log "optional sanity checks:"
log "  kubectl -n $NAMESPACE get pipelines,tasks,pipelineruns,eventlisteners"
log "  kubectl -n $NAMESPACE get secret docker-credentials"
if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
  log "  kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097"
  log "  open http://localhost:9097"
fi
