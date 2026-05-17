#!/usr/bin/env bash
# ============================================================
# deploy-vault.sh
#
# Installs HashiCorp Vault on GKE using Helm.
# Handles initialization and unsealing for first-time setup.
#
# Usage:
#   bash scripts/deploy-vault.sh
#
# Prerequisites:
#   - helm, kubectl installed
#   - kubectl connected to target GKE cluster
#   - (Optional) vault CLI installed locally for auto-init
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ── Configuration ─────────────────────────────────────────────────────────────
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
APP_NAMESPACE="${APP_NAMESPACE:-production}"
VAULT_RELEASE="${VAULT_RELEASE:-vault}"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.30.0}"

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }
title() { echo -e "\n${CYAN}━━━━ $* ━━━━${NC}"; }

trap 'echo -e "\n${RED}Vault deployment failed. Check output above.${NC}"' ERR

# ── Validate prerequisites ────────────────────────────────────────────────────
title "Validating prerequisites"

command -v helm    >/dev/null 2>&1 || fail "helm not found. Install from https://helm.sh"
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found."

kubectl cluster-info >/dev/null 2>&1 || \
  fail "kubectl is not connected to a cluster. Run: gcloud container clusters get-credentials <CLUSTER> --zone <ZONE>"

if command -v vault >/dev/null 2>&1; then
  log "vault CLI detected"
else
  warn "vault CLI not found locally — unseal step will be manual"
fi

# ── Add HashiCorp Helm repo ───────────────────────────────────────────────────
title "Configuring Helm repositories"

log "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update >/dev/null
log "Helm repositories updated"

# ── Create namespaces ─────────────────────────────────────────────────────────
title "Creating namespaces"

# FIX: Use --dry-run=client | kubectl apply -f - pattern to be idempotent
kubectl create namespace "$VAULT_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "Namespace '$VAULT_NAMESPACE' ready"

kubectl create namespace "$APP_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "Namespace '$APP_NAMESPACE' ready"

# ── Label production namespace for Vault injection ────────────────────────────
title "Configuring Vault Agent Injector"

kubectl label namespace "$APP_NAMESPACE" \
  vault-injection=enabled \
  --overwrite >/dev/null
log "Vault injection enabled for namespace '$APP_NAMESPACE'"

# ── Patch MutatingWebhookConfiguration to clear conflicting field managers ────
# The vault-k8s controller owns caBundle at runtime; strip managed fields before
# upgrade so Helm's server-side apply does not conflict with it.
if kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg &>/dev/null; then
  log "Patching vault-agent-injector-cfg to clear field ownership conflicts..."
  kubectl patch mutatingwebhookconfiguration vault-agent-injector-cfg \
    --type=json \
    -p='[{"op":"remove","path":"/metadata/managedFields"}]' 2>/dev/null || true
fi

# ── Install / Upgrade Vault via Helm ─────────────────────────────────────────
title "Deploying Vault via Helm"

# FIX: vault-install.yaml has gcpckms seal configured which causes
#      Vault to crash immediately unless GCP KMS is provisioned.
#      We generate a safe standalone values file here instead.
#      To use GCP KMS auto-unseal, see vault/vault-install.yaml (commented block).
mkdir -p helm

cat > helm/vault-values.yaml <<'EOF'
global:
  enabled: true
  tlsDisable: true     # Disable TLS for simplicity (enable in strict-prod)

injector:
  # Vault Agent Injector watches for vault.hashicorp.com/* annotations
  # on pods and injects an init container that fetches secrets from Vault.
  enabled: true
  replicas: 2          # HA injector
  logLevel: info

  resources:
    requests:
      memory: "64Mi"
      cpu: "50m"
    limits:
      memory: "128Mi"
      cpu: "250m"

  webhook:
    # Fail open so Vault downtime doesn't block all pod creation
    failurePolicy: Ignore

server:
  image:
    repository: "hashicorp/vault"
    tag: "1.19.0"

  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"
    limits:
      memory: "512Mi"
      cpu: "500m"

  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address     = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      # File storage (suitable for single-node; use GCS for HA production)
      storage "file" {
        path = "/vault/data"
      }

      # NOTE: gcpckms auto-unseal is defined in vault/vault-install.yaml.
      # To enable it, ensure your GCP KMS key ring and key exist first:
      #   gcloud kms keyrings create vault-keyring --location=asia-south1
      #   gcloud kms keys create vault-unseal-key \
      #     --keyring=vault-keyring --location=asia-south1 \
      #     --purpose=encryption
      # Then copy the seal block from vault/vault-install.yaml into this file.
      disable_mlock = true

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: standard-rwo   # GKE standard persistent disk (ReadWriteOnce)
    accessMode: ReadWriteOnce

  readinessProbe:
    enabled: true
    path: "/v1/sys/health?standbyok=true"

  livenessProbe:
    enabled: true
    path: "/v1/sys/health?standbyok=true"
    initialDelaySeconds: 60

