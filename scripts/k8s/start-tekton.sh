#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${TEKTON_NAMESPACE:-default}"
INSTALL_TEKTON="true"
APPLY_TRIGGERS="true"
INSTALL_DASHBOARD="true"
RUN_PIPELINE="${RUN_PIPELINE_ON_SETUP:-true}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/k8s/start-tekton.sh [options]

Automates Tekton setup for this repository:
- Optionally installs Tekton Pipelines + Triggers + Dashboard UI
- Applies RBAC, PVC, Tasks, Pipeline, and Triggers manifests
- Creates/updates required Kubernetes secrets from local/env values

Options:
  --skip-install         Skip installing Tekton Pipelines/Triggers/Dashboard
  --skip-dashboard       Install Pipelines/Triggers but skip Tekton Dashboard UI install
  --skip-triggers        Do not apply trigger manifests
  --skip-run             Do not create a PipelineRun after setup
  --namespace <name>     Kubernetes namespace to target (default: TEKTON_NAMESPACE or default)
  -h, --help             Show this help message

Environment:
  TEKTON_NAMESPACE       Namespace for all kubectl operations (default: default)
  RUN_PIPELINE_ON_SETUP  Set to false to skip creating a PipelineRun (default: true)
  TEKTON_REPO_URL        Git repo URL for pipeline param repo-url (default: git remote origin)
  TEKTON_IMAGE_REFERENCE Base image name for pipeline param image-reference (default: derived from node app deployment image)
  RUN_SONARQUBE          true/false to set pipeline param run-sonarqube (default: false)
  INTEGRATION_TESTS_STRICT true/false to fail when integration tests are missing (default: false)
  RUN_INTEGRATION_TESTS  true/false to run integration tests stage (default: false)
  ARGOCD_AUTO_DEPLOY     true/false to patch+sync ArgoCD app after build (default: true)
  ARGOCD_NAMESPACE       ArgoCD namespace for auto deploy (default: argocd)
  ARGOCD_APP_NAME        ArgoCD application name for auto deploy (default: tech-stack)
  COSIGN_SIGN_ENABLED    true/false to sign built image before ArgoCD sync (default: true)
  NOTIFICATION_WEBHOOK_URL Optional webhook URL passed to PipelineRun notifications
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

retry_cmd() {
  local attempts="$1"
  local sleep_seconds="$2"
  shift 2

  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      return 1
    fi
    n=$((n + 1))
    sleep "$sleep_seconds"
  done
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
    --skip-run)
      RUN_PIPELINE="false"
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
  retry_cmd 3 2 k apply -f "$file_path"
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

wait_for_tekton_deployments() {
  log "waiting for Tekton Pipelines deployments"
  kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller --timeout=300s
  kubectl -n tekton-pipelines rollout status deployment/tekton-events-controller --timeout=300s
  kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-webhook --timeout=300s

  log "waiting for Tekton Triggers deployments"
  kubectl -n tekton-pipelines rollout status deployment/tekton-triggers-controller --timeout=300s
  kubectl -n tekton-pipelines rollout status deployment/tekton-triggers-webhook --timeout=300s
  kubectl -n tekton-pipelines rollout status deployment/tekton-triggers-core-interceptors --timeout=300s

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    local dashboard_ns=""
    if kubectl -n tekton-dashboard get deployment tekton-dashboard >/dev/null 2>&1; then
      dashboard_ns="tekton-dashboard"
    elif kubectl -n tekton-pipelines get deployment tekton-dashboard >/dev/null 2>&1; then
      dashboard_ns="tekton-pipelines"
    else
      die "Tekton Dashboard deployment not found in tekton-dashboard or tekton-pipelines namespace"
    fi

    log "waiting for Tekton Dashboard deployment (namespace=$dashboard_ns)"
    kubectl -n "$dashboard_ns" rollout status deployment/tekton-dashboard --timeout=300s
  fi
}

configure_tekton_feature_flags() {
  log "configuring Tekton feature flags (coschedule=disabled)"
  kubectl -n tekton-pipelines patch configmap feature-flags \
    --type merge \
    -p '{"data":{"coschedule":"disabled"}}' >/dev/null
}

