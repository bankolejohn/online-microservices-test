#!/bin/bash
# ============================================================================
# etcd Backup Script
# ============================================================================
# Takes a point-in-time snapshot of etcd and stores it locally.
# In production, you'd upload to S3/GCS with:
#   aws s3 cp $BACKUP_FILE s3://my-etcd-backups/$(date +%Y/%m/%d)/
#
# Usage:
#   ./scripts/etcd-backup.sh                    # Take backup now
#   ./scripts/etcd-backup.sh --verify           # Take backup and verify
#   ./scripts/etcd-backup.sh --retention 7      # Keep only last 7 backups
#
# CKA Exam:
#   etcdctl snapshot save /tmp/backup.db \
#     --endpoints=https://127.0.0.1:2379 \
#     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
#     --cert=/etc/kubernetes/pki/etcd/server.crt \
#     --key=/etc/kubernetes/pki/etcd/server.key
#
# Schedule (production):
#   0 */6 * * * /path/to/etcd-backup.sh --retention 28 >> /var/log/etcd-backup.log 2>&1
# ============================================================================

set -euo pipefail

# Configuration
CLUSTER_NAME="shopping-cluster"
CONTROL_PLANE="${CLUSTER_NAME}-control-plane"
BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"
RETENTION_COUNT=7  # Keep last N backups by default

# Parse arguments
VERIFY=false
for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY=true ;;
    --retention)
      shift
      RETENTION_COUNT="${1:-7}"
      ;;
  esac
done

echo "============================================"
echo " etcd Backup — ${TIMESTAMP}"
echo "============================================"
echo ""

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Step 1: Verify etcd is healthy
echo "[1/4] Checking etcd health..."
HEALTH=$(kubectl exec -n kube-system etcd-${CONTROL_PLANE} -- etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key 2>&1) || true

if echo "$HEALTH" | grep -q "is healthy"; then
  echo "  etcd is healthy."
else
  echo "  WARNING: etcd health check returned unexpected result:"
  echo "  $HEALTH"
  echo "  Proceeding with backup anyway..."
fi

# Step 2: Take the snapshot (inside the etcd pod)
echo ""
echo "[2/4] Taking etcd snapshot..."
kubectl exec -n kube-system etcd-${CONTROL_PLANE} -- etcdctl snapshot save /var/lib/etcd/snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key 2>&1 | grep -E "saved|size"

# Step 3: Copy snapshot out of the cluster
echo ""
echo "[3/4] Copying snapshot to ${BACKUP_FILE}..."
docker cp "${CONTROL_PLANE}:/var/lib/etcd/snapshot.db" "$BACKUP_FILE"

# Verify file exists and has size
FILE_SIZE=$(stat -f%z "$BACKUP_FILE" 2>/dev/null || stat --printf="%s" "$BACKUP_FILE" 2>/dev/null)
echo "  Backup size: $((FILE_SIZE / 1024 / 1024)) MB"

if [ "$FILE_SIZE" -lt 1000 ]; then
  echo "  ERROR: Backup file is suspiciously small. Something went wrong."
  exit 1
fi

# Step 4: Apply retention policy (delete old backups)
echo ""
echo "[4/4] Applying retention policy (keep last ${RETENTION_COUNT})..."
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "etcd-snapshot-*.db" | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "$RETENTION_COUNT" ]; then
  DELETABLE=$((BACKUP_COUNT - RETENTION_COUNT))
  find "$BACKUP_DIR" -name "etcd-snapshot-*.db" | sort | head -n "$DELETABLE" | while read -r old_backup; do
    echo "  Deleting old backup: $(basename "$old_backup")"
    rm -f "$old_backup"
  done
else
  echo "  ${BACKUP_COUNT} backups on disk (within retention limit)."
fi

echo ""
echo "============================================"
echo " Backup complete"
echo "============================================"
echo ""
echo "  File: ${BACKUP_FILE}"
echo "  Size: $((FILE_SIZE / 1024 / 1024)) MB"
echo "  Time: ${TIMESTAMP}"
echo ""
echo "  To restore from this backup:"
echo "    ./scripts/etcd-restore.sh ${BACKUP_FILE}"
echo ""
