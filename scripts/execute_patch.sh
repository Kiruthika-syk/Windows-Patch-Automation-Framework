#!/bin/bash
# Execute patch run for all enabled VMs in config/vms.csv
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CRED_FILE="${HOME}/.windows_patch_creds"

load_creds() {
  if [[ -f "$CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
    return 0
  fi
  local creds
  creds="$(python3 "$ROOT/../ansible/ssh_remediation/get_vault_creds.py" 2>/dev/null || true)"
  if [[ -n "$creds" ]]; then
    export VCENTER_USERNAME="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('vcenter_username',''))" <<< "$creds")"
    export VCENTER_PASSWORD="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('vcenter_password',''))" <<< "$creds")"
    export WINDOWS_GUEST_USERNAME="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('guest_username',''))" <<< "$creds")"
    export WINDOWS_GUEST_PASSWORD="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('guest_password',''))" <<< "$creds")"
  fi
}

load_creds

if [[ -z "${VCENTER_USERNAME:-}" || -z "${VCENTER_PASSWORD:-}" || -z "${WINDOWS_GUEST_USERNAME:-}" || -z "${WINDOWS_GUEST_PASSWORD:-}" ]]; then
  echo "ERROR: Credentials not found."
  echo ""
  echo "Create ${CRED_FILE} with TWO separate credential sets:"
  echo ""
  echo '  # vCenter SSO login (NOT the Windows Administrator account)'
  echo '  export VCENTER_USERNAME="your.name@strykercorp.com"'
  echo '  export VCENTER_PASSWORD="your-vcenter-password"'
  echo ''
  echo '  # Windows local admin inside each VM (what you use for RDP)'
  echo '  export WINDOWS_GUEST_USERNAME="Administrator"'
  echo '  export WINDOWS_GUEST_PASSWORD="your-windows-password"'
  echo ""
  echo "Then run: chmod 600 ${CRED_FILE} && ./scripts/execute_patch.sh"
  exit 1
fi

echo "=== Credential check ==="
echo "vCenter user: ${VCENTER_USERNAME}"
echo "Windows guest user: ${WINDOWS_GUEST_USERNAME}"
echo "(These must be different accounts unless you intentionally use the same)"

echo "=== Enabled VMs ==="
awk -F, 'NR==1 || $2 ~ /^(true|yes|1)$/i {print}' config/vms.csv

echo ""
echo "=== Starting patch run (all enabled VMs in parallel) ==="
pwsh -NoProfile -File ./scripts/Validate-PatchEnvironment.ps1 -ExecutePatch

echo ""
echo "=== Patch run finished. Reports in output/ ==="
ls -la output/ 2>/dev/null | tail -5
