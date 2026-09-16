#!/bin/bash
# Re-patch VMs that previously failed or hit MaxCyclesExceeded (after orchestrator fixes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CRED_FILE="${HOME}/.windows_patch_creds"

if [[ ! -f "$CRED_FILE" ]]; then
  echo "ERROR: Missing $CRED_FILE"
  exit 1
fi

VM_CSVS=(
  "./output/blr-damo-test02-only.csv"
  "./output/blr-122105-only.csv"
)

unset VCENTER_USERNAME VCENTER_PASSWORD WINDOWS_GUEST_USERNAME WINDOWS_GUEST_PASSWORD || true
# shellcheck disable=SC1090
source "$CRED_FILE"

for csv in "${VM_CSVS[@]}"; do
  if [[ ! -f "$csv" ]]; then
    echo "SKIP: $csv not found"
    continue
  fi
  echo ""
  echo "=========================================="
  echo "Re-patching inventory: $csv"
  echo "=========================================="
  ./scripts/run_patch_with_creds.sh "$csv" "$CRED_FILE"
done

echo ""
echo "All re-patch jobs finished. Refresh http://10.90.105.221:8080/"
