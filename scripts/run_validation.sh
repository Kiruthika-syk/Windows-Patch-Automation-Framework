#!/bin/bash
# Validate Windows patch configuration against BLR/FW/STC vCenters.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

load_vault_creds() {
  local creds
  creds="$(python3 "$ROOT/../ansible/ssh_remediation/get_vault_creds.py" 2>/dev/null || true)"
  if [[ -n "$creds" ]]; then
    export VCENTER_USERNAME="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('vcenter_username',''))" <<< "$creds")"
    export VCENTER_PASSWORD="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('vcenter_password',''))" <<< "$creds")"
    export WINDOWS_GUEST_USERNAME="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('guest_username',''))" <<< "$creds")"
    export WINDOWS_GUEST_PASSWORD="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('guest_password',''))" <<< "$creds")"
  fi
}

if [[ -z "${VCENTER_USERNAME:-}" || -z "${VCENTER_PASSWORD:-}" ]]; then
  load_vault_creds
fi

if [[ -z "${VCENTER_USERNAME:-}" || -z "${VCENTER_PASSWORD:-}" ]]; then
  echo "ERROR: Set VCENTER_USERNAME and VCENTER_PASSWORD, or configure ansible/ssh_remediation/vault.yml"
  echo "  export VCENTER_USERNAME='user@strykercorp.com'"
  echo "  export VCENTER_PASSWORD='...'"
  exit 1
fi

echo "=== Step 1: Pester tests ==="
pwsh -NoProfile -Command "\$r = Invoke-Pester -Path ./tests -CI -PassThru; if (\$r.FailedCount -gt 0) { exit 1 }"

echo ""
echo "=== Step 2: Resolve VM names from vCenter (optional inventory check) ==="
pwsh -NoProfile -File ./scripts/Resolve-VMInventory.ps1 || true

echo ""
echo "=== Step 3: Validate all three vCenters and inventory ==="
pwsh -NoProfile -File ./scripts/Validate-PatchEnvironment.ps1 -ResolveAllInventory

echo ""
echo "Done. To patch, enable VMs in config/vms.csv then run:"
echo "  pwsh -File ./scripts/Validate-PatchEnvironment.ps1 -ExecutePatch"
