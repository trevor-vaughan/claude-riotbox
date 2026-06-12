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
#   3. Interposes headroom (when RIOTBOX_HEADROOM=1 and guard unset): execs
#      `headroom wrap <agent> … -- <original argv>`, which re-launches the shim;
#      the guard (RIOTBOX_HEADROOM_ACTIVE=1) makes that second pass fall through.
#   4. Resolves the real binary via container/find-real-bin.sh.
#   5. Calls agent_<name>_wrapper_inject "$@" to rewrite argv (and decide
#      whether to set CI=true).
#   6. Execs the real binary with the rewritten argv.
#
# Replaces claude-wrapper.sh and opencode-wrapper.sh. Adding a new agent
# requires only a new manifest (agents/<name>/manifest.sh) and a symlink —
# no wrapper code to modify.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

agent="$(basename "$0")"

# Source the registry so we have agent_call and AGENT_REGISTRY available.
# Inside the container, the agents directory lives at ${HOME}/.riotbox/agents/
# (placed by the Containerfile COPY).
# shellcheck source=/dev/null
source "${HOME}/.riotbox/agents/registry.sh"

# shellcheck disable=SC2154  # AGENT_REGISTRY is set by agents/registry.sh (sourced above)
if ! agent_is_registered "${agent}"; then
	echo "ERROR: agent-wrapper.sh invoked as '${agent}' but no such agent is registered." >&2
	echo "       Registered agents: ${AGENT_REGISTRY[*]}" >&2
	exit 1
fi

# ── Headroom interposition (opt-in context compression) ─────────────────────
# First pass (RIOTBOX_HEADROOM=1, guard unset): exec `headroom wrap …`
# instead of the real binary. headroom re-launches the agent by name, which
# resolves back to this shim; the exported RIOTBOX_HEADROOM_ACTIVE guard
# makes that second pass fall through to the normal inject-and-exec path
# below. Both degraded modes (agent has no headroom_argv verb / headroom
# missing from the image) warn and run unwrapped — headroom is an
# optimization layer, never a reason to lose a session.
if [[ "${RIOTBOX_HEADROOM:-0}" = "1" ]] && [[ -z "${RIOTBOX_HEADROOM_ACTIVE:-}" ]]; then
	if ! declare -F "agent_${agent}_headroom_argv" >/dev/null; then
		echo "WARNING: RIOTBOX_HEADROOM=1 but agent '${agent}' has no headroom support — running unwrapped." >&2
	elif ! command -v headroom >/dev/null 2>&1; then
		echo "WARNING: RIOTBOX_HEADROOM=1 but headroom is not installed in this image — running unwrapped." >&2
		echo "         Update the image with: riotbox update" >&2
	else
		export RIOTBOX_HEADROOM_ACTIVE=1
		# shellcheck disable=SC2312  # agent_call exit code is not masked; mapfile reads its stdout via process substitution
		mapfile -d '' -t headroom_args < <(agent_call "${agent}" headroom_argv "$@")
		exec "${headroom_args[@]}"
	fi
fi

# Resolve the agent's real binary on PATH (skipping ${HOME}/.riotbox/bin).
# The manifest tells us the binary name; the finder walks PATH.
real_bin_name="$(agent_call "${agent}" real_binary)"
# shellcheck source=/dev/null
source "${HOME}/.riotbox/find-real-bin.sh" "${real_bin_name}"
if [[ -z "${REAL_BIN}" ]]; then
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
# shellcheck disable=SC2312  # agent_call exit code is not masked; mapfile reads its stdout via process substitution
mapfile -d '' -t new_args < <(agent_call "${agent}" wrapper_inject "$@")

# Read each KEY=VAL line and export it. Lines that don't look like a valid
# `KEY=VAL` env assignment are skipped — manifests own this file and the
# format is strict on purpose.
if [[ -s "${RIOTBOX_INJECT_ENV_FILE}" ]]; then
	while IFS= read -r _line || [[ -n "${_line}" ]]; do
		# Match KEY=VAL where KEY is [A-Za-z_][A-Za-z0-9_]*
		if [[ "${_line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
			export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
		fi
	done <"${RIOTBOX_INJECT_ENV_FILE}"
fi
rm -f "${RIOTBOX_INJECT_ENV_FILE}"
trap - EXIT
unset RIOTBOX_INJECT_ENV_FILE _line

exec "${REAL_BIN}" "${new_args[@]}"
