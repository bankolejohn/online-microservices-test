#!/bin/bash
# ============================================================================
# Build All Services — Local Development (Kind Cluster)
# ============================================================================
# Builds all Docker images and loads them into the Kind cluster.
# This is the LOCAL DEV workflow. For staging/prod, GitHub Actions CI handles
# building and pushing to GHCR.
#
# Usage:
#   ./build-all.sh                 # Build all services, load into Kind
#   ./build-all.sh --no-load       # Build only (don't load into Kind)
#   ./build-all.sh cart-service    # Build a single service
#
# Image tagging strategy:
#   - Local dev: <service>:latest (loaded into Kind)
#   - CI/CD: ghcr.io/bankolejohn/online-shopping/<service>:sha-<commit>
# ============================================================================

set -euo pipefail

CLUSTER_NAME="shopping-cluster"
SERVICES=(
  frontend-service
  product-catalog-service
  cart-service
  user-authentication-service
  checkout-service
  payment-service
  shipping-service
)

NO_LOAD=false
TARGET_SERVICE=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --no-load) NO_LOAD=true ;;
    *) TARGET_SERVICE="$arg" ;;
  esac
done

# If a specific service is requested, only build that one
if [ -n "$TARGET_SERVICE" ]; then
  SERVICES=("$TARGET_SERVICE")
fi

echo "============================================"
echo " Building microservices Docker images"
echo "============================================"
echo ""

# Verify Kind cluster exists
if ! kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "ERROR: Kind cluster '$CLUSTER_NAME' not found."
  echo "Create it with: kind create cluster --config kind-cluster.yaml --name $CLUSTER_NAME"
  exit 1
fi

# Build each service
FAILED=()
for SERVICE in "${SERVICES[@]}"; do
  echo "Building ${SERVICE}..."

  if [ ! -d "$SERVICE" ]; then
    echo "  WARNING: Directory '$SERVICE' not found, skipping."
    FAILED+=("$SERVICE")
    continue
  fi

  if docker build -t "${SERVICE}:latest" "./${SERVICE}" --quiet; then
    echo "  Built: ${SERVICE}:latest"
  else
    echo "  FAILED: ${SERVICE}"
    FAILED+=("$SERVICE")
  fi
done

echo ""

# Load images into Kind
if [ "$NO_LOAD" = false ]; then
  echo "============================================"
  echo " Loading images into Kind cluster"
  echo "============================================"
  echo ""

  for SERVICE in "${SERVICES[@]}"; do
    # Skip services that failed to build
    if [[ " ${FAILED[*]} " =~ " ${SERVICE} " ]]; then
      continue
    fi

    echo "Loading ${SERVICE}:latest into ${CLUSTER_NAME}..."
    kind load docker-image "${SERVICE}:latest" --name "$CLUSTER_NAME" 2>/dev/null
  done

  echo ""
fi

# Summary
echo "============================================"
echo " Build Summary"
echo "============================================"
echo ""
echo "  Built: $((${#SERVICES[@]} - ${#FAILED[@]}))/${#SERVICES[@]} services"

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "  Failed: ${FAILED[*]}"
  echo ""
  exit 1
fi

echo ""
echo "To deploy to your local cluster:"
echo "  kubectl apply -k k8s/overlays/dev"
echo ""
echo "To restart deployments (pick up new images):"
echo "  kubectl rollout restart deployment -n shopping"
echo ""
