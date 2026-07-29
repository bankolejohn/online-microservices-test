#!/bin/bash
# ============================================================================
# Kubernetes Cluster Upgrade Runbook Script
# ============================================================================
# This script documents and partially automates the kubeadm upgrade process.
# It upgrades from one minor version to the next (e.g., 1.36 → 1.37).
#
# IMPORTANT RULES:
#   1. Always upgrade ONE minor version at a time (1.36→1.37, NOT 1.36→1.38)
#   2. Always upgrade control plane FIRST, then workers
#   3. Always take an etcd backup BEFORE starting
#   4. Always drain worker nodes ONE AT A TIME (never all at once)
#   5. The kubelet can be at most 2 minor versions behind the API server
#
# CKA EXAM: This procedure is tested directly. Know the commands cold.
#
# Usage (documentation mode — shows what to do without executing):
#   ./scripts/cluster-upgrade.sh --dry-run
#
# Usage (on a real kubeadm cluster — NOT Kind):
#   ./scripts/cluster-upgrade.sh --target-version 1.37.0
#
# Prerequisites:
#   - etcd backup taken (./scripts/etcd-backup.sh)
#   - Maintenance window communicated to the team
#   - PDBs in place for all critical services
#   - Monitoring dashboards open (watch for errors during upgrade)
# ============================================================================

set -euo pipefail

TARGET_VERSION="${2:-1.37.0}"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --target-version) shift ;;
  esac
done

CURRENT_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' | sed 's/v//')
CONTROL_PLANE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
WORKERS=$(kubectl get nodes --no-headers | grep -v control-plane | awk '{print $1}')

echo "============================================"
echo " Kubernetes Cluster Upgrade Runbook"
echo "============================================"
echo ""
echo " Current version: v${CURRENT_VERSION}"
echo " Target version:  v${TARGET_VERSION}"
echo " Control plane:   ${CONTROL_PLANE}"
echo " Workers:         $(echo $WORKERS | tr '\n' ' ')"
echo " Mode:            $([ "$DRY_RUN" = true ] && echo 'DRY RUN (showing commands only)' || echo 'LIVE')"
echo ""
echo "============================================"

# ============================================================================
# PRE-UPGRADE CHECKS
# ============================================================================
echo ""
echo "=== PRE-UPGRADE CHECKS ==="
echo ""

echo "1. Verify all nodes are Ready:"
kubectl get nodes
echo ""

echo "2. Verify no pods in bad state:"
BAD_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | grep -v "NAMESPACE" | grep -v "Completed" | wc -l | tr -d ' ')
echo "   Pods in non-Running state: ${BAD_PODS}"
if [ "$BAD_PODS" -gt 5 ]; then
  echo "   WARNING: Many pods in bad state. Fix before upgrading."
fi
echo ""

echo "3. Verify etcd backup exists:"
LATEST_BACKUP=$(find "$(dirname "$0")/../backups" -name "etcd-snapshot-*.db" 2>/dev/null | sort | tail -1)
if [ -n "$LATEST_BACKUP" ]; then
  echo "   Latest backup: $(basename "$LATEST_BACKUP")"
else
  echo "   WARNING: No etcd backup found! Run ./scripts/etcd-backup.sh first."
fi
echo ""

echo "4. Verify PDBs are in place:"
kubectl get pdb -n shopping --no-headers 2>/dev/null | wc -l | tr -d ' ' | xargs -I{} echo "   PDBs configured: {}"
echo ""

# ============================================================================
# PHASE 1: UPGRADE CONTROL PLANE
# ============================================================================
echo "=== PHASE 1: UPGRADE CONTROL PLANE ==="
echo ""
echo "On the control-plane node (${CONTROL_PLANE}):"
echo ""
echo "  # Step 1: Update package repository"
echo "  sudo apt-get update"
echo ""
echo "  # Step 2: Check available kubeadm versions"
echo "  sudo apt-cache madison kubeadm | head -5"
echo ""
echo "  # Step 3: Upgrade kubeadm to target version"
echo "  sudo apt-mark unhold kubeadm"
echo "  sudo apt-get install -y kubeadm=${TARGET_VERSION}-1.1"
echo "  sudo apt-mark hold kubeadm"
echo ""
echo "  # Step 4: Verify kubeadm version"
echo "  kubeadm version"
echo ""
echo "  # Step 5: Check upgrade plan (shows what will change)"
echo "  sudo kubeadm upgrade plan"
echo ""
echo "  # Step 6: Apply the upgrade (this upgrades API server, controller-manager, scheduler)"
echo "  sudo kubeadm upgrade apply v${TARGET_VERSION}"
echo ""
echo "  # Step 7: Upgrade kubelet and kubectl on control-plane"
echo "  sudo apt-mark unhold kubelet kubectl"
echo "  sudo apt-get install -y kubelet=${TARGET_VERSION}-1.1 kubectl=${TARGET_VERSION}-1.1"
echo "  sudo apt-mark hold kubelet kubectl"
echo ""
echo "  # Step 8: Restart kubelet"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl restart kubelet"
echo ""
echo "  # Step 9: Verify control-plane is upgraded"
echo "  kubectl get nodes"
echo "  # Control-plane should show v${TARGET_VERSION}"
echo ""

