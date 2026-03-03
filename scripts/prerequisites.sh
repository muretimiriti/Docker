#!/bin/bash
set -euo pipefail

INSTALL_TEKTON_CRDS="true"
INSTALL_ARGOCD_CRDS="true"

TEKTON_PIPELINES_RELEASE_URL="${TEKTON_PIPELINES_RELEASE_URL:-https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml}"
TEKTON_TRIGGERS_RELEASE_URL="${TEKTON_TRIGGERS_RELEASE_URL:-https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/prerequisites.sh [options]

Installs prerequisite CRDs for Tekton and ArgoCD.
Only CRDs are applied; controller/webhook/dashboard deployments are not installed by this script.

Options:
  --skip-tekton       Do not install Tekton CRDs
  --skip-argocd       Do not install ArgoCD CRDs
  -h, --help          Show this help message

Environment overrides:
  TEKTON_PIPELINES_RELEASE_URL
  TEKTON_TRIGGERS_RELEASE_URL
  ARGOCD_INSTALL_URL
USAGE
}

log() {
  echo "[prerequisites] $*"
}

die() {
  echo "[prerequisites] $*" >&2
  exit 1
}

apply_crds_from_url() {
  local url="$1"
  local label="$2"

  log "applying CRDs from $label"
  # Extract only YAML docs with kind: CustomResourceDefinition from a multi-doc manifest.
  curl -fsSL "$url" \
    | awk '
      BEGIN { doc = ""; is_crd = 0 }
      /^---[[:space:]]*$/ {
        if (doc != "" && is_crd == 1) {
          printf "%s---\n", doc
        }
        doc = ""
        is_crd = 0
        next
      }
      {
        doc = doc $0 "\n"
        if ($0 ~ /^[[:space:]]*kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$/) {
          is_crd = 1
        }
      }
      END {
        if (doc != "" && is_crd == 1) {
          printf "%s", doc
        }
      }
    ' \
    | kubectl apply --server-side -f -
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

wait_for_argocd_crds() {
  log "waiting for ArgoCD CRDs"
  kubectl wait --for=condition=Established --timeout=240s crd/applications.argoproj.io
  kubectl wait --for=condition=Established --timeout=240s crd/appprojects.argoproj.io
  kubectl wait --for=condition=Established --timeout=240s crd/applicationsets.argoproj.io
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tekton)
      INSTALL_TEKTON_CRDS="false"
      shift
      ;;
    --skip-argocd)
      INSTALL_ARGOCD_CRDS="false"
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

if [[ "$INSTALL_TEKTON_CRDS" == "false" && "$INSTALL_ARGOCD_CRDS" == "false" ]]; then
  die "Nothing to do; both Tekton and ArgoCD were skipped"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  die "kubectl not found on PATH"
fi

if ! command -v curl >/dev/null 2>&1; then
  die "curl not found on PATH"
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  die "Cannot reach Kubernetes cluster; ensure your context is configured"
fi

log "starting (tekton_crds=$INSTALL_TEKTON_CRDS, argocd_crds=$INSTALL_ARGOCD_CRDS)"

if [[ "$INSTALL_TEKTON_CRDS" == "true" ]]; then
  apply_crds_from_url "$TEKTON_PIPELINES_RELEASE_URL" "Tekton Pipelines release"
  apply_crds_from_url "$TEKTON_TRIGGERS_RELEASE_URL" "Tekton Triggers release"
  wait_for_tekton_crds
else
  log "skipping Tekton CRDs"
fi

if [[ "$INSTALL_ARGOCD_CRDS" == "true" ]]; then
  apply_crds_from_url "$ARGOCD_INSTALL_URL" "ArgoCD install manifest"
  wait_for_argocd_crds
else
  log "skipping ArgoCD CRDs"
fi

log "prerequisite CRD setup complete"
