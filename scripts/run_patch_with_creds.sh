#!/bin/bash
# Run patch for one inventory CSV using credentials from a file.
# Usage: ./scripts/run_patch_with_creds.sh ./output/vm-only.csv [cred-file]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="${1:?Inventory CSV path required}"
CRED_FILE="${2:-${HOME}/.windows_patch_creds}"

if [[ ! -f "$CRED_FILE" ]]; then
  echo "ERROR: Credential file not found: $CRED_FILE"
  exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: Inventory file not found: $INVENTORY"
  exit 1
fi

unset VCENTER_USERNAME VCENTER_PASSWORD WINDOWS_GUEST_USERNAME WINDOWS_GUEST_PASSWORD || true
# shellcheck disable=SC1090
source "$CRED_FILE"

cd "$ROOT"

# Publish inventory to the internal website before and after the patch run.
pwsh -NoProfile -File ./scripts/Update-DocsSite.ps1 >/dev/null || true

./scripts/execute_repair_and_patch.sh "$INVENTORY"

pwsh -NoProfile -File ./scripts/Update-DocsSite.ps1 >/dev/null || true
echo "Website fleet status updated: docs/fleet-status.json (refresh http://10.90.105.221:8080/)"
