#!/usr/bin/env bash
set -euo pipefail
# Resume the last session for the active agent.
# Required env: ROOT_DIR (set by Taskfile)
# Reads: RIOTBOX_AGENT (default: claude)

# shellcheck source=../../agents/registry.sh
source "${ROOT_DIR}/agents/registry.sh"
agent="${RIOTBOX_AGENT:-claude}"
if ! agent_is_registered "${agent}"; then
    echo "ERROR: unknown RIOTBOX_AGENT: '${agent}'" >&2
    echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
    exit 1
fi
mapfile -d '' -t agent_argv < <(agent_call "${agent}" resume_argv)
exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" "${agent_argv[@]}"