install_tekton_components() {
  log "installing Tekton Pipelines (latest)"
  retry_cmd 3 4 kubectl apply -f "https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml"

  log "installing Tekton Triggers (latest)"
  retry_cmd 3 4 kubectl apply -f "https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml"

  log "installing Tekton Triggers interceptors (latest)"
  retry_cmd 3 4 kubectl apply -f "https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml"

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    log "installing Tekton Dashboard UI (latest)"
    retry_cmd 3 4 kubectl apply -f "https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml"
  else
    log "skipping Tekton Dashboard UI install"
  fi

  wait_for_tekton_crds
  wait_for_tekton_deployments
  configure_tekton_feature_flags
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

infer_repo_url() {
  git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true
}

extract_node_image_reference_base() {
  local deployment_file image_no_digest image_ref
  deployment_file="$ROOT_DIR/manifests/apps/sample-node-app/deployment.yaml"
  if [[ ! -f "$deployment_file" ]]; then
    deployment_file="$ROOT_DIR/manifests/k8s/node-app/deployment.yaml"
  fi

  image_ref="$(awk '/image:/{print $2; exit}' "$deployment_file" 2>/dev/null || true)"
  [[ -n "$image_ref" ]] || return 0

  image_no_digest="${image_ref%@*}"
  if [[ "$image_no_digest" =~ .+:[^/]+$ ]]; then
    printf '%s\n' "${image_no_digest%:*}"
    return
  fi

  printf '%s\n' "$image_no_digest"
}

create_pipeline_run_for_node_app() {
  local repo_url image_reference run_sonarqube integration_tests_strict run_integration_tests argocd_auto_deploy argocd_namespace argocd_app_name cosign_sign_enabled notification_webhook_url created_run_name

  repo_url="${TEKTON_REPO_URL:-$(infer_repo_url)}"
  image_reference="${TEKTON_IMAGE_REFERENCE:-$(extract_node_image_reference_base)}"
  run_sonarqube="${RUN_SONARQUBE:-false}"
  integration_tests_strict="${INTEGRATION_TESTS_STRICT:-false}"
  run_integration_tests="${RUN_INTEGRATION_TESTS:-false}"
  argocd_auto_deploy="${ARGOCD_AUTO_DEPLOY:-true}"
  argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
  argocd_app_name="${ARGOCD_APP_NAME:-tech-stack}"
  cosign_sign_enabled="${COSIGN_SIGN_ENABLED:-true}"
  notification_webhook_url="${NOTIFICATION_WEBHOOK_URL:-}"

  [[ -n "$repo_url" ]] || die "Unable to resolve repo URL; set TEKTON_REPO_URL"
  [[ -n "$image_reference" ]] || die "Unable to resolve image reference base; set TEKTON_IMAGE_REFERENCE"
  [[ "$run_sonarqube" == "true" || "$run_sonarqube" == "false" ]] || die "RUN_SONARQUBE must be true or false"
  [[ "$integration_tests_strict" == "true" || "$integration_tests_strict" == "false" ]] || die "INTEGRATION_TESTS_STRICT must be true or false"
  [[ "$run_integration_tests" == "true" || "$run_integration_tests" == "false" ]] || die "RUN_INTEGRATION_TESTS must be true or false"
  [[ "$argocd_auto_deploy" == "true" || "$argocd_auto_deploy" == "false" ]] || die "ARGOCD_AUTO_DEPLOY must be true or false"
  [[ "$cosign_sign_enabled" == "true" || "$cosign_sign_enabled" == "false" ]] || die "COSIGN_SIGN_ENABLED must be true or false"

  if [[ "$image_reference" == host.docker.internal:5000/* ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsS "http://localhost:5000/v2/" >/dev/null 2>&1 || die "Local registry is not reachable at http://localhost:5000/v2/ (start it first, e.g. docker compose up -d local-registry)"
    else
      log "warning: curl not found; skipping local registry reachability check"
    fi
  fi

  if [[ "$cosign_sign_enabled" == "true" ]]; then
    if ! k get secret cosign-key >/dev/null 2>&1; then
      die "COSIGN_SIGN_ENABLED=true but secret/cosign-key is missing in namespace $NAMESPACE (run ./scripts/k8s/start-security.sh and wait for ExternalSecret sync, or set COSIGN_SIGN_ENABLED=false)"
    fi
  fi

  log "creating PipelineRun for Node.js app (repo-url=$repo_url, image-reference=$image_reference, run-sonarqube=$run_sonarqube, run-integration-tests=$run_integration_tests, integration-tests-strict=$integration_tests_strict, argocd-auto-deploy=$argocd_auto_deploy, argocd-app=$argocd_namespace/$argocd_app_name, cosign-sign-enabled=$cosign_sign_enabled)"
  cat <<EOF | k create -f -
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  generateName: nodejs-app-run-
  labels:
    app.kubernetes.io/name: sample-node-app
spec:
  serviceAccountName: tekton-triggers-sa
  timeouts:
    pipeline: 45m0s
    tasks: 40m0s
    finally: 5m0s
  pipelineRef:
    name: tekton-trigger-listeners
  podTemplate:
    securityContext:
      fsGroup: 65532
  workspaces:
    - name: shared-data
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
    - name: docker-credentials
      secret:
        secretName: docker-credentials
    - name: cache
      persistentVolumeClaim:
        claimName: tekton-cache-pvc
    - name: cosign-key
      secret:
        secretName: cosign-key
  params:
    - name: repo-url
      value: $repo_url
    - name: image-reference
      value: $image_reference
    - name: run-sonarqube
      value: "$run_sonarqube"
    - name: notification-webhook-url
      value: "$notification_webhook_url"
    - name: integration-tests-strict
      value: "$integration_tests_strict"
    - name: run-integration-tests
      value: "$run_integration_tests"
    - name: argocd-auto-deploy
      value: "$argocd_auto_deploy"
    - name: argocd-namespace
      value: "$argocd_namespace"
    - name: argocd-app-name
      value: "$argocd_app_name"
    - name: cosign-sign-enabled
      value: "$cosign_sign_enabled"
EOF

  created_run_name="$(k get pipelineruns --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | tail -n 1)"
  log "PipelineRun started: $created_run_name"
  log "follow logs: tkn -n $NAMESPACE pipelinerun logs -f $created_run_name"
}

log "starting setup (namespace=$NAMESPACE, install_tekton=$INSTALL_TEKTON, install_dashboard=$INSTALL_DASHBOARD, apply_triggers=$APPLY_TRIGGERS, run_pipeline=$RUN_PIPELINE)"

ensure_namespace

if [[ "$INSTALL_TEKTON" == "true" ]]; then
  install_tekton_components
else
  log "skipping Tekton component install"
  configure_tekton_feature_flags
fi

ensure_docker_secret
ensure_sonarqube_secret_if_configured
ensure_ssh_secret_if_configured

apply_manifest "$ROOT_DIR/manifests/tekton/rbac/rbac.yaml"
apply_manifest "$ROOT_DIR/manifests/tekton/pvc/cache-pvc.yaml"

log "applying Tekton tasks"
retry_cmd 3 2 k apply -f "$ROOT_DIR/manifests/tekton/tasks/"

apply_manifest "$ROOT_DIR/manifests/tekton/pipeline/pipeline.yaml"

if [[ "$APPLY_TRIGGERS" == "true" ]]; then
  log "applying Tekton triggers"
  retry_cmd 3 2 k apply -f "$ROOT_DIR/manifests/tekton/triggers/trigger-binding.yaml"
  retry_cmd 3 2 k apply -f "$ROOT_DIR/manifests/tekton/triggers/trigger-template.yaml"
  retry_cmd 3 2 k apply -f "$ROOT_DIR/manifests/tekton/triggers/event-listener.yaml"
else
  log "skipping trigger manifests"
fi

if [[ "$RUN_PIPELINE" == "true" ]]; then
  create_pipeline_run_for_node_app
else
  log "skipping PipelineRun creation"
fi

log "setup complete"
log "help: ./scripts/k8s/start-tekton.sh --help"
log "optional sanity checks:"
log "  kubectl -n $NAMESPACE get pipelines,tasks,pipelineruns,eventlisteners"
log "  kubectl -n $NAMESPACE get secret docker-credentials"
if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
  log "  kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097"
  log "  open http://localhost:9097"
fi
