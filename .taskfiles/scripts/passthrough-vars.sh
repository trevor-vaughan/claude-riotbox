#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# passthrough-vars.sh — Build container -e flags for configured env vars.
#
# Sourced (not executed) by launch.sh. Provides:
#   passthrough_flags  — prints "-e NAME" tokens (one per set variable),
#                        whitespace-separated. Empty output when nothing is set.
#
# The default list of variables is the union of every registered agent's
# `agent_<name>_env_vars` output (see agents/*/manifest.sh). This keeps
# the source-of-truth co-located with each agent: adding a provider key
# means editing one manifest, not this file.
#
# RIOTBOX_PASSTHROUGH_VARS (whitespace-separated) overrides the registry
# union when set — power users who want a curated passthrough list keep
# full control. Override via env or ~/.config/claude-riotbox/config.
#
# Values are NOT inlined — `-e NAME` (without `=value`) tells podman/docker
# to copy the value from the calling environment. This avoids quoting
# issues and keeps secrets out of process argv.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve the riotbox source root from this file's location. The script is
# always at <root>/.taskfiles/scripts/passthrough-vars.sh, so two levels up
# gets us to <root>. This works regardless of caller cwd or whether ROOT_DIR
# happens to be set in the environment, which keeps the script sourceable
# from both launch.sh (where ROOT_DIR is set) and standalone test scripts
# (where it may not be).
_PASSTHROUGH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../../agents/registry.sh
source "${_PASSTHROUGH_ROOT}/agents/registry.sh"

# _passthrough_registry_vars
#   Print the deduped, sorted union of every registered agent's env_vars.
#   One name per line — env var names cannot contain whitespace or NULs,
#   so newline framing is unambiguous and round-trips through `mapfile -t`.
_passthrough_registry_vars() {
    local _agent
    for _agent in "${AGENT_REGISTRY[@]}"; do
        agent_call "${_agent}" env_vars
    done | sort -u
}

passthrough_flags() {
    local vars
    if [ -n "${RIOTBOX_PASSTHROUGH_VARS:-}" ]; then
        # User override: whitespace-separated string. Word-split as-is.
        vars="${RIOTBOX_PASSTHROUGH_VARS}"
    else
        # Registry union, newline-separated. Word-splitting in the loop
        # below handles whitespace (including newlines) uniformly.
        vars="$(_passthrough_registry_vars)"
    fi
    local flags=""
    local name
    for name in ${vars}; do
        # Indirect expansion: ${!name} is the value of the var named $name.
        if [ -n "${!name:-}" ]; then
            if [ -z "${flags}" ]; then
                flags="-e ${name}"
            else
                flags="${flags} -e ${name}"
            fi
        fi
    done
    printf '%s' "${flags}"
}
