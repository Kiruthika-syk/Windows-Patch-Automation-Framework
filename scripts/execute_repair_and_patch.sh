#!/bin/bash
# Repair Windows Update Agent and optionally patch enabled inventory VMs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CRED_FILE="${HOME}/.windows_patch_creds"
INVENTORY="${1:-./output/blr-122105-only.csv}"

if [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
fi

if [[ -z "${VCENTER_USERNAME:-}" || -z "${VCENTER_PASSWORD:-}" || -z "${WINDOWS_GUEST_USERNAME:-}" || -z "${WINDOWS_GUEST_PASSWORD:-}" ]]; then
  echo "ERROR: Credentials not found in ${CRED_FILE}"
  exit 1
fi

echo "=== Repair + patch inventory: ${INVENTORY} ==="
pwsh -NoProfile -File ./scripts/Validate-PatchEnvironment.ps1 -InventoryPath "$INVENTORY" -ExecutePatch
