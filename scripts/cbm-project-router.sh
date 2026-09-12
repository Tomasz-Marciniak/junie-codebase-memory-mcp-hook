#!/usr/bin/env bash
# cbm-project-router.sh — Junie UserPromptSubmit hook for Codebase Memory project detection
# Fail-open router: detects mentions of indexed CBM projects and injects verification context.
# Never exits non-zero; never emits unformatted stdout.

# Fail-open: jq is required to parse JSON input and format JSON output.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Locate and source cbm-common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "$SCRIPT_DIR/cbm-common.sh" ]; then
    # shellcheck source=scripts/cbm-common.sh
    source "$SCRIPT_DIR/cbm-common.sh"
elif [ -f "$HOME/.junie/hooks/cbm-common.sh" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.junie/hooks/cbm-common.sh"
else
    exit 0
fi

# Declare associative map for project lookup
declare -A CBM_PROJECT_MAP

main() {
    # Read entire payload from stdin
    local input
    input=$(cat 2>/dev/null)
    if [ -z "$input" ]; then
        exit 0
    fi

    # Extract user prompt
    local prompt
    prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)
    if [ -z "$prompt" ]; then
        exit 0
    fi

    # Ensure project cache is ready (using stale cache as fallback if needed)
    if ! cbm_ensure_cache; then
        exit 0
    fi

    # Load project map into memory
    if ! cbm_load_project_map; then
        exit 0
    fi

    # Match tokens from prompt against known projects
    local matched
    matched=$(cbm_match_prompt "$prompt")
    if [ -z "$matched" ]; then
        exit 0
    fi

    # Build and emit single-line JSON with additionalContext
    cbm_build_additional_context_json "$matched"
    exit 0
}

# Trap any unexpected errors and exit 0 cleanly
trap 'exit 0' ERR
main || exit 0
