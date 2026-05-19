#!/usr/bin/env bash
# ============================================================
# deploy-k8s.sh
#
# Deploys the frontend and backend application to Kubernetes.
# Optionally accepts an image version to deploy.
#
# Usage:
#   bash scripts/deploy-k8s.sh [VERSION]
#   bash scripts/deploy-k8s.sh 1.2.0
# ============================================================

set -euo pipefail

VERSION="${1:-${APP_VERSION:-1.0.0}}"
NAMESPACE="${K8S_NAMESPACE:-production}"
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
REGION="${GCP_REGION:-asia-south1}"
REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
err()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; }

# ── Rollout with diagnostics on failure ───────────────────────────────────────
rollout_or_debug() {
  local deployment="$1"
  local timeout="${2:-180s}"

  if ! kubectl rollout status deployment/"$deployment" -n "$NAMESPACE" --timeout="$timeout"; then
    err "Rollout timed out for deployment/$deployment — collecting diagnostics..."

    warn "── Pod status ──"
    kubectl get pods -n "$NAMESPACE" -l "app=$deployment" -o wide || true

    warn "── Deployment describe (last 30 lines) ──"
    kubectl describe deployment/"$deployment" -n "$NAMESPACE" | tail -30 || true

    warn "── Recent namespace events ──"
    kubectl get events -n "$NAMESPACE" \
      --sort-by='.lastTimestamp' \
      --field-selector "involvedObject.name=$deployment" 2>/dev/null | tail -20 || true

    warn "── Pod logs (current, last 50 lines) ──"
    kubectl logs -n "$NAMESPACE" \
      -l "app=$deployment" \
      --tail=50 2>/dev/null || true

    warn "── Pod logs (previous container, if crashed) ──"
    kubectl logs -n "$NAMESPACE" \
      -l "app=$deployment" \
      --tail=50 --previous 2>/dev/null || true

    err "Rolling back deployment/$deployment to previous version..."
    kubectl rollout undo deployment/"$deployment" -n "$NAMESPACE" || true

    return 1
  fi
}

log "Deploying version $VERSION to namespace: $NAMESPACE"

# ── Apply namespace first ─────────────────────────────────────────────────────
log "Applying namespace..."
kubectl apply -f k8s/namespace.yaml

# ── Apply ALL ConfigMaps before any deployments ───────────────────────────────
# nginx-config MUST exist before frontend-deployment.yaml is applied.
# If missing, kubelet cannot mount the volume and pods stay in ContainerCreating
# indefinitely with: MountVolume.SetUp failed — configmap "nginx-config" not found
log "Applying ConfigMaps..."
kubectl apply -f k8s/configmap.yaml       -n "$NAMESPACE"
kubectl apply -f k8s/nginx-configmap.yaml -n "$NAMESPACE"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
# Validate ConfigMaps and GAR images exist before triggering any rollout.
# Fails fast with a clear error instead of timing out after 3 minutes.
log "Running pre-flight checks..."

for cm in app-config nginx-config; do
  if ! kubectl get configmap "$cm" -n "$NAMESPACE" &>/dev/null; then
    err "Required ConfigMap '$cm' not found in namespace '$NAMESPACE'. Aborting."
    exit 1
  fi
done
log "ConfigMaps verified: app-config, nginx-config"

for svc in frontend backend; do
  image="${REGISTRY}/${svc}:${VERSION}"
  if ! gcloud artifacts docker images describe "$image" --quiet &>/dev/null; then
    err "Image $image not found or inaccessible in GAR. Aborting."
    err "Fix: rebuild and re-push with:"
    err "  docker build -t $image ./${svc} && docker push $image"
    exit 1
  fi
done
log "GAR images verified: frontend:${VERSION}, backend:${VERSION}"

# ── Apply all k8s manifests ───────────────────────────────────────────────────
log "Applying frontend resources..."
kubectl apply -f k8s/frontend-deployment.yaml -n "$NAMESPACE"
kubectl apply -f k8s/frontend-service.yaml    -n "$NAMESPACE"

log "Applying backend resources..."
kubectl apply -f k8s/backend-deployment.yaml  -n "$NAMESPACE"
kubectl apply -f k8s/backend-service.yaml     -n "$NAMESPACE"

log "Applying Ingress..."
kubectl apply -f k8s/ingress.yaml -n "$NAMESPACE"

log "Applying HPA and PodDisruptionBudgets..."
kubectl apply -f k8s/hpa.yaml -n "$NAMESPACE"

# ── Patch image versions once, after all manifests are applied ────────────────
# Done ONCE here to avoid triggering two separate rollouts.
log "Patching image versions to $VERSION..."

kubectl set image deployment/frontend \
  nginx="${REGISTRY}/frontend:${VERSION}" \
  -n "$NAMESPACE"

kubectl set image deployment/backend \
  backend="${REGISTRY}/backend:${VERSION}" \
  -n "$NAMESPACE"

# ── Wait for rollouts ─────────────────────────────────────────────────────────
log "Waiting for frontend rollout..."
rollout_or_debug frontend 180s

log "Waiting for backend rollout..."
rollout_or_debug backend 180s

# ── Summary ───────────────────────────────────────────────────────────────────
log "✅ Application deployed successfully!"
log "Version:   $VERSION"
log "Namespace: $NAMESPACE"
log "Registry:  $REGISTRY"
log "Next step: bash scripts/verify-deployment.sh"