#!/bin/bash
# ============================================================================
# ArgoCD Rollback Script
# ============================================================================
# Rolls back an ArgoCD application to a previous revision.
#
# Usage:
#   ./rollback.sh staging          # Roll back staging to previous revision
#   ./rollback.sh prod             # Roll back production to previous revision
#   ./rollback.sh staging 3        # Roll back staging to revision 3
#
# What this does:
#   1. Lists recent deployment history
#   2. Rolls back to the previous (or specified) revision
#   3. Verifies the rollback succeeded
#
# Note: This uses ArgoCD's built-in rollback which reverts to a previous
# git commit's manifests. For a full GitOps rollback, you'd also revert
# the image tag in git (so ArgoCD doesn't re-sync forward).
# ============================================================================

set -euo pipefail

ENV="${1:-}"
REVISION="${2:-}"

if [ -z "$ENV" ]; then
  echo "Usage: ./rollback.sh <staging|prod> [revision_number]"
  echo ""
  echo "Examples:"
  echo "  ./rollback.sh staging        # Roll back to previous version"
  echo "  ./rollback.sh prod 3         # Roll back to revision 3"
  exit 1
fi

# Map environment to ArgoCD application name
case "$ENV" in
  staging) APP="online-shopping-staging" ;;
  prod|production) APP="online-shopping-prod" ;;
  *) echo "Error: Unknown environment '$ENV'. Use 'staging' or 'prod'."; exit 1 ;;
esac

echo "============================================"
echo " Rolling back: ${APP}"
echo "============================================"

# Show current status
echo ""
echo "Current status:"
argocd app get "$APP" --output json | jq '{
  health: .status.health.status,
  sync: .status.sync.status,
  revision: .status.sync.revision,
  deployedAt: .status.operationState.finishedAt
}'

# Show history
echo ""
echo "Deployment history (last 5):"
argocd app history "$APP" | tail -6

# Perform rollback
echo ""
if [ -n "$REVISION" ]; then
  echo "Rolling back to revision ${REVISION}..."
  argocd app rollback "$APP" "$REVISION"
else
  echo "Rolling back to previous revision..."
  # Get the previous revision number
  PREV_REV=$(argocd app history "$APP" --output json | jq -r '.[-2].revision // empty')
  if [ -z "$PREV_REV" ]; then
    echo "Error: No previous revision found. Cannot rollback."
    exit 1
  fi
  argocd app rollback "$APP" "$PREV_REV"
fi

# Verify
echo ""
echo "Verifying rollback..."
sleep 10

STATUS=$(argocd app get "$APP" --output json | jq -r '.status.health.status')
echo "Health status: ${STATUS}"

if [ "$STATUS" = "Healthy" ]; then
  echo ""
  echo "Rollback successful."
else
  echo ""
  echo "WARNING: Application health is '${STATUS}'. Check ArgoCD UI for details."
  echo "  argocd app get ${APP}"
fi

echo ""
echo "============================================"
echo " Rollback complete"
echo "============================================"
echo ""
echo "IMPORTANT: To make this rollback permanent (prevent ArgoCD from"
echo "re-syncing forward), also revert the image tag in git:"
echo ""
echo "  git revert HEAD   # If the last commit was the CD image tag update"
echo "  git push origin main"
echo ""
