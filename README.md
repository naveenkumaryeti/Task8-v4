# 🚀 Enterprise-Grade Kubernetes Deployment on GKE

> Production-grade microservices on Google Kubernetes Engine with GitHub Actions CI/CD,
> Google Artifact Registry, and HashiCorp Vault secret management.

---

## 📐 Architecture Overview

```
Internet
    │
    ▼
GCP Load Balancer
    │
    ▼
NGINX Ingress Controller  (TLS termination, rate limiting)
    │
    ▼
frontend-service (ClusterIP → Nginx pods × 2)
    │
    ├── Static assets served directly
    │
    └── /api/* → backend-service (ClusterIP → Node.js pods × 3)
                        │
                        └── mysql-service (ClusterIP → MySQL StatefulSet × 1)

HashiCorp Vault (separate namespace)
    └── Vault Agent Injector → injects secrets into backend + mysql pods
```

---

## 🗂️ Project Structure

```
project/
├── frontend/                   # Nginx static frontend
│   ├── Dockerfile              # Multi-stage: node builder → nginx:alpine
│   ├── nginx.conf              # Reverse proxy config
│   ├── package.json
│   └── src/index.html          # Frontend application
│
├── backend/                    # Node.js REST API
│   ├── Dockerfile              # Multi-stage: deps → production (non-root)
│   ├── package.json
│   ├── jest.config.js
│   ├── .eslintrc.json
│   └── src/
│       ├── server.js           # Express app with graceful shutdown
│       └── server.test.js      # Jest unit tests
│
├── database/                   # MySQL resources
│   ├── init.sql                # Schema + seed data
│   ├── mysql-configmap.yaml    # MySQL config + init script
│   ├── mysql-deployment.yaml   # StatefulSet with Vault injection
│   ├── mysql-service.yaml      # ClusterIP (internal only)
│   └── mysql-pvc.yaml          # 20Gi SSD PVC (standard-rwo)
│
├── vault/                      # HashiCorp Vault
│   ├── vault-install.yaml      # Helm values for Vault
│   ├── vault-auth.yaml         # Kubernetes auth + ServiceAccount
│   ├── vault-policy.hcl        # Least-privilege ACL policies
│   ├── vault-agent-injector.yaml
│   └── secrets-config.yaml     # Secret path documentation
│
├── k8s/                        # Application Kubernetes manifests
│   ├── namespace.yaml          # production namespace
│   ├── configmap.yaml          # Non-sensitive app config
│   ├── nginx-configmap.yaml    # Nginx config as ConfigMap
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml   # LoadBalancer (external)
│   ├── backend-deployment.yaml # 3 replicas, Vault-injected secrets
│   ├── backend-service.yaml    # ClusterIP (internal)
│   ├── ingress.yaml            # NGINX Ingress + TLS
│   └── hpa.yaml               # HPA + PodDisruptionBudgets
│
├── scripts/                    # Automation scripts
│   ├── cluster-setup.sh        # Create GKE cluster
│   ├── artifact-registry-setup.sh
│   ├── docker-auth.sh
│   ├── build-images.sh
│   ├── push-images.sh
│   ├── vault-secrets.sh        # Seed Vault secrets
│   ├── deploy-database.sh
│   ├── deploy-vault.sh
│   ├── deploy-k8s.sh
│   ├── rolling-update.sh       # Zero-downtime updates + auto-rollback
│   ├── scale-app.sh
│   ├── verify-deployment.sh    # Comprehensive health checks
│   └── cleanup.sh
│
├── .github/workflows/
│   ├── ci.yml                  # Build → Test → Scan → Push
│   └── cd.yml                  # Deploy to GKE → Verify
│
├── docker-compose.yml          # Local dev environment
├── .gitignore
└── README.md
```

---

## ⚡ Quick Start (Full Deployment)

### Prerequisites

```bash
# Install required tools
brew install google-cloud-sdk kubectl helm vault  # macOS
# or follow official docs for Linux

# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Step-by-Step Deployment

```bash
# 1. Create GKE cluster
bash scripts/cluster-setup.sh

# 2. Create Artifact Registry
bash scripts/artifact-registry-setup.sh

# 3. Authenticate Docker
bash scripts/docker-auth.sh

# 4. Build Docker images
bash scripts/build-images.sh 1.0.0

# 5. Push to Artifact Registry
bash scripts/push-images.sh 1.0.0

# 6. Deploy and configure Vault
bash scripts/deploy-vault.sh
# Then unseal manually (see Vault section below)

# 7. Seed secrets into Vault
VAULT_TOKEN=<root-token> bash scripts/vault-secrets.sh

# 8. Deploy MySQL
bash scripts/deploy-database.sh

# 9. Deploy application
bash scripts/deploy-k8s.sh 1.0.0

