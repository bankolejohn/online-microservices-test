#!/bin/bash
# ============================================================================
# Deploy All Services Using the Mono Chart
# ============================================================================
# Demonstrates the mono-chart pattern: ONE chart deployed N times, each with
# a different values file. This is how you'd manage 7 — or 700 — services.
#
# Usage:
#   ./charts/mono-chart/deploy-all.sh              # Install/upgrade all
#   ./charts/mono-chart/deploy-all.sh cart-service # Just one service
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR"
VALUES_DIR="$SCRIPT_DIR/values"
NAMESPACE="shopping"

TARGET="${1:-all}"

echo "============================================"
echo " Deploying via Mono Chart"
echo "============================================"
echo ""

# Get list of services (from values files) or a single target
if [ "$TARGET" = "all" ]; then
  SERVICES=$(ls "$VALUES_DIR" | sed 's/.yaml//')
else
  SERVICES="$TARGET"
fi

for SVC in $SERVICES; do
  VALUES_FILE="$VALUES_DIR/${SVC}.yaml"
  if [ ! -f "$VALUES_FILE" ]; then
    echo "  Skipping $SVC (no values file)"
    continue
  fi

  echo "Deploying $SVC ..."
  helm upgrade --install "$SVC" "$CHART_DIR" \
    -f "$VALUES_FILE" \
    --namespace "$NAMESPACE" \
    --create-namespace
  echo ""
done

echo "============================================"
echo " Done. Each service is a separate Helm release:"
echo "============================================"
helm list -n "$NAMESPACE"
