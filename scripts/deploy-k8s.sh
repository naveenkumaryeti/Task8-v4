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
  PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project-id}"
  REGION="${GCP_REGION:-asia-south1}"
  REPO_NAME="${GAR_REPO_NAME:-prod-repo}"
  REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
  log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
  warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

  log "Deploying version $VERSION to namespace: $NAMESPACE"

  # ── Apply core resources ──────────────────────────────────────────────────────
  log "Applying namespace..."
  kubectl apply -f k8s/namespace.yaml

  log "Applying ConfigMaps..."
  kubectl apply -f k8s/configmap.yaml -n "$NAMESPACE"

  # ── Update image versions in manifests dynamically ───────────────────────────
  # This avoids committing environment-specific image tags to git.
  # The manifests have placeholder image names; we patch them here.
  log "Patching image versions to $VERSION..."

  # Frontend image update
  kubectl set image deployment/frontend \
    nginx="${REGISTRY}/frontend:${VERSION}" \
    -n "$NAMESPACE" 2>/dev/null || true   # OK if deployment doesn't exist yet

  # Backend image update
  kubectl set image deployment/backend \
    backend="${REGISTRY}/backend:${VERSION}" \
    -n "$NAMESPACE" 2>/dev/null || true

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

  # ── Set correct image in deployments ──────────────────────────────────────────
  # kustomize or envsubst is preferred over sed for production
  # Using kubectl set image as the portable alternative
  kubectl set image deployment/frontend \
    nginx="${REGISTRY}/frontend:${VERSION}" \
    -n "$NAMESPACE"

  kubectl set image deployment/backend \
    backend="${REGISTRY}/backend:${VERSION}" \
    -n "$NAMESPACE"

  # ── Wait for rollout ──────────────────────────────────────────────────────────
  log "Waiting for frontend rollout..."
  kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=180s

  log "Waiting for backend rollout..."
  kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=180s

  log "✅ Application deployed successfully!"
  log "Version: $VERSION"
  log "Next step: bash scripts/verify-deployment.sh"
