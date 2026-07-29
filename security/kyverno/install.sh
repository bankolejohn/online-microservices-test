#!/bin/bash
# ============================================================================
# Install Kyverno — Kubernetes Policy Engine
# ============================================================================
# Kyverno validates, mutates, and generates Kubernetes resources based on
# policies you define in YAML. It runs as an admission controller — every
# kubectl apply goes through Kyverno before reaching etcd.
#
# What it does:
#   - VALIDATE: reject resources that violate policies (no latest tag, etc.)
#   - MUTATE: automatically add labels, resource limits, securityContext
#   - GENERATE: create NetworkPolicies, ConfigMaps when namespaces are created
#
# Prerequisites:
#   - Helm installed
#   - kubectl configured
#   - GitHub Pages reachable (https://kyverno.github.io)
#
# After installation:
#   kubectl get clusterpolicies
#   kubectl get policyreports -A
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " Installing Kyverno Policy Engine"
echo "============================================"
echo ""

# Step 1: Add Helm repo
echo "[1/4] Adding Kyverno Helm repository..."
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update kyverno

# Step 2: Install Kyverno
echo ""
echo "[2/4] Installing Kyverno..."
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --wait --timeout 5m

# Step 3: Verify
echo ""
echo "[3/4] Verifying Kyverno pods..."
kubectl get pods -n kyverno

# Step 4: Apply policies
echo ""
echo "[4/4] Applying cluster policies..."
kubectl apply -f "${SCRIPT_DIR}/policies/"
echo ""
kubectl get clusterpolicies

echo ""
echo "============================================"
echo " Kyverno installed with policies"
echo "============================================"
echo ""
echo " Policies applied:"
echo "   - disallow-latest-tag (enforce)"
echo "   - require-resource-limits (enforce)"
echo "   - require-labels (enforce)"
echo "   - restrict-image-registries (enforce)"
echo "   - disallow-privilege-escalation (enforce)"
echo ""
echo " Test a policy violation:"
echo "   kubectl run test --image=nginx:latest -n shopping"
echo "   → Should be REJECTED (latest tag not allowed)"
echo ""
echo " View policy reports:"
echo "   kubectl get policyreports -n shopping"
echo ""
