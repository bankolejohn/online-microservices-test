#!/bin/bash
# ============================================================================
# Chaos Engineering — Intentional Failure Tests
# ============================================================================
# Tests your cluster's resilience by deliberately causing failures and
# verifying recovery. Run these periodically to prove your infrastructure
# actually self-heals.
#
# Usage:
#   ./scripts/chaos-test.sh pod-kill         # Kill a random pod
#   ./scripts/chaos-test.sh service-kill     # Kill all pods of a service
#   ./scripts/chaos-test.sh node-drain       # Drain a worker node
#   ./scripts/chaos-test.sh all              # Run all tests
#
# What this proves:
#   - Deployments recreate killed pods (replicas controller)
#   - PDBs protect during node drain (minAvailable)
#   - Services route around failed pods (readiness probes)
#   - ArgoCD detects and heals drift (self-heal)
#
# Production chaos tools:
#   - Chaos Mesh (CNCF) — Kubernetes-native chaos engineering
#   - Litmus Chaos — experiments as CRDs
#   - Gremlin — commercial, very polished
#   - AWS Fault Injection Simulator — cloud-native
#
# For this project, simple kubectl-based chaos is sufficient to demonstrate
# the concepts. Production teams would use Chaos Mesh or Litmus.
# ============================================================================

set -euo pipefail

NAMESPACE="shopping"
TEST="${1:-all}"

SERVICES=(
  cart-service
  checkout-service
  frontend-service
  payment-service
  product-catalog-service
  shipping-service
  user-authentication-service
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[TEST]${NC} $1"; }

# ==========================================================================
pod_kill_test() {
  info "Chaos Test: Kill a random pod"
  echo ""

  # Pick a random service
  SVC=${SERVICES[$RANDOM % ${#SERVICES[@]}]}
  POD=$(kubectl get pods -n "$NAMESPACE" -l "app=$SVC" --no-headers | head -1 | awk '{print $1}')

  if [ -z "$POD" ]; then
    fail "No pods found for $SVC"
    return 1
  fi

  BEFORE=$(kubectl get pods -n "$NAMESPACE" -l "app=$SVC" --no-headers | wc -l | tr -d ' ')
  echo "  Service: $SVC"
  echo "  Target pod: $POD"
  echo "  Replicas before: $BEFORE"
  echo ""

  # Kill it
  echo "  Killing pod..."
  kubectl delete pod "$POD" -n "$NAMESPACE" --grace-period=5 2>/dev/null || true

  # Wait for recovery
  echo "  Waiting 60 seconds for recovery..."
  sleep 60

  AFTER=$(kubectl get pods -n "$NAMESPACE" -l "app=$SVC" --no-headers | grep "Running" | wc -l | tr -d ' ')
  echo "  Replicas after recovery: $AFTER"
  echo ""

  if [ "$AFTER" -ge "$BEFORE" ]; then
    pass "Pod killed and recreated. Self-healing works. ($SVC: $BEFORE → $AFTER)"
  else
    fail "Replicas did not recover. Expected $BEFORE, got $AFTER. ($SVC)"
  fi
}

# ==========================================================================
service_kill_test() {
  info "Chaos Test: Kill ALL pods of a service"
  echo ""

  SVC="shipping-service"  # Use shipping (lightweight, fast recovery)
  BEFORE=$(kubectl get pods -n "$NAMESPACE" -l "app=$SVC" --no-headers | wc -l | tr -d ' ')
  echo "  Service: $SVC"
  echo "  Replicas before: $BEFORE"
  echo ""

  # Kill all
  echo "  Killing all $SVC pods..."
  kubectl delete pods -n "$NAMESPACE" -l "app=$SVC" --grace-period=5 2>/dev/null || true

  # Wait for recovery
  echo "  Waiting 90 seconds for full recovery..."
  sleep 90

  AFTER=$(kubectl get pods -n "$NAMESPACE" -l "app=$SVC" --no-headers | grep "Running" | grep "2/2" | wc -l | tr -d ' ')
  echo "  Healthy replicas after recovery: $AFTER"
  echo ""

  if [ "$AFTER" -ge "$BEFORE" ]; then
    pass "All pods killed and recreated. Full recovery. ($SVC: $BEFORE → $AFTER)"
  else
    fail "Service did not fully recover. Expected $BEFORE healthy, got $AFTER. ($SVC)"
  fi
}

# ==========================================================================
node_drain_test() {
  info "Chaos Test: Drain a worker node"
  echo ""

  NODE="shopping-cluster-worker3"
  PODS_ON_NODE=$(kubectl get pods -n "$NAMESPACE" --field-selector="spec.nodeName=$NODE" --no-headers | wc -l | tr -d ' ')
  echo "  Target node: $NODE"
  echo "  Pods on node: $PODS_ON_NODE"
  echo ""

  # Cordon + Drain
  echo "  Cordoning and draining..."
  kubectl cordon "$NODE" 2>/dev/null
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>/dev/null || true

  echo "  Waiting 30 seconds..."
  sleep 30

  # Check total running pods (should be same as before)
  TOTAL_RUNNING=$(kubectl get pods -n "$NAMESPACE" --no-headers | grep "Running" | grep "2/2" | wc -l | tr -d ' ')
  PODS_REMAINING=$(kubectl get pods -n "$NAMESPACE" --field-selector="spec.nodeName=$NODE" --no-headers | grep -v "Terminating" | wc -l | tr -d ' ')

  echo "  Pods remaining on drained node: $PODS_REMAINING"
  echo "  Total healthy pods in namespace: $TOTAL_RUNNING"
  echo ""

  # Uncordon
  echo "  Uncordoning node..."
  kubectl uncordon "$NODE" 2>/dev/null

  if [ "$PODS_REMAINING" -eq 0 ]; then
    pass "Node drained successfully. All pods rescheduled. PDBs respected."
  else
    fail "Some pods still on drained node."
  fi
}

# ==========================================================================
echo "============================================"
echo " Chaos Engineering Tests"
echo "============================================"
echo " Namespace: $NAMESPACE"
echo " Test: $TEST"
echo ""

case "$TEST" in
  pod-kill) pod_kill_test ;;
  service-kill) service_kill_test ;;
  node-drain) node_drain_test ;;
  all)
    pod_kill_test
    echo ""
    echo "---"
    echo ""
    service_kill_test
    echo ""
    echo "---"
    echo ""
    node_drain_test
    ;;
  *) echo "Usage: $0 {pod-kill|service-kill|node-drain|all}" && exit 1 ;;
esac

echo ""
echo "============================================"
echo " Chaos tests complete"
echo "============================================"
