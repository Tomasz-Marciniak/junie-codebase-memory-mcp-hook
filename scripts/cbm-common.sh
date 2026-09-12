#!/usr/bin/env bash
# cbm-common.sh — shared functions for Junie CBM project mention detector
# Sourced by hook scripts, not intended to be executed directly.

# Configuration defaults (overridable via environment variables)
export JUNIE_CBM_CACHE_DIR="${JUNIE_CBM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/junie-cbm}"
export JUNIE_CBM_CACHE_FILE="${JUNIE_CBM_CACHE_FILE:-$JUNIE_CBM_CACHE_DIR/projects.json}"
export JUNIE_CBM_CACHE_TTL_SEC="${JUNIE_CBM_CACHE_TTL_SEC:-600}"
export JUNIE_CBM_CLI_TIMEOUT_SEC="${JUNIE_CBM_CLI_TIMEOUT_SEC:-2}"
export JUNIE_CBM_HOOK_DEBUG="${JUNIE_CBM_HOOK_DEBUG:-0}"
export CBM_BIN="${CBM_BIN:-codebase-memory-mcp}"

cbm_debug() {
    if [ "${JUNIE_CBM_HOOK_DEBUG:-0}" = "1" ]; then
        local msg="$1"
        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
        >&2 printf '[cbm-hook %s] %s\n' "$ts" "$msg"
        if mkdir -p "$JUNIE_CBM_CACHE_DIR" 2>/dev/null; then
            printf '[%s] %s\n' "$ts" "$msg" >> "$JUNIE_CBM_CACHE_DIR/hook-debug.log" 2>/dev/null || true
        fi
    fi
}