# 10. Verify everything
bash scripts/verify-deployment.sh
```

---

## 🔐 Secret Management (HashiCorp Vault)

### How it works

```
Pod starts
    │
    ▼
Vault Agent Injector (init container)
    │ reads: /var/run/secrets/kubernetes.io/serviceaccount/token
    │ authenticates with Vault Kubernetes auth
    ▼
Vault returns temporary token
    │
    ▼
Agent fetches secrets from:
    secret/data/app   → JWT_SECRET, SESSION_SECRET
    secret/data/mysql → DB_PASSWORD, DB_USER
    │
    ▼
Secrets written to: /vault/secrets/app-creds (tmpfs — never hits disk)
    │
    ▼
Main container sources the file:
    source /vault/secrets/app-creds
    exec node src/server.js
```

### Vault secret paths

| Path | Contents |
|------|----------|
| `secret/data/mysql` | root_password, app_password, app_user, host, port, database |
| `secret/data/app` | jwt_secret, session_secret, api_key |
| `secret/data/ci` | gke_sa_key (for CI/CD) |

### First-time Vault initialization

```bash
# After deploy-vault.sh completes:

# 1. Get Vault pod name
VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}')

# 2. Initialize (save the output SECURELY)
kubectl exec $VAULT_POD -n vault -- vault operator init \
  -key-shares=5 \
  -key-threshold=3

# 3. Unseal (run 3 times with 3 different keys from init output)
kubectl exec $VAULT_POD -n vault -- vault operator unseal <KEY_1>
kubectl exec $VAULT_POD -n vault -- vault operator unseal <KEY_2>
kubectl exec $VAULT_POD -n vault -- vault operator unseal <KEY_3>

# 4. Seed secrets
export VAULT_ADDR=http://localhost:8200
kubectl port-forward svc/vault -n vault 8200:8200 &
export VAULT_TOKEN=<root-token-from-init>
bash scripts/vault-secrets.sh
```

> **Production:** Configure [GCP KMS auto-unseal](https://developer.hashicorp.com/vault/docs/configuration/seal/gcpckms) in `vault/vault-install.yaml` — eliminates manual unseal steps.

---

## 🔄 CI/CD Pipeline

### CI Workflow (`.github/workflows/ci.yml`)

```
Push to main/develop
        │
        ▼
  ┌─────────────┐
  │   Validate   │  npm ci → lint → jest --coverage
  └──────┬──────┘
         │
         ▼
  ┌─────────────────────┐
  │  Build Docker Images │  BuildKit multi-stage (cached layers)
  │  frontend + backend  │
  └──────────┬──────────┘
             │
             ▼
  ┌──────────────────┐
  │  Trivy Security  │  HIGH/CRITICAL CVEs → fail build
  │  Scan both images│  Results → GitHub Security tab
  └──────┬───────────┘
         │ (only if scan passes)
         ▼
  ┌──────────────────────────────┐
  │  Push to Artifact Registry   │
  │  asia-south1-docker.pkg.dev  │
  └──────────────────────────────┘
```

### CD Workflow (`.github/workflows/cd.yml`)

```
CI succeeds on main
        │
        ▼
  ┌────────────┐
  │    Gate    │  Verify CI conclusion == 'success'
  └─────┬──────┘
        │
        ▼
  ┌─────────────────────────────────┐
  │  kubectl set image deployment   │  Rolling update (maxUnavailable=0)
  │  frontend + backend             │
  └──────────┬──────────────────────┘
             │
             ▼
  ┌──────────────────────┐
  │  kubectl rollout      │  Wait 180s for complete rollout
  │  status --timeout     │  Auto-rollback if fails
  └──────────┬────────────┘
             │
             ▼
  ┌──────────────────────┐
  │  HTTP health check   │  curl /health → 200 required
  │  Auto-rollback if ≠  │
  └──────────────────────┘
```

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `GCP_PROJECT_ID` | GCP project ID |
| `GCP_SA_KEY` | Base64-encoded service account JSON |
| `GCP_REGION` | e.g. `asia-south1` |
| `GKE_CLUSTER_NAME` | e.g. `prod-cluster` |
| `GKE_ZONE` | e.g. `asia-south1-a` |
| `GAR_REPO_NAME` | e.g. `prod-repo` |

```bash
# Create and encode service account key
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions CI/CD"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/container.developer"

gcloud iam service-accounts keys create /tmp/sa-key.json \
  --iam-account="github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Add to GitHub Secrets as GCP_SA_KEY:
base64 -i /tmp/sa-key.json | pbcopy   # macOS — paste into GitHub Secret
rm /tmp/sa-key.json
```

---

## 🔁 Rolling Updates

```bash
# Update a specific component
bash scripts/rolling-update.sh backend 1.2.0
bash scripts/rolling-update.sh frontend 1.2.0
bash scripts/rolling-update.sh all 1.2.0

