#!/bin/bash
# Regenerate docs/fleet-status.json for the internal website.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== Updating website fleet status ==="
pwsh -NoProfile -File ./scripts/Update-DocsSite.ps1
echo "Website data refreshed: docs/fleet-status.json"
echo "Open http://10.90.105.221:8080/ and hard-refresh (Ctrl+F5) to see changes."
