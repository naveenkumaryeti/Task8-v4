#!/usr/bin/env bash
# ============================================================
# verify-deployment.sh
#
# Verifies the health of the full stack after deployment:
#   - Vault (namespace: vault)
#   - MySQL StatefulSet (namespace: production)
#   - Backend Deployment (namespace: production)
#   - Frontend Deployment (namespace: production)
#   - Ingress / External IP
#
# FIX: This file previously contained an incorrect draft of
#      deploy-vault.sh wrapped in markdown backticks. It has
#      been replaced with the correct verification logic.
#
# Usage:
#   bash scripts/verify-deployment.sh
# ============================================================

set -euo pipefail

NAMESPACE="${K8S_NAMESPACE:-production}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}━━━━ $* ━━━━${NC}"; }

# ── Vault ─────────────────────────────────────────────────────────────────────
title "Vault Health"

VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$VAULT_POD" ]; then
  warn "No Vault pod found in namespace '$VAULT_NAMESPACE'"
else
  VAULT_PHASE=$(kubectl get pod "$VAULT_POD" -n "$VAULT_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  log "Vault pod: $VAULT_POD  phase=$VAULT_PHASE"

  SEALED=$(kubectl exec "$VAULT_POD" -n "$VAULT_NAMESPACE" -- \
    vault status -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sealed'])" \
    2>/dev/null || echo "unknown")
  [ "$SEALED" = "False" ] && log "Vault is unsealed ✓" || warn "Vault sealed=$SEALED"
fi

kubectl get pods -n "$VAULT_NAMESPACE" -o wide

# ── Namespace ─────────────────────────────────────────────────────────────────
title "Production Namespace — All Pods"
kubectl get pods -n "$NAMESPACE" -o wide

# ── MySQL ─────────────────────────────────────────────────────────────────────
title "MySQL StatefulSet"
kubectl rollout status statefulset/mysql -n "$NAMESPACE" --timeout=60s || \
  warn "MySQL StatefulSet not fully ready"
kubectl get pvc -n "$NAMESPACE"

# ── Backend ───────────────────────────────────────────────────────────────────
title "Backend Deployment"
kubectl rollout status deployment/backend -n "$NAMESPACE" --timeout=60s || \
  warn "Backend deployment not fully ready"

BACKEND_READY=$(kubectl get deployment backend -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
log "Backend ready replicas: $BACKEND_READY"

# ── Frontend ──────────────────────────────────────────────────────────────────
title "Frontend Deployment"
kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=60s || \
  warn "Frontend deployment not fully ready"

FRONTEND_READY=$(kubectl get deployment frontend -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
log "Frontend ready replicas: $FRONTEND_READY"

# ── Services ──────────────────────────────────────────────────────────────────
title "Services"
kubectl get svc -n "$NAMESPACE"

# ── Ingress / External IP ─────────────────────────────────────────────────────
title "Ingress"
kubectl get ingress -n "$NAMESPACE" 2>/dev/null || warn "No ingress resources found"

EXTERNAL_IP=$(kubectl get ingress -n "$NAMESPACE" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [ -n "$EXTERNAL_IP" ]; then
  log "External IP: $EXTERNAL_IP"
  log "Testing frontend: http://$EXTERNAL_IP"
  curl -sf --max-time 10 "http://$EXTERNAL_IP" -o /dev/null && \
    log "Frontend responded with HTTP 200 ✓" || \
    warn "Frontend did not respond (Ingress may still be provisioning)"
else
  warn "No external IP yet — Ingress controller may still be provisioning"
fi

# ── HPA ───────────────────────────────────────────────────────────────────────
title "Horizontal Pod Autoscalers"
kubectl get hpa -n "$NAMESPACE" 2>/dev/null || warn "No HPA resources found"

# ── Summary ───────────────────────────────────────────────────────────────────
title "Summary"
log "Vault pod    : ${VAULT_POD:-not found}"
log "Backend pods : $BACKEND_READY ready"
log "Frontend pods: $FRONTEND_READY ready"
[ -n "$EXTERNAL_IP" ] && log "External IP  : $EXTERNAL_IP" || warn "External IP  : pending"
echo ""
log "✅ Verification complete!"