# ============================================================================
# PHASE 2: UPGRADE WORKER NODES (ONE AT A TIME)
# ============================================================================
echo "=== PHASE 2: UPGRADE WORKER NODES (ONE AT A TIME) ==="
echo ""

for WORKER in $WORKERS; do
  echo "--- Upgrading ${WORKER} ---"
  echo ""
  echo "  # Step 1: Cordon the node (mark unschedulable)"
  echo "  kubectl cordon ${WORKER}"
  echo ""
  echo "  # Step 2: Drain the node (evict pods — PDBs protect availability)"
  echo "  kubectl drain ${WORKER} --ignore-daemonsets --delete-emptydir-data"
  echo ""
  echo "  # Step 3: SSH into the worker and upgrade kubeadm"
  echo "  ssh ${WORKER}"
  echo "  sudo apt-mark unhold kubeadm"
  echo "  sudo apt-get install -y kubeadm=${TARGET_VERSION}-1.1"
  echo "  sudo apt-mark hold kubeadm"
  echo ""
  echo "  # Step 4: Upgrade node config"
  echo "  sudo kubeadm upgrade node"
  echo ""
  echo "  # Step 5: Upgrade kubelet and kubectl"
  echo "  sudo apt-mark unhold kubelet kubectl"
  echo "  sudo apt-get install -y kubelet=${TARGET_VERSION}-1.1 kubectl=${TARGET_VERSION}-1.1"
  echo "  sudo apt-mark hold kubelet kubectl"
  echo ""
  echo "  # Step 6: Restart kubelet"
  echo "  sudo systemctl daemon-reload"
  echo "  sudo systemctl restart kubelet"
  echo "  exit  # back to local machine"
  echo ""
  echo "  # Step 7: Uncordon the node (allow pods to be scheduled)"
  echo "  kubectl uncordon ${WORKER}"
  echo ""
  echo "  # Step 8: Verify pods are rescheduled and healthy"
  echo "  kubectl get pods -n shopping -o wide | grep ${WORKER}"
  echo "  kubectl get nodes  # Should show v${TARGET_VERSION}"
  echo ""
  echo "  # Step 9: Wait 2-5 minutes, check monitoring dashboards"
  echo "  # Ensure no error rate spike before proceeding to next node"
  echo ""
done

# ============================================================================
# POST-UPGRADE VERIFICATION
# ============================================================================
echo "=== POST-UPGRADE VERIFICATION ==="
echo ""
echo "  # 1. All nodes should show the new version"
echo "  kubectl get nodes"
echo ""
echo "  # 2. All pods should be Running"
echo "  kubectl get pods --all-namespaces | grep -v Running | grep -v Completed"
echo ""
echo "  # 3. Verify cluster components"
echo "  kubectl get componentstatuses  # (deprecated but sometimes still works)"
echo "  kubectl get --raw /healthz"
echo ""
echo "  # 4. Run a smoke test (deploy a test pod, check DNS, check services)"
echo "  kubectl run test-pod --image=busybox --rm -it --restart=Never -- nslookup kubernetes"
echo ""
echo "  # 5. Take a NEW etcd backup (post-upgrade state)"
echo "  ./scripts/etcd-backup.sh"
echo ""
echo "============================================"
echo " Upgrade runbook complete"
echo "============================================"
echo ""
echo " Duration estimate: 30-60 minutes for a 4-node cluster"
echo " Key risk: if kubelet can't rejoin after upgrade, the node stays NotReady"
echo " Rollback: restore etcd from pre-upgrade backup + reinstall old kubelet version"
echo ""
