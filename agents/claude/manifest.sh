#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/manifest.sh — Manifest for the Claude Code CLI agent.
#
# Sourced by agents/registry.sh from both host and container contexts.
# Co-located with claude-specific helpers under agents/claude/:
#   manifest.sh       — this file (the contract functions)
#   setup.sh          — container-side runtime setup
#   sync-settings.sh  — host-side config sync
#
# See docs/maintainer/adding-an-agent.md for the full contract.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve this manifest's own directory so sibling files load by absolute path.
# BASH_SOURCE works regardless of caller cwd or how the registry was sourced.
_AGENT_CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Name of the binary on PATH inside the container.
agent_claude_real_binary() {
    printf 'claude\n'
}

# Argv for non-interactive "run with prompt" mode. Claude Code uses
# -p/--prompt to enter scripted mode.
#
# Argv tokens are emitted NUL-terminated (`printf '%s\0'`) so multi-line
# prompts survive the round-trip through `mapfile -d ''`. NUL is safe —
# argv tokens cannot contain NUL bytes (execve invariant). See
# docs/maintainer/adding-an-agent.md for the full contract.
agent_claude_run_argv() {
    local prompt="${1:?run_argv requires a prompt argument}"
    printf '%s\0' claude -p "${prompt}"
}

# Argv for "continue last session". --continue is a top-level Claude flag.
agent_claude_resume_argv() {
    printf '%s\0' claude --continue
}

# Argv for read-only audit mode. Same shape as run.
agent_claude_audit_argv() {
    local prompt="${1:?audit_argv requires a prompt argument}"
    printf '%s\0' claude -p "${prompt}"
}

# Wrapper injection rules. Claude takes --dangerously-skip-permissions as
# a root-level flag and is non-interactive when -p / --prompt is present.
# See docs/maintainer/adding-an-agent.md for the full contract.
agent_claude_wrapper_inject() {
    local set_ci=0
    local arg
    for arg in "$@"; do
        if [ "${arg}" = "-p" ] || [ "${arg}" = "--prompt" ]; then
            set_ci=1
            break
        fi
    done
    printf '%s\0' --dangerously-skip-permissions
    for arg in "$@"; do
        printf '%s\0' "${arg}"
    done
    if [ "${set_ci}" = "1" ]; then
        echo "CI=1" >&2
    fi
}

# Container-side runtime setup. setup.sh is a no-op in the common case
# (managed policy /etc/claude-code/CLAUDE.md is rendered at build time);
# it only does work when RIOTBOX_PROMPT overrides or the build-time render
# is missing.
agent_claude_container_setup() {
    # shellcheck source=./setup.sh
    source "${_AGENT_CLAUDE_DIR}/setup.sh"
    claude_setup
}

# Host-side config sync. sync-settings.sh handles credentials, config,
# skills, statusline-command.sh, host plugins, etc. Prints volume flags
# on stdout, notices on stderr.
agent_claude_host_sync() {
    local session_dir="${1:?host_sync requires a session_dir argument}"
    "${_AGENT_CLAUDE_DIR}/sync-settings.sh" \
        "${HOME}/.claude" \
        "${session_dir}"
}

# Print the env var names this agent reads (one per line). The launcher
# unions these across all registered agents to build the passthrough set.
# Names only — no values; the container runtime copies values from the
# caller's environment via `-e <name>` (see passthrough-vars.sh).
#
# Claude Code reads:
#   * ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN — direct API auth
#   * ANTHROPIC_BASE_URL — proxy/gateway routing
#   * ANTHROPIC_VERTEX_* / CLAUDE_CODE_USE_VERTEX / VERTEX_LOCATION /
#     CLOUD_ML_REGION — Google Vertex AI provider routing
#   * ANTHROPIC_BEDROCK_BASE_URL / CLAUDE_CODE_USE_BEDROCK / AWS_REGION /
#     AWS_PROFILE — AWS Bedrock provider routing (AWS_PROFILE selects a
#     credential set; access keys are NOT included by design — see
#     THREAT_MODEL.md)
agent_claude_env_vars() {
    cat <<'EOF'
ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
ANTHROPIC_VERTEX_PROJECT_ID
ANTHROPIC_VERTEX_BASE_URL
ANTHROPIC_BEDROCK_BASE_URL
CLAUDE_CODE_USE_VERTEX
CLAUDE_CODE_USE_BEDROCK
VERTEX_LOCATION
CLOUD_ML_REGION
AWS_REGION
AWS_PROFILE
EOF
}
