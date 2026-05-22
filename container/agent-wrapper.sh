#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agent-wrapper.sh — Generic agent wrapper, parameterized by basename($0).
#
# Installed at /home/llm/.riotbox/bin/<agent> (one symlink per agent
# pointing at this script). The wrapper:
#
#   1. Identifies the agent from its own filename — e.g. when invoked as
#      `claude`, it dispatches to the `claude` manifest.
#   2. Sources the agent registry to load every manifest.
#   3. Resolves the real binary via container/find-real-bin.sh.
#   4. Calls agent_<name>_wrapper_inject "$@" to rewrite argv (and decide
#      whether to set CI=true).
#   5. Execs the real binary with the rewritten argv.
#
# Replaces claude-wrapper.sh and opencode-wrapper.sh. Adding a new agent
# requires only a new manifest (agents/<name>/manifest.sh) and a symlink —
# no wrapper code to modify.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

agent="$(basename "$0")"

# Source the registry so we have agent_call and AGENT_REGISTRY available.
# Inside the container, the agents directory lives at ${HOME}/.riotbox/agents/
# (placed by the Dockerfile COPY).
# shellcheck source=/dev/null
source "${HOME}/.riotbox/agents/registry.sh"

if ! agent_is_registered "${agent}"; then
    echo "ERROR: agent-wrapper.sh invoked as '${agent}' but no such agent is registered." >&2
    echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
    exit 1
fi

# Resolve the agent's real binary on PATH (skipping ${HOME}/.riotbox/bin).
# The manifest tells us the binary name; the finder walks PATH.
real_bin_name="$(agent_call "${agent}" real_binary)"
# shellcheck source=/dev/null
source "${HOME}/.riotbox/find-real-bin.sh" "${real_bin_name}"
if [ -z "${REAL_BIN}" ]; then
    echo "ERROR: could not find the real ${real_bin_name} binary on PATH" >&2
    exit 1
fi

# Apply the agent's injection rules. wrapper_inject prints the rewritten argv
# as NUL-terminated tokens (`printf '%s\0'`) on stdout. NUL framing keeps
# multi-line argv (e.g. a `-p` prompt with embedded newlines) intact.
#
# Env hints (e.g. CI=true for non-interactive prompt mode) are NOT smuggled
# through stderr — that conflated env-channel and user diagnostics, and any
# manifest line matching the magic value would be silently consumed. Instead
# the wrapper allocates RIOTBOX_INJECT_ENV_FILE per call; manifests append
# `KEY=VAL` lines there, and we read+export them after the call returns.
# Stderr from the manifest passes through unchanged.
RIOTBOX_INJECT_ENV_FILE="$(mktemp)"
export RIOTBOX_INJECT_ENV_FILE
trap 'rm -f "${RIOTBOX_INJECT_ENV_FILE}"' EXIT
mapfile -d '' -t new_args < <(agent_call "${agent}" wrapper_inject "$@")

# Read each KEY=VAL line and export it. Lines that don't look like a valid
# `KEY=VAL` env assignment are skipped — manifests own this file and the
# format is strict on purpose.
if [ -s "${RIOTBOX_INJECT_ENV_FILE}" ]; then
    while IFS= read -r _line || [ -n "${_line}" ]; do
        # Match KEY=VAL where KEY is [A-Za-z_][A-Za-z0-9_]*
        if [[ "${_line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
        fi
    done < "${RIOTBOX_INJECT_ENV_FILE}"
fi
rm -f "${RIOTBOX_INJECT_ENV_FILE}"
trap - EXIT
unset RIOTBOX_INJECT_ENV_FILE _line

exec "${REAL_BIN}" "${new_args[@]}"