ui:
  enabled: true
  serviceType: ClusterIP   # Access via port-forward (LoadBalancer = public exposure)

csi:
  enabled: false
EOF

log "Vault Helm values generated at helm/vault-values.yaml"

# FIX: Added --version flag for reproducible deploys.
# FIX: Removed --force-conflicts (not needed without gcpckms field conflicts).
# FIX: Using helm/vault-values.yaml instead of vault/vault-install.yaml.
HELM_FLAGS=(
  -f helm/vault-values.yaml
  --namespace "$VAULT_NAMESPACE"
  --version "$VAULT_CHART_VERSION"
  --wait
  --timeout=10m
)

if helm status "$VAULT_RELEASE" -n "$VAULT_NAMESPACE" &>/dev/null; then
  warn "Vault Helm release already exists — upgrading..."
  helm upgrade "$VAULT_RELEASE" hashicorp/vault "${HELM_FLAGS[@]}"
else
  helm install "$VAULT_RELEASE" hashicorp/vault "${HELM_FLAGS[@]}"
fi

log "Vault Helm chart deployed"

# ── Wait for Vault pod to be Running ─────────────────────────────────────────
# Sealed pods fail their readinessProbe (by design) so we wait on
# phase=Running, not on kubectl rollout status (which waits for Ready).
title "Waiting for Vault pod"

VAULT_POD=""
for i in $(seq 1 40); do
  VAULT_POD=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  PHASE=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")

  if [ "$PHASE" = "Running" ]; then
    log "Vault pod is Running: $VAULT_POD"
    break
  fi

  # Detect crash loops early so we don't spin for 200s uselessly
  REASON=$(kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
  if [[ "$REASON" == "CrashLoopBackOff" ]]; then
    kubectl logs -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault --tail=30 || true
    fail "Vault pod is in CrashLoopBackOff. Check logs above."
  fi

  warn "Attempt $i/40 — pod phase: $PHASE — waiting 5s..."
  sleep 5
  [ "$i" -eq 40 ] && fail "Vault pod did not reach Running phase in 200s"
done

# ── Vault Initialization (first time only) ────────────────────────────────────
title "Vault Initialization"

log "Checking Vault initialization status..."

INIT_STATUS=$(kubectl exec "$VAULT_POD" -n "$VAULT_NAMESPACE" -- \
  vault status -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d['initialized']).lower())" \
  2>/dev/null || echo "false")

if [ "$INIT_STATUS" = "false" ]; then
  log "Initializing Vault (first-time setup)..."
  warn "⚠️  SAVE THE FOLLOWING OUTPUT SECURELY — THESE KEYS CANNOT BE RECOVERED!"
  warn "    Store root token and unseal keys in a secure location."

  kubectl exec "$VAULT_POD" -n "$VAULT_NAMESPACE" -- \
    vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json | tee /tmp/vault-init-keys.json

  warn "Init keys saved temporarily to /tmp/vault-init-keys.json"
  warn "MOVE THIS FILE TO SECURE STORAGE NOW, then delete it:"
  warn "  gcloud secrets create vault-init-keys --data-file=/tmp/vault-init-keys.json"
  warn "  rm -f /tmp/vault-init-keys.json"
else
  log "Vault already initialized — skipping init"
fi

# ── Apply Vault Kubernetes auth manifests ─────────────────────────────────────
# FIX: vault-auth.yaml creates resources in the 'production' namespace.
#      Must pass -n production to ensure it lands in the correct namespace.
title "Applying Vault auth configuration"

kubectl apply -f vault/vault-auth.yaml -n "$APP_NAMESPACE"
log "Vault auth ServiceAccount and RBAC applied to namespace '$APP_NAMESPACE'"

# ── Display current pod/service status ───────────────────────────────────────
title "Vault Status"

kubectl get pods -n "$VAULT_NAMESPACE" -o wide
kubectl get svc -n "$VAULT_NAMESPACE"

# ── Done ──────────────────────────────────────────────────────────────────────
title "Deployment Summary"

echo "Vault Namespace      : $VAULT_NAMESPACE"
echo "Application Namespace: $APP_NAMESPACE"
echo "Helm Release         : $VAULT_RELEASE"
echo "Chart Version        : $VAULT_CHART_VERSION"
echo ""

log "✅ Vault deployment complete!"
echo ""
log "Next steps:"
log "  1. Port-forward Vault in a separate terminal:"
log "     kubectl port-forward svc/vault -n $VAULT_NAMESPACE 8200:8200"
log ""
log "  2. Unseal Vault (run 3 times with 3 different unseal keys from vault-init-keys.json):"
log "     kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- vault operator unseal <KEY>"
log ""
log "  3. Bootstrap all application secrets:"
log "     export VAULT_ADDR=http://127.0.0.1:8200"
log "     export VAULT_TOKEN=<root_token_from_vault-init-keys.json>"
log "     bash scripts/vault-secrets.sh"
