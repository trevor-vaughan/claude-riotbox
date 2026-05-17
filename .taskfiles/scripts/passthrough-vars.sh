#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# passthrough-vars.sh — Build container -e flags for configured env vars.
#
# Sourced (not executed) by launch.sh. Provides:
#   passthrough_export  — export each KEY=VALUE entry from
#                         RIOTBOX_PASSTHROUGH_VARS into the calling shell's
#                         process env. MUST be called in the launcher's
#                         current shell (no command substitution).
#   passthrough_flags   — print "-e NAME" tokens (whitespace-separated)
#                         for podman/docker. Safe to call via $(...).
#
# RIOTBOX_PASSTHROUGH_VARS entry forms (parsed line-by-line):
#   - bare NAME      — emit `-e NAME` iff NAME is non-empty in env
#   - KEY=VALUE      — export KEY="$VALUE" then unconditionally emit `-e KEY`
#                      (user-explicit assignment, empty values forwarded)
#
# Multiple bare names on one whitespace-separated line are accepted
# (backwards compatible with the historical single-line idiom). A line
# containing `=` is treated as one whole KEY=VALUE entry — values may
# contain whitespace, KEY=VALUE must be on its own line.
#
# Comment lines (leading `#` after trim) and blank lines are skipped.
#
# Values are bash-expanded at config-source time (~/.config/claude-riotbox/
# config is `source`d), so `FOO=$BAR` and `FOO=$(cmd)` Just Work — they
# are NOT re-expanded here, which would be a security regression.
#
# Default (when RIOTBOX_PASSTHROUGH_VARS is unset): the agent-registry
# union of every agent's env_vars output — bare names only.
# ─────────────────────────────────────────────────────────────────────────────

_PASSTHROUGH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=../../agents/registry.sh
source "${_PASSTHROUGH_ROOT}/agents/registry.sh"

# _passthrough_registry_vars
#   Print the deduped union of every registered agent's env_vars,
#   one name per line.
_passthrough_registry_vars() {
    local _agent
    for _agent in "${AGENT_REGISTRY[@]}"; do
        agent_call "${_agent}" env_vars
    done | sort -u
}

# _passthrough_source
#   Print the raw input — user override if set, else registry union.
_passthrough_source() {
    if [ -n "${RIOTBOX_PASSTHROUGH_VARS:-}" ]; then
        printf '%s' "${RIOTBOX_PASSTHROUGH_VARS}"
    else
        _passthrough_registry_vars
    fi
}

# _passthrough_valid_key NAME
#   Return 0 iff NAME is a POSIX identifier ([A-Za-z_][A-Za-z0-9_]*).
_passthrough_valid_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# _passthrough_trim VAR_NAME
#   Trim leading and trailing whitespace from the named variable in place.
_passthrough_trim() {
    local __v="${!1}"
    __v="${__v#"${__v%%[![:space:]]*}"}"
    __v="${__v%"${__v##*[![:space:]]}"}"
    printf -v "$1" '%s' "${__v}"
}

# passthrough_export
#   For each KEY=VALUE entry in the source, export KEY="$VALUE" into the
#   calling shell's process env. Bare-name entries are ignored here
#   (handled by passthrough_flags). Returns 1 (and prints to stderr) on
#   invalid KEY — caller's `set -e` will abort the launch.
passthrough_export() {
    local raw line key value
    raw="$(_passthrough_source)"
    while IFS= read -r line; do
        _passthrough_trim line
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        [[ "${line}" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if ! _passthrough_valid_key "${key}"; then
            printf 'passthrough-vars: invalid KEY in entry: %s\n' "${line}" >&2
            return 1
        fi
        export "${key}=${value}"
    done <<< "${raw}"
}

# passthrough_flags
#   Print "-e NAME" tokens for podman/docker, whitespace-separated.
#   Safe to call in a subshell ($(...)). Bare names are emitted only when
#   non-empty in env; KEY=VALUE entries are always emitted (user-explicit).
#   Returns 1 (and prints to stderr) on invalid KEY/NAME.
passthrough_flags() {
    local raw line key name flags=""
    raw="$(_passthrough_source)"
    while IFS= read -r line; do
        _passthrough_trim line
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        if [[ "${line}" == *=* ]]; then
            key="${line%%=*}"
            if ! _passthrough_valid_key "${key}"; then
                printf 'passthrough-vars: invalid KEY in entry: %s\n' "${line}" >&2
                return 1
            fi
            flags="${flags:+${flags} }-e ${key}"
        else
            # shellcheck disable=SC2086
            # Intentional word-splitting: bare-name lines may carry multiple
            # space-separated names (backwards-compatible single-line idiom).
            for name in ${line}; do
                if ! _passthrough_valid_key "${name}"; then
                    printf 'passthrough-vars: invalid NAME in entry: %s\n' "${name}" >&2
                    return 1
                fi
                if [ -n "${!name:-}" ]; then
                    flags="${flags:+${flags} }-e ${name}"
                fi
            done
        fi
    done <<< "${raw}"
    printf '%s' "${flags}"
}