cbm_normalize() {
    # Lowercase and treat _ and - as equivalent (map _ to -)
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

cbm_get_file_mtime() {
    local file="$1"
    # Linux stat: stat -c %Y; BSD/macOS stat: stat -f %m
    stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0
}

cbm_is_cache_fresh() {
    local cache_file="${JUNIE_CBM_CACHE_FILE}"
    [ -f "$cache_file" ] && [ -s "$cache_file" ] || return 1

    local mtime now age ttl
    mtime=$(cbm_get_file_mtime "$cache_file")
    now=$(date +%s 2>/dev/null || echo 0)
    ttl="${JUNIE_CBM_CACHE_TTL_SEC:-600}"

    if [ "$mtime" -le 0 ] || [ "$now" -le 0 ]; then
        return 1
    fi

    age=$(( now - mtime ))
    if [ "$age" -lt "$ttl" ] && [ "$age" -ge 0 ]; then
        cbm_debug "Cache is fresh (age: ${age}s, ttl: ${ttl}s)"
        return 0
    else
        cbm_debug "Cache is stale (age: ${age}s, ttl: ${ttl}s)"
        return 1
    fi
}

cbm_fetch_projects() {
    local cache_dir="${JUNIE_CBM_CACHE_DIR}"
    local cache_file="${JUNIE_CBM_CACHE_FILE}"
    local tmp_file="${cache_file}.tmp.$$"
    local bin="${CBM_BIN:-codebase-memory-mcp}"

    if ! command -v "$bin" >/dev/null 2>&1; then
        cbm_debug "Binary '$bin' not found in PATH"
        return 1
    fi

    if ! mkdir -p "$cache_dir" 2>/dev/null; then
        cbm_debug "Failed to create cache dir: $cache_dir"
        return 1
    fi

    local offset=0
    local limit=100
    local all_projects=()
    local cli_timeout="${JUNIE_CBM_CLI_TIMEOUT_SEC:-2}"
    local max_total_time="${JUNIE_CBM_CLI_MAX_TIME_SEC:-3}"
    local start_time
    start_time=$(date +%s 2>/dev/null || echo 0)
    local timeout_cmd=""

    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd="timeout $cli_timeout"
    fi

    cbm_debug "Fetching project list from $bin cli list_projects"

    while true; do
        local raw_out
        raw_out=$($timeout_cmd "$bin" cli list_projects --offset "$offset" --limit "$limit" </dev/null 2>/dev/null)
        local status=$?

        if [ $status -ne 0 ]; then
            cbm_debug "Command exited with status $status (offset: $offset)"
            if [ ${#all_projects[@]} -eq 0 ]; then
                return 1
            fi
            break
        fi

        local names
        names=$(printf '%s' "$raw_out" | jq -r '.projects[]? | if type == "object" then .name else . end' 2>/dev/null)
        if [ -z "$names" ]; then
            cbm_debug "No projects extracted from CLI output at offset $offset"
            break
        fi

        while IFS= read -r name; do
            [ -n "$name" ] && all_projects+=("$name")
        done <<< "$names"

        local has_more
        has_more=$(printf '%s' "$raw_out" | jq -r '.has_more // false' 2>/dev/null)
        if [ "$has_more" != "true" ]; then
            break
        fi

        # Check total time spent
        local cur_time
        cur_time=$(date +%s 2>/dev/null || echo 0)
        if [ "$start_time" -gt 0 ] && [ "$cur_time" -gt 0 ]; then
            if [ $(( cur_time - start_time )) -ge "$max_total_time" ]; then
                cbm_debug "Reached max total fetch time budget (${max_total_time}s)"
                break
            fi
        fi

        offset=$(( offset + limit ))
    done

    local count="${#all_projects[@]}"
    if [ "$count" -eq 0 ]; then
        cbm_debug "No projects found"
        return 1
    fi

    local now
    now=$(date +%s 2>/dev/null || echo 0)

    # Atomically write new cache file
    if printf '%s\n' "${all_projects[@]}" | \
       jq -R . | \
       jq -s --argjson total "$count" --argjson cached_at "$now" \
          '{total: $total, cached_at: $cached_at, projects: [ .[] | {name: .} ]}' \
          > "$tmp_file" 2>/dev/null; then
        if mv -f "$tmp_file" "$cache_file" 2>/dev/null; then
            cbm_debug "Successfully updated cache with $count projects at $cache_file"
            return 0
        else
            cbm_debug "Failed to move $tmp_file to $cache_file"
            rm -f "$tmp_file" 2>/dev/null || true
            return 1
        fi
    else
        cbm_debug "Failed to format projects JSON to $tmp_file"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
}

cbm_ensure_cache() {
    if cbm_is_cache_fresh; then
        return 0
    fi

    # Attempt to refresh cache
    if cbm_fetch_projects; then
        return 0
    fi

    # Stale cache fallback: if previous cache exists and is non-empty, use it
    if [ -f "$JUNIE_CBM_CACHE_FILE" ] && [ -s "$JUNIE_CBM_CACHE_FILE" ]; then
        cbm_debug "Using stale cache as fallback: $JUNIE_CBM_CACHE_FILE"
        return 0
    fi

    cbm_debug "Cache refresh failed and no stale cache available"
    return 1
}

# Populates associative array CBM_PROJECT_MAP (normalized_name -> canonical_name)
cbm_load_project_map() {
    local cache_file="$JUNIE_CBM_CACHE_FILE"
    if [ ! -f "$cache_file" ] || [ ! -s "$cache_file" ]; then
        return 1
    fi

    local names
    names=$(jq -r '.projects[]? | if type == "object" then .name else . end' "$cache_file" 2>/dev/null)
    if [ -z "$names" ]; then
        return 1
    fi

    while IFS= read -r orig; do
        [ -z "$orig" ] && continue
        local norm
        norm=$(cbm_normalize "$orig")
        [ -n "$norm" ] && CBM_PROJECT_MAP["$norm"]="$orig"
    done <<< "$names"

    return 0
}

# Matches prompt tokens against CBM_PROJECT_MAP
# Outputs comma-space separated string of matched canonical project names
cbm_match_prompt() {
    local prompt="$1"
    [ -z "$prompt" ] && return 0

    local matched=()
    declare -A seen

    # Real CBM project names use [A-Za-z0-9_-].
    # Tokenize prompt into maximal runs of [A-Za-z0-9_-]+.
    # Punctuation (?, ,, ., `, (), etc.) adjacent to names is naturally stripped.
    while IFS= read -r token; do
        [ -z "$token" ] && continue
        local norm
        norm=$(cbm_normalize "$token")
        if [[ -v "CBM_PROJECT_MAP[$norm]" ]]; then
            local orig="${CBM_PROJECT_MAP["$norm"]}"
            if [[ ! -v "seen[$orig]" ]]; then
                seen["$orig"]=1
                matched+=("$orig")
            fi
        fi
    done < <(printf '%s\n' "$prompt" | grep -o -E '[A-Za-z0-9_-]+')

    if [ ${#matched[@]} -gt 0 ]; then
        local joined
        joined=$(printf ', %s' "${matched[@]}")
        printf '%s' "${joined:2}"
    fi
}

cbm_build_additional_context_json() {
    local matched_str="$1"
    [ -z "$matched_str" ] && return 0

    local context_msg="Relevant Codebase Memory (CBM) projects mentioned in this prompt: ${matched_str}. Do NOT assume any relationship between them from name matching alone — use the Codebase Memory MCP tool to verify actual code-level relationships (e.g. search_graph, trace_path, query_graph) before answering."

    jq -n --arg ctx "$context_msg" '{"additionalContext": $ctx}' -c 2>/dev/null
}
