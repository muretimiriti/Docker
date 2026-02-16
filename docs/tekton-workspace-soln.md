# Tekton Pipeline PVC Volume Mounting: Problem, Solution & Best Practices

## Table of Contents
1. [Overview](#overview)
2. [The Problem](#the-problem)
3. [Root Cause Analysis](#root-cause-analysis)
4. [The Solution](#the-solution)
5. [Current Pipeline Architecture](#current-pipeline-architecture)
6. [Deployment Scenarios](#deployment-scenarios)
7. [Cache Strategy & Performance Gains](#cache-strategy--performance-gains)
8. [Quick Reference Commands](#quick-reference-commands)

---

## Overview

This document explains the PVC (PersistentVolumeClaim) volume mounting issue encountered when running a Tekton CI/CD pipeline on Minikube, how it was resolved, and the architectural decisions made to ensure reliable, performant pipeline execution across different deployment environments.

---

## The Problem

### Error Encountered

```
[User error] more than one PersistentVolumeClaim is bound
reason: TaskRunValidationFailed
```

This error caused the pipeline to fail at the `restore-cache` task stage, preventing any subsequent tasks from running.

### What Was Happening

The original pipeline mounted the **cache PVC** (`tekton-cache-pvc`) directly in multiple tasks simultaneously:

```
ORIGINAL PIPELINE (broken):
─────────────────────────────────────────────────────────
fetch-source   → shared-data
npm-test       → shared-data + cache ❌ (mounted here)
sca-scan       → shared-data + cache ❌ (mounted here)
sonarqube-scan → shared-data + cache ❌ (mounted here)
build-push     → shared-data + docker-credentials
─────────────────────────────────────────────────────────
```

When multiple tasks tried to mount the same `ReadWriteOnce` (RWO) PVC simultaneously, Kubernetes rejected the requests because RWO PVCs can only be attached to **one node/pod at a time**.

---

## Root Cause Analysis

### 1. Tekton Affinity Assistant

Tekton's **Affinity Assistant** creates a helper pod for each PipelineRun to co-locate all PVCs on the same Kubernetes node. The rule is:

> Each workspace PVC must be managed by only ONE affinity-assistant at a time.

When the pipeline had multiple tasks mounting the same cache PVC, Tekton's affinity assistant detected the conflict and rejected the run.

### 2. ReadWriteOnce (RWO) Limitation

Minikube's default storage class (`standard`) only supports `ReadWriteOnce` access mode:

```
Minikube Storage Support:
├── ReadWriteOnce (RWO) ✅ Supported (default)
├── ReadWriteMany (RWX) ❌ NOT supported by default
└── ReadOnlyMany  (ROX) ❌ NOT supported by default

Rule: Each RWO PVC can only be mounted by ONE pod at a time.
```

### 3. Feature Flag Configuration

The Tekton `feature-flags` ConfigMap had `coschedule: workspaces` which enforced strict PVC co-scheduling, making the conflict worse.

### Why the PVC Appears "Bound" Immediately on Creation

When you create a PVC on Minikube, it shows `Bound` status immediately. This is **normal** — it simply means storage has been provisioned and is ready. It does NOT mean a pod is actively using it:

```
PVC Status Meanings:
──────────────────────────────────────────────────────
Pending  → Storage being provisioned
Bound    → Storage allocated and READY ✅ (not in use by a pod)
Released → PVC deleted but underlying PV still exists
Failed   → Provisioning failed ❌
```

---

## The Solution

### Fix 1: Disable Affinity Assistant & Coschedule

```bash
kubectl patch configmap feature-flags \
  -n tekton-pipelines \
  --type merge \
  -p '{
    "data": {
      "disable-affinity-assistant": "true",
      "coschedule": "disabled"
    }
  }'

# Restart controllers to apply
kubectl rollout restart deployment tekton-pipelines-controller -n tekton-pipelines
kubectl rollout restart deployment tekton-pipelines-webhook -n tekton-pipelines
```

### Fix 2: Sequential Cache Mounting Strategy

The core fix was restructuring the pipeline so the **cache PVC is only ever mounted by ONE task at a time**. We introduced two dedicated tasks:

- **`restore-cache`** — mounts the cache PVC first, copies files to `shared-data`, then releases the cache PVC
- **`save-cache`** — mounts the cache PVC last, after all other tasks are done, copies files back

All other tasks only use `shared-data` (a fresh PVC per run via `volumeClaimTemplate`).

### Fix 3: Workspace Architecture

```
WORKSPACE TYPE       PURPOSE                     LIFECYCLE
─────────────────────────────────────────────────────────────
shared-data          Source code, copied cache,   Fresh per run (volumeClaimTemplate)
docker-credentials   Docker auth                 Kubernetes Secret (no PVC)
cache                npm, trivy, sonar cache     Persistent across runs (PVC)
```

---

## Current Pipeline Architecture

### Pipeline Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    TEKTON PIPELINE FLOW                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Stage 1: fetch-source                                       │
│  Workspaces: [shared-data]                                   │
│  → Clones the git repository into shared-data                    │
│                         │                                    │
│                         ▼                                    │
│  Stage 2: restore-cache                                      │
│  Workspaces: [shared-data] + [cache] ← CACHE MOUNTED        │
│  → Copies node_modules, .npm, .trivy, .sonar                │
│    from cache PVC → shared-data                              │
│  → Cache PVC RELEASED after this task                        │
│                         │                                    │
│                         ▼                                    │
│  Stage 3: npm-test                                           │
│  Workspaces: [shared-data] only ✅                           │
│  → Uses node_modules from shared-data (restored from cache)  │
│  → Skips npm install if node_modules found                   │
│                         │                                    │
│                    ┌────┴────┐                               │
│                    ▼         ▼                               │
│  Stage 4a:         │  Stage 4b: sonarqube-scan (conditional) │
│  show-readme       │  Workspaces: [shared-data] only ✅      │
│  [shared-data] ✅  │  → Only runs if run-sonarqube=true      │
│                    └────┬────┘                               │
│                         │                                    │
│                         ▼                                    │
│  Stage 5: debug-workspace                                    │
│  Workspaces: [shared-data] only ✅                           │
│  → Lists workspace contents for debugging                    │
│                         │                                    │
│                         ▼                                    │
│  Stage 6: sca-scan (Trivy)                                   │
│  Workspaces: [shared-data] only ✅                           │
│  → Uses cached Trivy DB from shared-data                     │
│  → Scans for HIGH and CRITICAL vulnerabilities               │
│                         │                                    │
│                         ▼                                    │
│  Stage 7: save-cache                                         │
│  Workspaces: [shared-data] + [cache] ← CACHE MOUNTED        │
│  → Copies node_modules, .npm, .trivy, .sonar                │
│    from shared-data → cache PVC                              │
│  → Cache PVC RELEASED after this task                        │
│                         │                                    │
│                         ▼                                    │
│  Stage 8: build-push (Kaniko)                                │
│  Workspaces: [shared-data] + [docker-credentials]            │
│  → Builds Docker image                                       │
│  → Pushes to registry                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Rule: Cache PVC Mounting Pattern

```
CORRECT - Cache mounted sequentially, never simultaneously:

Task:          fetch  restore  npm  show  debug  sca  sonar  save  build
               ─────  ───────  ───  ────  ─────  ───  ─────  ────  ─────
shared-data:     ✅      ✅     ✅   ✅     ✅    ✅    ✅     ✅    ✅
cache PVC:               ✅                                    ✅
                         ↑                                     ↑
                    MOUNTED                              MOUNTED
                    (then released)                      (then released)

Cache PVC is NEVER mounted by two tasks at the same time ✅
```

### TriggerTemplate Workspace Configuration

```yaml
workspaces:
  # Fresh PVC per run - prevents conflicts between concurrent runs
  - name: shared-data
    volumeClaimTemplate:
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 2Gi        # Larger to accommodate copied cache files

  # Secret - no PVC needed for credentials
  - name: docker-credentials
    secret:
      secretName: docker-credentials

  # Persistent cache PVC - shared across all pipeline runs
  - name: cache
    persistentVolumeClaim:
      claimName: tekton-cache-pvc
```

---

## Deployment Scenarios

### Scenario 1: Minikube (Local Development) — Current Setup ✅

**Use Case:** Local development, learning, testing pipelines before production deployment.

**Storage:** Default `standard` StorageClass (RWO only)

**Configuration:**
```yaml
# Cache PVC
accessModes:
  - ReadWriteOnce    # Only option on Minikube
storageClassName: standard
```

**Requirements:**
```bash
# Feature flags MUST be set
disable-affinity-assistant: "true"
coschedule: "disabled"

# Pipeline tasks MUST mount cache sequentially
# NEVER mount cache in parallel tasks
```

**Limitations:**
- No ReadWriteMany support
- Single node cluster
- Limited resources (CPU/Memory)
- Cache PVC can only be used by one pod at a time

**Best For:**
- Learning Tekton pipelines
- Testing pipeline logic
- Development environment CI/CD
- Small projects

---

### Scenario 2: Single-Node Server / VPS ✅

**Use Case:** Small team, single server deployment (e.g., DigitalOcean Droplet, AWS EC2, bare metal).

**Storage:** Local path provisioner or `hostPath.`

**Configuration:**
```yaml
# Cache PVC - same as Minikube
accessModes:
  - ReadWriteOnce
storageClassName: local-path    # or hostpath

# Feature flags
disable-affinity-assistant: "true"
coschedule: "disabled"
```

**Additional Setup:**
```bash
# Install local-path provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

# Set as default
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

**Best For:**
- Small team projects
- Budget-conscious deployments
- Projects with sequential (not parallel) pipelines

---

### Scenario 3: Multi-Node Kubernetes Cluster (Production) ✅

**Use Case:** Production deployment on AWS EKS, GKE, AKS, or self-managed cluster.

**Storage:** Network-attached storage supporting ReadWriteMany

**Configuration:**
```yaml
# Shared Cache PVC - ReadWriteMany for parallel runs
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-cache-pvc
spec:
  accessModes:
    - ReadWriteMany       # Multiple pods can mount simultaneously
  storageClassName: efs   # AWS EFS, GCP Filestore, Azure Files, NFS
  resources:
    requests:
      storage: 50Gi
```

**Cloud Storage Options:**
```
AWS EKS:
  └── Amazon EFS (ReadWriteMany) ✅
  └── Amazon EBS (ReadWriteOnce only) ⚠️

Google GKE:
  └── GCP Filestore (ReadWriteMany) ✅
  └── GCP PD (ReadWriteOnce only) ⚠️

Azure AKS:
  └── Azure Files (ReadWriteMany) ✅
  └── Azure Disk (ReadWriteOnce only) ⚠️

Self-Managed:
  └── NFS Server (ReadWriteMany) ✅
  └── Rook-Ceph (ReadWriteMany) ✅
  └── Longhorn (ReadWriteMany) ✅
```

**With ReadWriteMany, tasks can mount cache simultaneously:**
```yaml
# Feature flags - can keep affinity assistant ON
disable-affinity-assistant: "false"   # Optional with RWX
coschedule: "workspaces"             # Default setting OK

# ALL tasks can safely mount cache with RWX ✅
npm-test:
  workspaces:
    - name: cache
      workspace: cache    # ✅ Safe with ReadWriteMany

sca-scan:
  workspaces:
    - name: cache
      workspace: cache    # ✅ Safe with ReadWriteMany
```

**Best For:**
- Production CI/CD
- Large teams with parallel pipeline runs
- High-frequency deployments
- Enterprise environments

---

### Scenario 4: CI/CD as a Service (GitHub Actions, GitLab CI) ⚡

**Use Case:** Managed CI/CD platforms where Tekton is not used, but the same caching principles apply.

**GitHub Actions equivalent:**
```yaml
# GitHub Actions cache equivalent
- uses: actions/cache@v3
  with:
    path: |
      node_modules
      ~/.npm
      ~/.trivy
    key: ${{ runner.os }}-cache-${{ hashFiles('**/package-lock.json') }}

# This is equivalent to our restore-cache → save-cache pattern
```

**Best For:**
- Open source projects
- Teams already using GitHub/GitLab
- When Kubernetes is not available

---

## Cache Strategy & Performance Gains

### What Gets Cached

```
CACHE CONTENTS (stored in tekton-cache-pvc):
─────────────────────────────────────────────
/cache/
├── node_modules/    → npm dependencies (can be 100MB-1GB)
├── .npm/            → npm download cache
├── .trivy/          → Trivy vulnerability database (~200MB)
│   └── db/          → CVE database (avoids re-download)
└── .sonar/          → SonarQube analysis cache
```

### Performance Comparison

```
PIPELINE DURATION COMPARISON:
──────────────────────────────────────────────────────────────
Task                Run 1 (Cold)      Run 2+ (Warm Cache)
──────────────────────────────────────────────────────────────
restore-cache       2s (miss)         5s (copy from cache)
npm install         3-5 mins ❌       ~5s (skip, use cache) ✅
npm test            1 min             1 min
trivy DB download   3-5 mins ❌       ~0s (skip, use cache) ✅
trivy scan          1 min             1 min
sonar setup         2-3 mins ❌       ~0s (skip, use cache) ✅
sonar scan          2 mins            2 mins
save-cache          2s                5s
build & push        3-5 mins          3-5 mins
──────────────────────────────────────────────────────────────
TOTAL               ~16-21 mins       ~7-10 mins
IMPROVEMENT         baseline          ~3x faster ✅
```

### Cache Lifecycle

```
Run 1 (Cold):
  restore-cache → MISS → no files copied
  [tasks run, generating artifacts]
  save-cache    → SAVE → node_modules, .trivy, .sonar saved to cache PVC

Run 2+ (Warm):
  restore-cache → HIT  → files copied from cache to shared-data
  npm-test      → SKIP npm install (node_modules exists)
  sca-scan      → SKIP DB download (.trivy exists)
  save-cache    → UPDATE → refresh cache with any new files
```

---

## Quick Reference Commands

### Check Pipeline Status

```bash
# List all pipeline runs
tkn pipelinerun list

# Watch latest pipeline run logs
tkn pipelinerun logs --last -f

# Describe latest pipeline run
tkn pipelinerun describe --last
```

### Check PVC Status

```bash
# List all PVCs
kubectl get pvc

# Check cache PVC details
kubectl describe pvc tekton-cache-pvc

# Check what's in the cache PVC
kubectl run cache-inspect --rm -it \
  --image=alpine \
  --overrides='{
    "spec": {
      "volumes": [{"name":"cache","persistentVolumeClaim":{"claimName":"tekton-cache-pvc"}}],
      "containers": [{
        "name":"inspect",
        "image":"alpine",
        "command":["sh","-c","ls -la /cache && du -sh /cache/*"],
        "volumeMounts":[{"name":"cache","mountPath":"/cache"}]
      }]
    }
  }'
```

### Manage Pipeline Runs

```bash
# Delete all old pipeline runs (cleanup)
kubectl delete pipelinerun --all

# Delete all old task runs
kubectl delete taskrun --all

# Delete and recreate cache PVC (reset cache)
kubectl delete pvc tekton-cache-pvc
kubectl apply -f manifests/tekton/pvc/cache-pvc.yaml
```

### Check Feature Flags

```bash
# View current feature flags
kubectl get configmap feature-flags -n tekton-pipelines \
  -o jsonpath='{.data}' | python3 -m json.tool

# Verify affinity assistant is disabled
kubectl get configmap feature-flags -n tekton-pipelines \
  -o jsonpath='{.data.disable-affinity-assistant}'
# Expected: true

# Verify coschedule is disabled
kubectl get configmap feature-flags -n tekton-pipelines \
  -o jsonpath='{.data.coschedule}'
# Expected: disabled
```

### Trigger Pipeline via Webhook

```bash
# Start port-forward
kubectl port-forward svc/el-event-listener 8090:8080 &

# Send test webhook
curl -X POST http://localhost:8090 \
  -H 'Content-Type: application/json' \
  -H 'X-GitHub-Event: push' \
  -d '{
    "ref": "refs/heads/main",
    "after": "abc123",
    "repository": {
      "name": "my-app",
      "clone_url": "https://github.com/youruser/my-app.git"
    }
  }'

# Watch pipeline
watch tkn pipelinerun list
```

---

## Summary

| Issue | Cause | Fix |
|-------|-------|-----|
| `more than one PVC is bound` | Multiple tasks mounting RWO cache PVC simultaneously | Sequential cache mounting via `restore-cache` and `save-cache` tasks |
| Affinity assistant conflicts | Tekton's affinity assistant detecting PVC conflicts | `disable-affinity-assistant: true` + `coschedule: disabled` |
| Cache PVC "Bound" on creation | Minikube dynamic provisioner binds PVCs immediately | Expected behaviour — "Bound" means ready, not in-use |
| Slow pipeline runs | Re-downloading dependencies every run | Cache node_modules, Trivy DB, Sonar cache between runs |

**The golden rule for RWO PVCs on Minikube/single-node clusters:**

> Mount the cache PVC in exactly ONE task at a time. Use dedicated `restore-cache` and `save-cache` tasks as the only entry and exit points for the cache PVC, and keep all other tasks using only `shared-data`.