# Manual rollback (if needed)
kubectl rollout undo deployment/backend  -n production
kubectl rollout undo deployment/frontend -n production

# View rollout history
kubectl rollout history deployment/backend -n production
```

---

## 📈 Scaling

```bash
# Manual scaling (HPA overrides this eventually)
bash scripts/scale-app.sh backend 5
bash scripts/scale-app.sh frontend 3

# View HPA status
kubectl get hpa -n production

# HPA scaling rules:
#   Backend:  min=3, max=10, CPU>70% or Memory>80%
#   Frontend: min=2, max=6,  CPU>75%
```

---

## 🩺 Health Probes

| Component | Liveness Probe | Readiness Probe |
|-----------|---------------|-----------------|
| Frontend | `GET /health` (Nginx) | `GET /health` |
| Backend | `GET /api/ping` (**NO DB check**) | `GET /api/health` (validates DB) |
| MySQL | `mysqladmin ping` | `mysql -e 'SELECT 1'` |

> **Critical rule:** Liveness probes must NEVER check external dependencies (DB, cache, APIs).
> If the DB goes down, liveness should NOT restart the pod — that causes cascade restarts.
> Only readiness should check DB connectivity, which stops traffic without restarting pods.

---

## 🐳 Local Development

```bash
# Start everything locally
docker-compose up -d

# Access points:
#   Frontend: http://localhost:80
#   Backend API: http://localhost:3000
#   Vault UI: http://localhost:8200 (token: dev-root-token)
#   MySQL: localhost:3306 (user: appuser, pass: devpass123)

# View logs
docker-compose logs -f backend

# Stop
docker-compose down        # Keep volumes (data preserved)
docker-compose down -v     # Remove volumes (data lost)
```

---

## 🔧 Useful kubectl Commands

```bash
# Pod management
kubectl get pods -n production -o wide
kubectl describe pod <pod-name> -n production
kubectl logs <pod-name> -n production --tail=100 -f
kubectl exec -it <pod-name> -n production -- sh

# Deployment ops
kubectl rollout status deployment/backend -n production
kubectl rollout history deployment/backend -n production
kubectl rollout undo deployment/backend -n production

# Scaling
kubectl scale deployment/backend --replicas=5 -n production

# ConfigMap update (triggers pod restart via checksum annotation)
kubectl edit configmap app-config -n production
kubectl rollout restart deployment/backend -n production

# Port forwarding (debug without external exposure)
kubectl port-forward svc/backend-service 3000:3000 -n production
kubectl port-forward svc/vault 8200:8200 -n vault

# Resource usage
kubectl top pods -n production
kubectl top nodes
```

---

## 🏗️ Key Architecture Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Secret management | HashiCorp Vault | Zero hardcoded secrets anywhere; dynamic injection |
| MySQL deployment type | StatefulSet | Stable pod name, stable PVC binding |
| Liveness probe for backend | `/api/ping` (no DB) | Prevents cascade restarts during DB maintenance |
| `maxUnavailable: 0` | Always 0 | Zero-downtime rolling updates |
| `preStop: sleep 5` | 5s sleep before SIGTERM | Kubernetes removes pod from endpoints before process stops |
| Storage class | `standard-rwo` | GKE SSD, ReadWriteOnce — correct for single-writer MySQL |
| Image registry | Google Artifact Registry | Native GKE integration, IAM-based access, regional |
| Vault Agent mode | Injector (sidecar) | No app code changes needed; transparent secret delivery |

---

## 🧹 Cleanup

```bash
# Remove app only (keep namespace + MySQL data)
bash scripts/cleanup.sh

# Remove everything including MySQL data (DESTRUCTIVE)
bash scripts/cleanup.sh --full

# Delete the entire GKE cluster
gcloud container clusters delete prod-cluster --zone=asia-south1-a
```

---

## 📋 Environment Variables Reference

### Backend (set via ConfigMap + Vault)

| Variable | Source | Description |
|----------|--------|-------------|
| `NODE_ENV` | ConfigMap | `production` |
| `PORT` | ConfigMap | `3000` |
| `DB_HOST` | ConfigMap | `mysql-service` |
| `DB_PORT` | ConfigMap | `3306` |
| `DB_NAME` | ConfigMap | `appdb` |
| `DB_USER` | **Vault** | `appuser` |
| `DB_PASSWORD` | **Vault** | MySQL app user password |
| `JWT_SECRET` | **Vault** | JWT signing key |
| `SESSION_SECRET` | **Vault** | Express session secret |

---

*Built for production. Tested for zero-downtime. Secured with Vault.*
