#!/bin/bash
# Push Windows Patch Automation Framework to Kiruthika-syk GitHub account
set -euo pipefail

TOKEN_FILE="${HOME}/.github_token"
REPO_NAME="Windows-Patch-Automation-Framework"
USER="Kiruthika-syk"
REPO_URL="https://github.com/${USER}/${REPO_NAME}.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${TOKEN_FILE}" ]]; then
  echo "ERROR: ${TOKEN_FILE} not found."
  exit 1
fi

TOKEN="$(tr -d '[:space:]' < "${TOKEN_FILE}")"

cd "${SCRIPT_DIR}"

if [[ ! -d .git ]]; then
  git init -b main
fi

git add -A
git status --short

if git diff --cached --quiet; then
  echo "Nothing to commit."
else
  git commit -m "$(cat <<'EOF'
Add Windows Patch Automation Framework with auto-update and reboot support.

Automates Windows Update scanning, installation, and reboot-when-required
through VMware Guest Operations and GitHub Actions.
EOF
)"
fi

HTTP_CODE="$(curl -s -o /tmp/create_repo.json -w "%{http_code}" \
  -X POST \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/user/repos" \
  -d "{\"name\":\"${REPO_NAME}\",\"description\":\"Production Windows patch automation with auto-update and reboot-when-required via VMware Guest Operations\",\"private\":false,\"auto_init\":false}")"

if [[ "${HTTP_CODE}" != "201" && "${HTTP_CODE}" != "422" ]]; then
  echo "ERROR: Failed to create repository (HTTP ${HTTP_CODE})."
  cat /tmp/create_repo.json
  exit 1
fi

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

git remote remove origin 2>/dev/null || true
git remote add origin "${REPO_URL}"
git push "https://${USER}:${TOKEN}@github.com/${USER}/${REPO_NAME}.git" main
git remote set-url origin "${REPO_URL}"
git branch --set-upstream-to=origin/main main 2>/dev/null || true

echo ""
echo "SUCCESS: https://github.com/${USER}/${REPO_NAME}"
