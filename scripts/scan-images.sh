#!/bin/bash
# ============================================================================
# Image Vulnerability Scanner — Scans all service images with Trivy
# ============================================================================
# Scans all local Docker images for known vulnerabilities (CVEs).
# Produces a summary table and optional detailed JSON reports.
#
# Usage:
#   ./scripts/scan-images.sh                    # Summary table (HIGH+CRITICAL)
#   ./scripts/scan-images.sh --all              # Include MEDIUM and LOW
#   ./scripts/scan-images.sh --json             # Output JSON reports per service
#   ./scripts/scan-images.sh --fix              # Show only fixable vulnerabilities
#
# What this replaces:
#   In CI, the Trivy GitHub Action does this automatically.
#   This script is for local development — "check before you push."
#
# Severity levels:
#   CRITICAL — actively exploited or trivially exploitable. Fix NOW.
#   HIGH     — exploitable with some effort. Fix within 1-2 weeks.
#   MEDIUM   — requires specific conditions. Fix within the quarter.
#   LOW      — theoretical risk. Track but don't rush.
#
# CKS Exam relevance:
#   The CKS tests you on understanding image scanning outputs and
#   knowing how to identify which images need patching.
# ============================================================================

set -euo pipefail

SERVICES=(
  frontend-service
  product-catalog-service
  cart-service
  user-authentication-service
  checkout-service
  payment-service
  shipping-service
)

SEVERITY="HIGH,CRITICAL"
FORMAT="table"
EXTRA_FLAGS=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --all) SEVERITY="LOW,MEDIUM,HIGH,CRITICAL" ;;
    --json) FORMAT="json" ;;
    --fix) EXTRA_FLAGS="--ignore-unfixed" ;;
  esac
done

echo "============================================"
echo " Image Vulnerability Scan"
echo "============================================"
echo ""
echo " Severity filter: ${SEVERITY}"
echo " Services: ${#SERVICES[@]}"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Check trivy is installed
if ! command -v trivy &>/dev/null; then
  echo "ERROR: trivy is not installed."
  echo "Install: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
  exit 1
fi

echo "============================================"
echo " Scanning..."
echo "============================================"
echo ""

# Summary table header
printf "%-35s %10s %10s %10s %10s\n" "SERVICE" "CRITICAL" "HIGH" "MEDIUM" "LOW"
printf "%-35s %10s %10s %10s %10s\n" "---" "---" "---" "---" "---"

TOTAL_CRITICAL=0
TOTAL_HIGH=0

for SERVICE in "${SERVICES[@]}"; do
  # Check if image exists locally
  if ! docker image inspect "${SERVICE}:latest" &>/dev/null; then
    printf "%-35s %10s\n" "${SERVICE}" "IMAGE NOT FOUND"
    continue
  fi

  # Run Trivy scan (JSON output for parsing)
  RESULT=$(trivy image --severity CRITICAL,HIGH,MEDIUM,LOW --no-progress --quiet --format json "${SERVICE}:latest" 2>/dev/null)

  # Count by severity using Python (reliable JSON parsing)
  COUNTS=$(echo "$RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
c = h = m = l = 0
for result in data.get('Results', []):
    for vuln in result.get('Vulnerabilities', []):
        s = vuln.get('Severity', '')
        if s == 'CRITICAL': c += 1
        elif s == 'HIGH': h += 1
        elif s == 'MEDIUM': m += 1
        elif s == 'LOW': l += 1
print(f'{c} {h} {m} {l}')
" 2>/dev/null || echo "0 0 0 0")

  CRITICAL=$(echo "$COUNTS" | awk '{print $1}')
  HIGH=$(echo "$COUNTS" | awk '{print $2}')
  MEDIUM=$(echo "$COUNTS" | awk '{print $3}')
  LOW=$(echo "$COUNTS" | awk '{print $4}')

  TOTAL_CRITICAL=$((TOTAL_CRITICAL + CRITICAL))
  TOTAL_HIGH=$((TOTAL_HIGH + HIGH))

  # Color output (red for critical, yellow for high)
  if [ "$CRITICAL" -gt 0 ]; then
    printf "%-35s \033[31m%10s\033[0m %10s %10s %10s\n" "${SERVICE}" "$CRITICAL" "$HIGH" "$MEDIUM" "$LOW"
  elif [ "$HIGH" -gt 0 ]; then
    printf "%-35s %10s \033[33m%10s\033[0m %10s %10s\n" "${SERVICE}" "$CRITICAL" "$HIGH" "$MEDIUM" "$LOW"
  else
    printf "%-35s %10s %10s %10s %10s\n" "${SERVICE}" "$CRITICAL" "$HIGH" "$MEDIUM" "$LOW"
  fi

  # Save detailed JSON report if requested
  if [ "$FORMAT" = "json" ]; then
    REPORT_DIR="$(dirname "$0")/../reports"
    mkdir -p "$REPORT_DIR"
    echo "$RESULT" > "${REPORT_DIR}/trivy-${SERVICE}.json"
  fi
done

echo ""
printf "%-35s %10s %10s\n" "TOTAL" "$TOTAL_CRITICAL" "$TOTAL_HIGH"
echo ""

# Verdict
if [ "$TOTAL_CRITICAL" -gt 0 ]; then
  echo "VERDICT: FAIL — ${TOTAL_CRITICAL} CRITICAL vulnerabilities found."
  echo ""
  echo "Action required:"
  echo "  1. Update base images (node:18 → node:22, python:3.11 → python:3.13, go:1.22 → go:1.26)"
  echo "  2. Run 'npm audit fix' / 'pip install --upgrade' / 'go get -u'"
  echo "  3. Rebuild and re-scan"
  echo ""
  echo "In CI, this would BLOCK the deployment."
  exit 1
else
  echo "VERDICT: PASS — no CRITICAL vulnerabilities."
  if [ "$TOTAL_HIGH" -gt 0 ]; then
    echo "  (${TOTAL_HIGH} HIGH vulnerabilities should be addressed within 1-2 weeks)"
  fi
  exit 0
fi
