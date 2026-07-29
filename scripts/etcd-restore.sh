#!/bin/bash
# ============================================================================
# etcd Restore Script
# ============================================================================
# Restores etcd from a snapshot file. This is a DESTRUCTIVE operation —
# all cluster state after the snapshot was taken will be LOST.
#
# When to use:
#   - Accidental deletion of critical resources
#   - Cluster corruption
#   - Ransomware recovery (if attacker modified cluster state)
#   - CKA exam (they will ask you to do this)
#
# Usage:
#   ./scripts/etcd-restore.sh backups/etcd-snapshot-20260727-103730.db
#
# What happens:
#   1. Copies snapshot into the control-plane node
#   2. Stops the etcd static pod (moves manifest temporarily)
#   3. Removes old etcd data directory
#   4. Restores snapshot to a new data directory
#   5. Starts etcd again (moves manifest back)
#   6. Waits for API server to recover
#
# WARNING:
#   - All changes made AFTER the snapshot was taken are LOST
#   - The cluster will be unavailable for 30-60 seconds during restore
#   - In production, you'd drain nodes first and notify the team
#
# CKA Exam Command (memorize this):
#   etcdctl snapshot restore /tmp/backup.db \
#     --data-dir=/var/lib/etcd-restored
#   Then update the etcd static pod manifest to point to the new data-dir.
# ============================================================================

set -euo pipefail

SNAPSHOT_FILE="${1:-}"
CLUSTER_NAME="shopping-cluster"
CONTROL_PLANE="${CLUSTER_NAME}-control-plane"

if [ -z "$SNAPSHOT_FILE" ]; then
  echo "Usage: ./scripts/etcd-restore.sh <path-to-snapshot.db>"
  echo ""
  echo "Available backups:"
  find "$(dirname "$0")/../backups" -name "etcd-snapshot-*.db" -exec basename {} \; 2>/dev/null | sort
  exit 1
fi

if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "ERROR: Snapshot file not found: ${SNAPSHOT_FILE}"
  exit 1
fi

echo "============================================"
echo " etcd Restore — DESTRUCTIVE OPERATION"
echo "============================================"
echo ""
echo " Snapshot: ${SNAPSHOT_FILE}"
echo " Cluster:  ${CLUSTER_NAME}"
echo ""
echo " WARNING: All changes after this snapshot will be LOST."
echo ""
read -p " Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "[1/6] Copying snapshot into control-plane node..."
docker cp "$SNAPSHOT_FILE" "${CONTROL_PLANE}:/root/snapshot.db"

echo ""
echo "[2/6] Stopping etcd (moving static pod manifest)..."
# In Kind, static pod manifests are at /etc/kubernetes/manifests/
# Moving the file out stops the pod. Moving it back starts it.
docker exec "$CONTROL_PLANE" mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.bak

echo "  Waiting for etcd to stop..."
sleep 10

echo ""
echo "[3/6] Removing old etcd data directory..."
docker exec "$CONTROL_PLANE" rm -rf /var/lib/etcd

echo ""
echo "[4/6] Restoring snapshot to new data directory..."
# In etcd v3.6+, restore was moved from etcdctl to etcdutl
# Find etcdutl in the containerd snapshot layers
ETCDUTL_PATH=$(docker exec "$CONTROL_PLANE" find /var/lib/containerd -name "etcdutl" 2>/dev/null | head -1)
if [ -z "$ETCDUTL_PATH" ]; then
  echo "  ERROR: etcdutl not found on the control-plane node."
  echo "  Trying etcdctl (older versions)..."
  ETCDUTL_PATH=$(docker exec "$CONTROL_PLANE" find /var/lib/containerd -name "etcdctl" 2>/dev/null | head -1)
fi

docker exec "$CONTROL_PLANE" "$ETCDUTL_PATH" snapshot restore /root/snapshot.db \
  --data-dir=/var/lib/etcd 2>&1

echo ""
echo "[5/6] Restarting etcd (restoring static pod manifest)..."
docker exec "$CONTROL_PLANE" mv /tmp/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml

echo "  Waiting for etcd and API server to recover (this takes 30-60 seconds)..."
sleep 30

echo ""
echo "[6/6] Verifying cluster is responsive..."
RETRIES=10
for i in $(seq 1 $RETRIES); do
  if kubectl get nodes &>/dev/null; then
    echo "  Cluster is responsive."
    break
  fi
  if [ "$i" -eq "$RETRIES" ]; then
    echo "  WARNING: Cluster not yet responsive after ${RETRIES} attempts."
    echo "  Wait a minute and try: kubectl get nodes"
    exit 1
  fi
  echo "  Attempt ${i}/${RETRIES} — waiting..."
  sleep 10
done

echo ""
echo "============================================"
echo " Restore complete"
echo "============================================"
echo ""
echo "  Cluster state has been restored to the snapshot point-in-time."
echo "  Any resources created AFTER the snapshot will not exist."
echo ""
echo "  Verify:"
echo "    kubectl get pods -n shopping"
echo "    kubectl get deployments -n shopping"
echo ""
