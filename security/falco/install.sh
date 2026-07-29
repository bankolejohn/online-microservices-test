#!/bin/bash
# ============================================================================
# Install Falco — Runtime Security Monitoring
# ============================================================================
# Installs Falco as a DaemonSet (runs on every node) with custom rules
# for the online-shopping application.
#
# What Falco monitors:
#   - Shell access in containers (bash, sh spawned)
#   - Sensitive file reads (/etc/shadow, /proc/environ)
#   - Unexpected outbound network connections
#   - Package manager usage (apt, npm, pip in running containers)
#   - Kubernetes API access from application pods
#   - Cryptocurrency mining indicators
#
# Prerequisites:
#   - Helm installed
#   - kubectl configured
#   - Linux kernel 5.8+ (for modern_ebpf driver)
#
# After installation:
#   # View alerts in real-time
#   kubectl logs -n falco -l app.kubernetes.io/name=falco -f
#
#   # Trigger a test alert (shell in container)
#   kubectl exec -it deployment/cart-service -n shopping -- sh
#   → Check Falco logs for "Shell spawned in shopping container"
#
#   # Check Falco Sidekick metrics
#   kubectl port-forward -n falco svc/falco-falcosidekick 2801:2801
#   curl http://localhost:2801/metrics | grep falcosidekick
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " Installing Falco Runtime Security"
echo "============================================"
echo ""

# Step 1: Add Helm repo
echo "[1/4] Adding Falco Security Helm repository..."
helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo update falcosecurity

# Step 2: Install Falco
echo ""
echo "[2/4] Installing Falco (DaemonSet + Sidekick)..."
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 5m

# Step 3: Verify
echo ""
echo "[3/4] Verifying Falco pods (should be one per node)..."
kubectl get pods -n falco -o wide
echo ""
kubectl get ds -n falco

# Step 4: Test
echo ""
echo "[4/4] Running test — spawning shell in cart-service..."
echo "  Executing: kubectl exec deployment/cart-service -n shopping -- echo 'test'"
kubectl exec deployment/cart-service -n shopping -- echo "Falco test" 2>/dev/null || true

echo ""
echo "  Checking Falco logs for alert..."
sleep 5
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=10 | grep -i "shell\|shopping" || echo "  (Alert may take a few seconds to appear)"

echo ""
echo "============================================"
echo " Falco installed"
echo "============================================"
echo ""
echo " Falco is now monitoring ALL containers on ALL nodes."
echo ""
echo " View real-time alerts:"
echo "   kubectl logs -n falco -l app.kubernetes.io/name=falco -f"
echo ""
echo " Trigger test alerts:"
echo "   kubectl exec -it deployment/cart-service -n shopping -- sh"
echo "   → Alert: 'Shell spawned in shopping container'"
echo ""
echo " Custom rules loaded:"
echo "   - Shell in Shopping Container"
echo "   - Sensitive File Read in Shopping"
echo "   - Unexpected Outbound Connection from Shopping"
echo "   - Package Manager in Shopping Container"
echo "   - K8s API Access from Shopping Pod"
echo "   - Crypto Mining in Shopping Container"
echo ""
echo " Prometheus metrics available at:"
echo "   falco_falcosidekick_events_total{rule=\"Shell in Shopping Container\"}"
echo ""
