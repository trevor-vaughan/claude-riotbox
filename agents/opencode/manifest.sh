#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/manifest.sh — Manifest for the opencode CLI agent.
#
# Sourced by agents/registry.sh from both host and container contexts.
# Co-located with opencode-specific helpers under agents/opencode/:
#   manifest.sh       — this file (the contract functions)
#   setup.sh          — container-side runtime setup
#   sync-settings.sh  — host-side config sync
#
# See docs/maintainer/adding-an-agent.md for the full contract.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve this manifest's own directory so sibling files load by absolute path.
_AGENT_OPENCODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Name of the binary on PATH inside the container.
agent_opencode_real_binary() {
    printf 'opencode\n'
}

# Argv for non-interactive "run with prompt" mode. opencode uses a cobra-style
# subcommand layout: `opencode run <prompt>`. The wrapper injects
# --dangerously-skip-permissions after `run` (see agent_opencode_wrapper_inject).
#
# Argv tokens are emitted NUL-terminated (`printf '%s\0'`) so multi-line
# prompts survive the round-trip through `mapfile -d ''`. NUL is safe —
# argv tokens cannot contain NUL bytes (execve invariant). See
# docs/maintainer/adding-an-agent.md for the full contract.
agent_opencode_run_argv() {
    local prompt="${1:?run_argv requires a prompt argument}"
    printf '%s\0' opencode run "${prompt}"
}

# Argv for "continue last session". opencode's continuation is also a
# `run` subcommand flag.
agent_opencode_resume_argv() {
    printf '%s\0' opencode run --continue
}

# Argv for read-only audit mode. Same shape as run — the read-only project
# mount is a launch-time concern, not an agent flag.
agent_opencode_audit_argv() {
    local prompt="${1:?audit_argv requires a prompt argument}"
    printf '%s\0' opencode run "${prompt}"
}

# Wrapper injection rules. opencode rejects --dangerously-skip-permissions at
# the root level — it must follow the `run` subcommand. When `run` is absent
# (e.g. `opencode auth login`, `opencode --version`) we leave argv untouched.
agent_opencode_wrapper_inject() {
    local saw_run=0
    local arg
    for arg in "$@"; do
        if [ "${saw_run}" -eq 0 ] && [ "${arg}" = "run" ]; then
            saw_run=1
            printf '%s\0' "${arg}"
            printf '%s\0' --dangerously-skip-permissions
            continue
        fi
        printf '%s\0' "${arg}"
    done
    if [ "${saw_run}" -eq 1 ]; then
        echo "CI=1" >&2
    fi
}

# Container-side runtime setup. setup.sh places AGENTS.md and a baseline
# opencode.json on every container start; both are idempotent.
agent_opencode_container_setup() {
    # shellcheck source=./setup.sh
    source "${_AGENT_OPENCODE_DIR}/setup.sh"
    opencode_setup
}

# Host-side config sync. sync-settings.sh copies the host opencode config
# tree into the session dir and emits volume flags (including the auth.json
# RW bind when present).
agent_opencode_host_sync() {
    local session_dir="${1:?host_sync requires a session_dir argument}"
    "${_AGENT_OPENCODE_DIR}/sync-settings.sh" \
        "${HOME}/.config/opencode" \
        "${HOME}/.local/share/opencode" \
        "${session_dir}"
}

# Print the env var names this agent reads (one per line). The launcher
# unions these across all registered agents to build the passthrough set.
# Names only — no values; the container runtime copies values from the
# caller's environment via `-e <name>` (see passthrough-vars.sh).
#
# opencode is provider-agnostic: it reads each provider's own API key when
# configured to use that provider. We list every key opencode supports
# upstream so users can switch providers without re-editing this manifest.
agent_opencode_env_vars() {
    cat <<'EOF'
ANTHROPIC_API_KEY
OPENAI_API_KEY
OPENROUTER_API_KEY
GEMINI_API_KEY
GROQ_API_KEY
MISTRAL_API_KEY
DEEPSEEK_API_KEY
XAI_API_KEY
EOF
}
