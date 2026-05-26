#!/usr/bin/env bash
set -euo pipefail
# Resume the last session for the active agent.
# Required env: ROOT_DIR (set by Taskfile)
# Reads: RIOTBOX_AGENT (default: claude)

# shellcheck source=../agents/registry.sh disable=SC1091  # source path resolves only from libexec/; safe to skip follow
# shellcheck disable=SC2154  # ROOT_DIR is exported by the caller (bin/riotbox)
source "${ROOT_DIR}/agents/registry.sh"
agent="${RIOTBOX_AGENT:-claude}"
# shellcheck disable=SC2310  # if-condition handles non-zero; set -e suppression is intentional
if ! agent_is_registered "${agent}"; then
	echo "ERROR: unknown RIOTBOX_AGENT: '${agent}'" >&2
	# shellcheck disable=SC2154  # AGENT_REGISTRY is set by agents/registry.sh (sourced above)
	echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
	exit 1
fi
# shellcheck disable=SC2312  # agent_call prints; mapfile captures its stdout deliberately
mapfile -d '' -t agent_argv < <(agent_call "${agent}" resume_argv)
exec "${ROOT_DIR}/libexec/launch.sh" "${agent_argv[@]}"
