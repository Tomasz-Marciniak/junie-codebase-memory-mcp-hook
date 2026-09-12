#!/usr/bin/env bash
# install.sh — Installer for Junie Codebase Memory (CBM) project mention detector hook
# Supports direct execution (./install.sh) and curl piping (curl -fsSL ... | bash)

set -euo pipefail

GITHUB_RAW_URL="https://raw.githubusercontent.com/upfera/junie-codebase-memory-mcp-hooks/main"
JUNIE_DIR="${HOME}/.junie"
HOOKS_DIR="${JUNIE_DIR}/hooks"
CONFIG_FILE="${JUNIE_DIR}/config.json"
HOOK_CMD="~/.junie/hooks/cbm-project-router.sh"

echo "=== Installing Junie CBM Project Mention Detector Hook ==="

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required but not installed. Please install jq first." >&2
    exit 1
fi

if ! command -v codebase-memory-mcp >/dev/null 2>&1; then
    echo "WARNING: 'codebase-memory-mcp' was not found in PATH." >&2
    echo "         The hook will fail-open (silent no-op) until codebase-memory-mcp is available." >&2
fi

# Ensure target directories exist
mkdir -p "${HOOKS_DIR}"

# Determine source location: local repository or remote download
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/scripts/cbm-common.sh" ] && [ -f "$SCRIPT_DIR/scripts/cbm-project-router.sh" ]; then
    echo "Installing from local repository files..."
    cp -f "$SCRIPT_DIR/scripts/cbm-common.sh" "${HOOKS_DIR}/cbm-common.sh"
    cp -f "$SCRIPT_DIR/scripts/cbm-project-router.sh" "${HOOKS_DIR}/cbm-project-router.sh"
else
    echo "Downloading hook scripts from GitHub (${GITHUB_RAW_URL})..."
    curl -fsSL "${GITHUB_RAW_URL}/scripts/cbm-common.sh" -o "${HOOKS_DIR}/cbm-common.sh"
    curl -fsSL "${GITHUB_RAW_URL}/scripts/cbm-project-router.sh" -o "${HOOKS_DIR}/cbm-project-router.sh"
fi

chmod +x "${HOOKS_DIR}/cbm-common.sh" "${HOOKS_DIR}/cbm-project-router.sh"
echo "Hook scripts installed and marked executable at ${HOOKS_DIR}/"

# Update ~/.junie/config.json
echo "Configuring ${CONFIG_FILE}..."
BACKUP_FILE=""
if [ -f "${CONFIG_FILE}" ]; then
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%s)"
    cp "${CONFIG_FILE}" "${BACKUP_FILE}"
    echo "Created backup at ${BACKUP_FILE}"
    CONFIG_JSON=$(cat "${CONFIG_FILE}")
else
    CONFIG_JSON='{}'
fi

# Merge hook entry idempotently into hooks.UserPromptSubmit
NEW_ENTRY='{"hooks":[{"type":"command","command":"'"$HOOK_CMD"'","timeout":5}]}'

MERGED_JSON=$(printf '%s' "${CONFIG_JSON}" | jq \
  --arg cmd "${HOOK_CMD}" \
  --argjson entry "${NEW_ENTRY}" '
  .hooks = (.hooks // {}) |
  .hooks.UserPromptSubmit = (
    (.hooks.UserPromptSubmit // []) |
    if any(.[].hooks[]?; .command == $cmd) then
      .
    else
      . + [$entry]
    end
  )
')

# Validate resulting JSON
TMP_CONFIG="${CONFIG_FILE}.tmp.$$"
printf '%s\n' "${MERGED_JSON}" | jq . > "${TMP_CONFIG}" 2>/dev/null || {
    echo "ERROR: Failed to validate merged configuration JSON." >&2
    rm -f "${TMP_CONFIG}"
    if [ -n "${BACKUP_FILE}" ] && [ -f "${BACKUP_FILE}" ]; then
        cp "${BACKUP_FILE}" "${CONFIG_FILE}"
    fi
    exit 1
}

mv -f "${TMP_CONFIG}" "${CONFIG_FILE}"
echo "Successfully updated ${CONFIG_FILE}"

# Pre-warm project cache if codebase-memory-mcp is available
if command -v codebase-memory-mcp >/dev/null 2>&1; then
    echo "Pre-warming Codebase Memory projects cache..."
    export JUNIE_CBM_CACHE_DIR="${HOME}/.cache/junie-cbm"
    export JUNIE_CBM_CACHE_FILE="${JUNIE_CBM_CACHE_DIR}/projects.json"
    source "${HOOKS_DIR}/cbm-common.sh"
    if cbm_ensure_cache; then
        PROJECT_COUNT=$(jq -r '.total // (.projects | length)' "${JUNIE_CBM_CACHE_FILE}" 2>/dev/null || echo "unknown")
        echo "Cache pre-warmed successfully (${PROJECT_COUNT} projects indexed)."
    else
        echo "Cache pre-warm skipped (will warm automatically on first prompt)."
    fi
fi

echo "=== Installation complete! ==="
echo "The hook is active for all Junie sessions."
