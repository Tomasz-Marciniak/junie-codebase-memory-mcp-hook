# Junie Codebase Memory MCP Hook

> [!WARNING]
> **Deprecated: use the [`codebase-memory` marketplace extension](https://github.com/upfera/junie-extensions/tree/main/extensions/codebase-memory) instead.** Do not install this standalone hook alongside the marketplace extension; both can register `UserPromptSubmit` and inject duplicate context. This standalone installer is retained only to help existing users clean up.
>
> Before installing the marketplace extension, run `./uninstall.sh` from a clone. If cleanup is incomplete, remove only `~/.junie/hooks/cbm-common.sh` and `~/.junie/hooks/cbm-project-router.sh`, plus the `UserPromptSubmit` hook entry invoking `~/.junie/hooks/cbm-project-router.sh` in `~/.junie/config.json`. Preserve unrelated hooks and settings.

A fast, local, fail-open `UserPromptSubmit` hook for Junie CLI that detects when a user prompt mentions projects indexed by `codebase-memory-mcp` (CBM) and injects verification context.

## Overview

This hook acts as a **router, not an oracle**:
- **Detects mentions**: Identifies when a prompt references one or more projects indexed in Codebase Memory.
- **Instructs the agent**: Injects a concise `additionalContext` note reminding the agent to use Codebase Memory MCP tools (e.g. `search_graph`, `trace_path`, `query_graph`) to verify relationships rather than inferring them from name co-occurrence.
- **Fail-open, always**: Any error, missing binary, malformed JSON, or timeout results in a silent exit (code 0) without blocking prompt submission.
- **Fast**: Sub-millisecond to ~160ms token matching on warm cache; zero network calls.
- **Zero MCP calls**: Only queries the local `codebase-memory-mcp` CLI for project names during cache refresh.

## Quick Installation

Run the one-line installer via curl:

```bash
curl -fsSL https://raw.githubusercontent.com/upfera/junie-codebase-memory-mcp-hook/main/install.sh | bash
```

## Local Installation

```bash
git clone https://github.com/upfera/junie-codebase-memory-mcp-hook.git
cd junie-codebase-memory-mcp-hook
./install.sh
```

The installer:
1. Installs `cbm-common.sh` and `cbm-project-router.sh` to `~/.junie/hooks/`.
2. Backs up `~/.junie/config.json`.
3. Idempotently merges the hook entry into `hooks.UserPromptSubmit` while preserving all existing hooks and settings.
4. Pre-warms the local project cache if `codebase-memory-mcp` is installed.

## Uninstallation

To cleanly remove the hook and restore your configuration:

```bash
./uninstall.sh
```

## How It Works

1. **Prompt Ingestion**: Junie invokes `cbm-project-router.sh` with the JSON payload on stdin (`{"prompt": "...", ...}`).
2. **Caching**: Reads indexed project names from `~/.cache/junie-cbm/projects.json` (TTL: 600s). Rebuilds the cache atomically via `codebase-memory-mcp cli list_projects` when stale. If refreshing fails, falls back to stale cache or exits cleanly.
3. **Token Matching**:
   - Normalizes project names and prompt tokens (lowercase, mapping `_` to `-`).
   - Tokenizes prompt into maximal identifier runs `[A-Za-z0-9_-]+` (ignoring surrounding punctuation like `?`, `,`, `.`, backticks, and parentheses).
   - Exact-matches tokens against indexed project names to eliminate substring false positives (e.g. `super-user-service-v2` will never falsely match `user-service`).
4. **Context Injection**: If one or more projects match, outputs:
   ```json
   {
     "additionalContext": "Relevant Codebase Memory (CBM) projects mentioned in this prompt: <projects>. Do NOT assume any relationship between them from name matching alone — use the Codebase Memory MCP tool to verify actual code-level relationships (e.g. search_graph, trace_path, query_graph) before answering."
   }
   ```
   If no projects match, outputs nothing and exits 0.

## Configuration & Environment Variables

| Variable | Default | Description |
|---|---|---|
| `JUNIE_CBM_CACHE_DIR` | `~/.cache/junie-cbm` | Directory where project cache and logs are stored |
| `JUNIE_CBM_CACHE_FILE` | `~/.cache/junie-cbm/projects.json` | Path to cached project list |
| `JUNIE_CBM_CACHE_TTL_SEC` | `600` | Cache time-to-live in seconds |
| `JUNIE_CBM_CLI_TIMEOUT_SEC` | `2` | Per-call timeout budget for `codebase-memory-mcp` CLI |
| `JUNIE_CBM_HOOK_DEBUG` | `0` | Set to `1` to enable debug logging to stderr and `hook-debug.log` |

## Testing

Run the automated test suite covering all 9 required verification scenarios:

```bash
./tests/test-router.sh
```

## Requirements

- `bash` (v4+)
- `jq` (required for JSON handling; hook fails open if missing)
- `codebase-memory-mcp` (CLI installed and in PATH)
