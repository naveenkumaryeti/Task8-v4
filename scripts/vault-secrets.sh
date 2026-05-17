#!/usr/bin/env bash
# ============================================================
# vault-secrets.sh
#
# Creates and manages all application secrets in HashiCorp Vault.
# Run ONCE during initial setup. Vault persists secrets.
#
# Secrets managed:
#   secret/mysql         → MySQL credentials
#   secret/app           → JWT, session, API key secrets
#   secret/ci            → CI/CD credentials (not app-facing)
#
# Usage:
#   VAULT_ADDR=http://vault:8200 VAULT_TOKEN=<root_token> bash scripts/vault-secrets.sh
#
# For secret rotation, run again — Vault KV v2 keeps version history.
# ============================================================

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"    # Set from environment — NEVER hardcode
APP_NAMESPACE="${APP_NAMESPACE:-production}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
fail() { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────
[ -z "$VAULT_TOKEN" ] && fail "VAULT_TOKEN environment variable is required"
command -v vault >/dev/null 2>&1 || fail "vault CLI not found"

export VAULT_ADDR VAULT_TOKEN

# ── Verify Vault connectivity ──────────────────────────────────────────────────
log "Connecting to Vault at $VAULT_ADDR"
vault status | grep -E "Sealed|Version" || fail "Cannot connect to Vault"

# ── Enable KV v2 secrets engine ───────────────────────────────────────────────
log "Enabling KV v2 secrets engine at 'secret/'"
vault secrets enable -path=secret kv-v2 2>/dev/null || \
  warn "KV v2 already enabled at 'secret/' — continuing"

# ── Generate secure random values ─────────────────────────────────────────────
# Using openssl for cryptographically secure random strings
# NEVER use weak passwords in production
generate_password() {
  openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

generate_key() {
  openssl rand -hex 64
}

log "Generating secure random credentials..."

# ── MySQL Secrets ─────────────────────────────────────────────────────────────
log "Writing MySQL credentials to secret/mysql..."
MYSQL_ROOT_PASSWORD=$(generate_password)
MYSQL_APP_PASSWORD=$(generate_password)

vault kv put secret/mysql \
  root_password="$MYSQL_ROOT_PASSWORD" \
  app_password="$MYSQL_APP_PASSWORD" \
  app_user="appuser" \
  host="mysql-service" \
  port="3306" \
  database="appdb"

log "MySQL secrets written (root + app user)"
# Immediately unset from shell — don't leave in environment
unset MYSQL_ROOT_PASSWORD MYSQL_APP_PASSWORD

# ── Application Secrets ───────────────────────────────────────────────────────
log "Writing application secrets to secret/app..."
JWT_SECRET=$(generate_key)
SESSION_SECRET=$(generate_key)
API_KEY=$(generate_password)

vault kv put secret/app \
  jwt_secret="$JWT_SECRET" \
  session_secret="$SESSION_SECRET" \
  api_key="$API_KEY"

unset JWT_SECRET SESSION_SECRET API_KEY

# ── Configure Kubernetes Auth Method ─────────────────────────────────────────
log "Configuring Vault Kubernetes authentication..."

vault auth enable kubernetes 2>/dev/null || \
  warn "Kubernetes auth already enabled"

KUBE_HOST=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[].cluster.server}')

KUBE_CA_CERT=$(kubectl config view --raw --minify \
  --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 --decode)

TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth-sa -n "$APP_NAMESPACE")

vault write auth/kubernetes/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA_CERT"

# ── Vault Policies ────────────────────────────────────────────────────────────
log "Writing Vault policies..."
vault policy write app-backend-policy vault/vault-policy.hcl

# MySQL-specific policy (read-only access to mysql secrets)
vault policy write mysql-policy - <<'EOF'
path "secret/data/mysql" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF

# ── Kubernetes Auth Roles ──────────────────────────────────────────────────────
log "Creating Vault Kubernetes auth roles..."

# Backend pods role
vault write auth/kubernetes/role/app-role \
  bound_service_account_names="vault-auth-sa" \
  bound_service_account_namespaces="production" \
  policies="app-backend-policy" \
  ttl="1h" \
  max_ttl="24h"

# MySQL pod role
vault write auth/kubernetes/role/mysql-role \
  bound_service_account_names="vault-auth-sa" \
  bound_service_account_namespaces="production" \
  policies="mysql-policy" \
  ttl="1h"

log "✅ Vault secrets and policies configured!"
log ""
log "Secret paths:"
log "  secret/mysql  → MySQL root + app credentials"
log "  secret/app    → JWT secret, session secret, API key"
log ""
log "Vault auth roles:"
log "  app-role   → backend pods (reads secret/app + secret/mysql)"
log "  mysql-role → mysql pod (reads secret/mysql only)"
