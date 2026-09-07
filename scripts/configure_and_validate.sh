#!/bin/bash
# Prompt for credentials and run read-only vCenter validation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Windows Patch — Credential Setup ==="
echo "Enter vCenter and Windows guest credentials for BLR/FW/STC."
echo ""

read -r -p "vCenter username (e.g. user@strykercorp.com): " VCENTER_USERNAME
read -r -s -p "vCenter password: " VCENTER_PASSWORD
echo ""
read -r -p "Windows guest username (e.g. CORP\\svc-patch or Administrator): " WINDOWS_GUEST_USERNAME
read -r -s -p "Windows guest password: " WINDOWS_GUEST_PASSWORD
echo ""
echo ""

export VCENTER_USERNAME VCENTER_PASSWORD WINDOWS_GUEST_USERNAME WINDOWS_GUEST_PASSWORD

echo "=== Running validation ==="
pwsh -NoProfile -Command "\$r = Invoke-Pester -Path ./tests -CI -PassThru; if (\$r.FailedCount -gt 0) { exit 1 }"

echo ""
echo "=== Resolving VM names from your spreadsheet IPs ==="
pwsh -NoProfile -File ./scripts/Resolve-VMInventory.ps1

echo ""
echo "=== Validating all three vCenters + inventory ==="
pwsh -NoProfile -File ./scripts/Validate-PatchEnvironment.ps1 -ResolveAllInventory

echo ""
echo "SUCCESS: validation complete."
echo "Review: output/validation/"
echo ""
echo "To enable patching for a VM, set Enabled=true in config/vms.csv, then run:"
echo "  pwsh -File ./scripts/Validate-PatchEnvironment.ps1 -ExecutePatch"
