#!/usr/bin/env bash
# ============================================================
# cluster-setup.sh
#
# Creates a production-grade GKE cluster with security features.
#
# Usage:
#   bash scripts/cluster-setup.sh
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - gcloud config set project <YOUR_PROJECT_ID>
#   - Billing enabled on the project
# ============================================================

set -euo pipefail   # Exit on error, undefined var, pipe failure
IFS=$'\n\t'

# ── Configuration ─────────────────────────────────────────────────────────────
PROJECT_ID="${GCP_PROJECT_ID:-naveen-devops-cicd}"
CLUSTER_NAME="${GKE_CLUSTER_NAME:-gke-microservices}"
REGION="${GCP_REGION:-asia-south1}"
ZONE="${GCP_ZONE:-asia-south1-a}"
NODE_COUNT="${GKE_NODE_COUNT:-3}"
MACHINE_TYPE="${GKE_MACHINE_TYPE:-e2-standard-2}"
DISK_SIZE="${GKE_DISK_SIZE:-50}"

# ── Colors for output ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }

# ── Validate prerequisites ────────────────────────────────────────────────────
log "Validating prerequisites..."
command -v gcloud >/dev/null 2>&1 || fail "gcloud CLI not found."
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found. Run: gcloud components install kubectl"

gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@" || \
  fail "Not authenticated. Run: gcloud auth login"

# ── Set active project ────────────────────────────────────────────────────────
log "Setting project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

log "Enabling required GCP APIs..."
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudkms.googleapis.com \
  secretmanager.googleapis.com \
  --quiet

# ── Auto-detect public IP ─────────────────────────────────────────────────────
# This IP is whitelisted so your machine can reach the private cluster API.
# Override at runtime:  MY_PUBLIC_IP=1.2.3.4 bash scripts/cluster-setup.sh
if [[ -z "${MY_PUBLIC_IP:-}" ]]; then
  log "Auto-detecting public IP for master authorized networks..."
  MY_PUBLIC_IP=$(
    curl -sf --max-time 5 https://checkip.amazonaws.com ||
    curl -sf --max-time 5 https://ifconfig.me ||
    curl -sf --max-time 5 https://api4.my-ip.io/ip ||
    echo ""
  )
  # Trim whitespace/newlines
  MY_PUBLIC_IP="${MY_PUBLIC_IP//[$'\t\r\n ']}"
fi

# Validate it looks like an IPv4 address
if [[ ! "$MY_PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  fail "Could not detect a valid public IP (got: '${MY_PUBLIC_IP:-empty}'). Set it manually: MY_PUBLIC_IP=1.2.3.4 bash $0"
fi

log "Public IP detected: $MY_PUBLIC_IP — will be whitelisted for cluster API access"

# ── Create GKE Cluster ────────────────────────────────────────────────────────
log "Creating GKE cluster: $CLUSTER_NAME in $ZONE"
log "Machine type: $MACHINE_TYPE | Nodes: $NODE_COUNT | Disk: ${DISK_SIZE}GB"

if gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" --quiet 2>/dev/null; then
  warn "Cluster '$CLUSTER_NAME' already exists — skipping creation"
else
  gcloud container clusters create "$CLUSTER_NAME" \
    --zone="$ZONE" \
    --num-nodes="$NODE_COUNT" \
    --machine-type="$MACHINE_TYPE" \
    --disk-size="${DISK_SIZE}GB" \
    --disk-type="pd-ssd" \
    --enable-shielded-nodes \
    --shielded-secure-boot \
    --shielded-integrity-monitoring \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-autorepair \
    --enable-autoupgrade \
    --enable-ip-alias \
    --enable-private-nodes \
    --master-ipv4-cidr="172.16.0.0/28" \
    --enable-master-authorized-networks \
    --master-authorized-networks="${MY_PUBLIC_IP}/32" \
    --enable-autoscaling \
    --min-nodes=2 \
    --max-nodes=6 \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM \
    --labels="environment=production,team=devops,managed-by=gcloud" \
    --quiet
  log "Cluster created successfully!"
fi

# ── Configure kubectl context ─────────────────────────────────────────────────
log "Configuring kubectl context..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE"

log "Verifying cluster connectivity..."
kubectl cluster-info
kubectl get nodes -o wide

log "Creating production namespace..."
kubectl apply -f k8s/namespace.yaml

log "✅ Cluster setup complete!"
log "Next step: bash scripts/artifact-registry-setup.sh"