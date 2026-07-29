#!/bin/bash
# ============================================================================
# Install Trivy Operator in the Kubernetes Cluster
# ============================================================================
# Installs the Trivy Operator which continuously scans all running pods
# for vulnerabilities. Results are stored as Kubernetes CRDs.
#
# Prerequisites:
#   - Helm installed
#   - kubectl configured
#   - Cluster accessible
#
# After installation:
#   kubectl get vulnerabilityreports -n shopping
#   kubectl get vulnerabilityreports -n shopping -o json | \
#     jq '.items[].report.summary'
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " Installing Trivy Operator"
echo "============================================"
echo ""

# Add Helm repo
echo "[1/3] Adding Aqua Security Helm repository..."
helm repo add aqua https://aquasecurity.github.io/helm-charts/ 2>/dev/null || true
helm repo update aqua

# Install the operator
echo ""
echo "[2/3] Installing Trivy Operator..."
helm install trivy-operator aqua/trivy-operator \
  --namespace trivy-system \
  --create-namespace \
  --values "${SCRIPT_DIR}/trivy-operator-values.yaml" \
  --wait --timeout 5m

# Verify installation
echo ""
echo "[3/3] Verifying installation..."
kubectl get pods -n trivy-system
echo ""

echo "============================================"
echo " Trivy Operator installed"
echo "============================================"
echo ""
echo " The operator will now scan all pods in the 'shopping' namespace."
echo " First scan results appear within 5-10 minutes."
echo ""
echo " Query vulnerability reports:"
echo "   kubectl get vulnerabilityreports -n shopping"
echo "   kubectl get vulnerabilityreports -n shopping -o wide"
echo ""
echo " Get summary for a specific report:"
echo '   kubectl get vulnerabilityreport <name> -n shopping -o jsonpath="{.report.summary}"'
echo ""
echo " Prometheus metrics (if ServiceMonitor is enabled):"
echo "   trivy_image_vulnerabilities{severity=\"Critical\"}"
echo ""
