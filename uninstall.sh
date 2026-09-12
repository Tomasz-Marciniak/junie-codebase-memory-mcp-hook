#!/usr/bin/env bash
# uninstall.sh — Uninstaller for Junie Codebase Memory (CBM) project mention detector hook

set -euo pipefail

JUNIE_DIR="${HOME}/.junie"
HOOKS_DIR="${JUNIE_DIR}/hooks"
CONFIG_FILE="${JUNIE_DIR}/config.json"
CACHE_DIR="${HOME}/.cache/junie-cbm"
HOOK_CMD="~/.junie/hooks/cbm-project-router.sh"

echo "=== Uninstalling Junie CBM Project Mention Detector Hook ==="

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required to update config.json." >&2
    exit 1
fi

# Remove hook entry from ~/.junie/config.json
if [ -f "${CONFIG_FILE}" ]; then
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%s)"
    cp "${CONFIG_FILE}" "${BACKUP_FILE}"
    echo "Created backup at ${BACKUP_FILE}"

    CONFIG_JSON=$(cat "${CONFIG_FILE}")
    REMOVED_JSON=$(printf '%s' "${CONFIG_JSON}" | jq \
      --arg cmd "${HOOK_CMD}" '
      if .hooks?.UserPromptSubmit then
        .hooks.UserPromptSubmit = [ .hooks.UserPromptSubmit[] | select([ .hooks[]? | select(.command == $cmd) ] | length == 0) ] |
        if (.hooks.UserPromptSubmit | length == 0) then del(.hooks.UserPromptSubmit) else . end |
        if (.hooks | length == 0) then del(.hooks) else . end
      else
        .
      end
    ')

    TMP_CONFIG="${CONFIG_FILE}.tmp.$$"
    printf '%s\n' "${REMOVED_JSON}" | jq . > "${TMP_CONFIG}" 2>/dev/null || {
        echo "ERROR: Failed to validate configuration JSON during uninstallation." >&2
        rm -f "${TMP_CONFIG}"
        exit 1
    }
    mv -f "${TMP_CONFIG}" "${CONFIG_FILE}"
    echo "Removed hook entry from ${CONFIG_FILE}"
fi

# Remove installed script files
rm -f "${HOOKS_DIR}/cbm-common.sh" "${HOOKS_DIR}/cbm-project-router.sh"
echo "Removed hook scripts from ${HOOKS_DIR}/"

# Clean cache directory if requested or prompt
if [ -d "${CACHE_DIR}" ]; then
    rm -rf "${CACHE_DIR}"
    echo "Removed cache directory ${CACHE_DIR}"
fi

echo "=== Uninstallation complete! ==="
