#!/bin/bash
# ============================================================================
# ArgoCD Installation Script
# ============================================================================
# Installs ArgoCD into the Kind cluster and configures it for GitOps.
#
# Prerequisites:
#   - Kind cluster running (shopping-cluster)
#   - kubectl configured to use the cluster
#   - GitHub repo accessible (public or with deploy key)
#
# What this script does:
#   1. Creates the argocd namespace
#   2. Installs ArgoCD (stable release)
#   3. Waits for ArgoCD pods to be ready
#   4. Patches the argocd-server to use NodePort (accessible from host)
#   5. Retrieves the initial admin password
#   6. Applies the AppProject and Application manifests
#
# After running:
#   - ArgoCD UI: https://localhost:8443 (via port-forward)
#   - ArgoCD CLI: argocd login localhost:8443 --insecure
#   - Initial password: printed at the end of this script
# ============================================================================

set -euo pipefail

ARGOCD_VERSION="v2.13.3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " Installing ArgoCD ${ARGOCD_VERSION}"
echo "============================================"

# Step 1: Create namespace
echo ""
echo "[1/6] Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Install ArgoCD
echo ""
echo "[2/6] Installing ArgoCD manifests..."
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Step 3: Wait for pods to be ready
echo ""
echo "[3/6] Waiting for ArgoCD pods to be ready (this may take 2-3 minutes)..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller -n argocd

echo "ArgoCD pods are ready."

# Step 4: Patch argocd-server for insecure access (no TLS termination needed in Kind)
echo ""
echo "[4/6] Configuring ArgoCD server for local access..."
kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]' \
  2>/dev/null || true

# Step 5: Apply AppProject and Applications
echo ""
echo "[5/6] Applying ArgoCD project and applications..."
kubectl apply -f "${SCRIPT_DIR}/appproject.yaml"
kubectl apply -f "${SCRIPT_DIR}/application-staging.yaml"
kubectl apply -f "${SCRIPT_DIR}/application-prod.yaml"

# Step 6: Retrieve initial admin password
echo ""
echo "[6/6] Retrieving ArgoCD admin credentials..."
echo ""

# Wait for the secret to be available
sleep 5
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo "============================================"
echo " ArgoCD Installation Complete"
echo "============================================"
echo ""
echo " Username: admin"
echo " Password: ${ARGOCD_PASSWORD}"
echo ""
echo " Access the UI:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "   Open: https://localhost:8443"
echo ""
echo " Install ArgoCD CLI (optional):"
echo "   brew install argocd"
echo ""
echo " Login via CLI:"
echo "   argocd login localhost:8443 --insecure --username admin --password '${ARGOCD_PASSWORD}'"
echo ""
echo " Applications deployed:"
echo "   - online-shopping-staging (auto-sync enabled)"
echo "   - online-shopping-prod    (manual sync — requires approval)"
echo ""
echo "============================================"
