#!/bin/bash
# Delete completed patch run output older than PATCH_OUTPUT_RETENTION_HOURS (default 24).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RETENTION_HOURS="${PATCH_OUTPUT_RETENTION_HOURS:-24}"
DRY_RUN="${1:-}"

cd "$ROOT"
mkdir -p "$ROOT/output"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  pwsh -NoProfile -File ./scripts/Cleanup-PatchRunOutput.ps1 \
    -RetentionHours "$RETENTION_HOURS" -WhatIf
else
  pwsh -NoProfile -File ./scripts/Cleanup-PatchRunOutput.ps1 \
    -RetentionHours "$RETENTION_HOURS"
fi
