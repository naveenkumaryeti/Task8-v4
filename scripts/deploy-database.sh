#!/usr/bin/env bash
# ============================================================
# deploy-database.sh
#
# Deploys MySQL to Kubernetes.
# Order matters: PVC → ConfigMap → StatefulSet → Service
#
# Usage:
#   bash scripts/deploy-database.sh
# ============================================================

set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-production}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }

log "Deploying MySQL to namespace: $NAMESPACE"

# ── Apply resources in dependency order ───────────────────────────────────────
log "Creating namespace (if not exists)..."
kubectl apply -f k8s/namespace.yaml

log "Applying MySQL ConfigMap..."
kubectl apply -f database/mysql-configmap.yaml -n "$NAMESPACE"

log "Applying MySQL PVC..."
kubectl apply -f database/mysql-pvc.yaml -n "$NAMESPACE"

log "Applying Vault auth ServiceAccount..."
kubectl apply -f vault/vault-auth.yaml -n "$NAMESPACE"

log "Applying MySQL StatefulSet..."
kubectl apply -f database/mysql-deployment.yaml -n "$NAMESPACE"

log "Applying MySQL Service..."
kubectl apply -f database/mysql-service.yaml -n "$NAMESPACE"

# ── Wait for MySQL to be ready ────────────────────────────────────────────────
log "Waiting for MySQL pod to be ready (this may take 60-90s)..."
kubectl rollout status statefulset/mysql -n "$NAMESPACE" --timeout=120s

# ── Verify ────────────────────────────────────────────────────────────────────
log "MySQL pod status:"
kubectl get pods -n "$NAMESPACE" -l app=mysql -o wide

log "MySQL PVC status:"
kubectl get pvc mysql-pvc -n "$NAMESPACE"

log "✅ MySQL deployed successfully!"
