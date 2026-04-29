#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/registry.sh — Single source of truth for the set of supported CLI
# agents and the dispatcher that routes verbs to per-agent implementations.
#
# Every agent contributes a manifest at agents/<name>/manifest.sh that defines
# a fixed set of agent_<name>_<verb> functions (see docs/maintainer/adding-an-agent.md
# for the full contract). This file:
#   1. Auto-discovers agents by globbing agents/*/manifest.sh.
#   2. Sources each manifest.
#   3. Provides agent_call / agent_is_registered for callers.
#
# Sourceable from both host scripts (where ROOT_DIR points at /workspace) and
# from inside the container (where the registry lives at ${HOME}/.riotbox/agents/).
# Callers locate the directory containing the registry via BASH_SOURCE so no
# external path variable is required.
# ─────────────────────────────────────────────────────────────────────────────

# Re-sourcing safety: the registry is small but a few host scripts may source
# it more than once during a single invocation (e.g. install.sh chained into
# Taskfile dispatch). Make the load idempotent so we do not pay for redundant
# disk reads or accidentally clobber state set by a caller.
if [ "${_AGENT_REGISTRY_LOADED:-0}" = "1" ]; then
    # shellcheck disable=SC2317  # `true` runs only when this file is *executed*
    # (rare — it is meant to be sourced); `return` outside a function fails
    # in that case, so the `|| true` swallows the error.
    return 0 2>/dev/null || true
fi
_AGENT_REGISTRY_LOADED=1

# Resolve the directory that contains this file. Used to source the per-agent
# manifests by absolute path so callers do not have to set anything.
_agent_registry_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── The registry: auto-discovered from agents/*/manifest.sh ─────────────────
# To add a new agent: create agents/<name>/manifest.sh defining the contract
# functions (see docs/maintainer/adding-an-agent.md). The registry picks it
# up automatically — no edit to this file required.
#
# Discovery rules:
#   * Any subdirectory of agents/ that contains a manifest.sh is registered.
#   * Subdirectories without manifest.sh are skipped (they belong to
#     scaffolding, drafts, or unrelated tooling — not to an active agent).
#   * Names starting with `_` or `.` are skipped (template/hidden dirs).
#   * Iteration order is the shell glob's lexical order, which is stable.
#
# Manifests are pure function declarations — no side effects on source.
AGENT_REGISTRY=()
for _agent_manifest in "${_agent_registry_dir}"/*/manifest.sh; do
    # Glob with no matches expands to the literal pattern; guard against it.
    [ -f "${_agent_manifest}" ] || continue
    _agent_dir="$(dirname "${_agent_manifest}")"
    _agent="$(basename "${_agent_dir}")"
    # Skip template / hidden directories.
    case "${_agent}" in
        _*|.*) continue ;;
    esac
    AGENT_REGISTRY+=("${_agent}")
    # shellcheck source=/dev/null
    source "${_agent_manifest}"
done
unset _agent _agent_dir _agent_manifest

if [ "${#AGENT_REGISTRY[@]}" -eq 0 ]; then
    echo "ERROR: no agents discovered under ${_agent_registry_dir}/*/manifest.sh" >&2
    # shellcheck disable=SC2317  # `exit` runs only when this file is
    # *executed* directly; `return` outside a function then fails and
    # the fallback fires.
    return 1 2>/dev/null || exit 1
fi

# ── Public API ───────────────────────────────────────────────────────────────

# agent_is_registered <name>
#   Exit 0 if <name> is in AGENT_REGISTRY, 1 otherwise. Quiet — no output.
agent_is_registered() {
    local needle="${1:-}"
    local a
    for a in "${AGENT_REGISTRY[@]}"; do
        if [ "${a}" = "${needle}" ]; then
            return 0
        fi
    done
    return 1
}

# agent_call <agent> <verb> [args...]
#   Dispatches to agent_<agent>_<verb> with the remaining arguments. Validates
#   both the agent and the verb up front so callers get a clear error rather
#   than the nondescript "command not found" bash would otherwise emit.
agent_call() {
    local agent="${1:-}"
    local verb="${2:-}"
    shift 2 || true

    if ! agent_is_registered "${agent}"; then
        echo "ERROR: unknown agent: '${agent}'. Registered agents: ${AGENT_REGISTRY[*]}" >&2
        return 2
    fi

    local fn="agent_${agent}_${verb}"
    if ! declare -F "${fn}" >/dev/null; then
        echo "ERROR: agent '${agent}' does not implement verb '${verb}' (missing function ${fn})" >&2
        return 2
    fi

    "${fn}" "$@"
}

# agent_registry_csv
#   Print AGENT_REGISTRY as a comma-separated list. Used by --agent error
#   messages to show "must be one of: claude, opencode" without the caller
#   having to re-stringify the array.
agent_registry_csv() {
    local IFS=,
    printf '%s' "${AGENT_REGISTRY[*]}"
}
