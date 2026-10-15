#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/sync-settings.sh — Copy host Pi config into a RiotBox session dir,
# and print the volume flags that mount it into the container.
#
# Usage: sync-settings.sh <host-agent-dir> <session-dir>
#
# <host-agent-dir> is the host's Pi agent directory: $PI_CODING_AGENT_DIR when
# the user relocated it, otherwise ~/.pi/agent (agents/pi/manifest.sh decides).
#
# Pi keeps its own state in the same directory as the config it reads, so this
# is NOT opencode's delete-and-recopy of a whole tree. Only the allowlisted
# entries below are replaced on each launch; everything else under
# <session-dir>/.pi-agent/ belongs to Pi and survives — above all sessions/,
# which holds the conversation history `riotbox resume` continues.
#
# Never copied from the host, because they are Pi-managed state or host-only
# install trees whose absolute paths cannot resolve in the container:
# sessions/, trust.json, models-store.json, npm/, git/, bin/, install/, ...
#
# Volume flags printed to stdout:
#   -v <session>/.pi-agent:/home/llm/.pi/agent:z
# plus a read-write bind for each credential file present on the host, so
# OAuth refreshes write back and later runs stay signed in:
#   -v <host-agent-dir>/auth.json:/home/llm/.pi/agent/auth.json:z
#   -v <host-agent-dir>/mcp-auth.json:/home/llm/.pi/agent/mcp-auth.json:z
#
# Known limitations:
#   * An unreadable file or a symlink loop under an allowlisted entry aborts
#     the sync (find/tar fail under pipefail), as in agents/opencode/sync-settings.sh.
#   * The extract-side tar's stderr is dropped, as in opencode.
#   * Paths containing whitespace break the printed -v flags, because
#     scripts/mount-projects.sh word-splits them (see its documented
#     limitation). This matters for a user-set PI_CODING_AGENT_DIR.
#
# Exit codes:
#   0 — success (including the no-host-config case, which prints a notice)
#   1 — wrong number of arguments, or a non-absolute <session-dir>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 <host-agent-dir> <session-dir>" >&2
	exit 1
fi

HOST_AGENT_DIR="$1"
SESSION_DIR="$2"

[[ "${SESSION_DIR}" = /* ]] || {
	echo "sync-settings.sh: session dir must be an absolute path: ${SESSION_DIR}" >&2
	exit 1
}

CONTAINER_AGENT_DIR="/home/llm/.pi/agent"
SESSION_AGENT_DIR="${SESSION_DIR}/.pi-agent"

# Host-authored config and resources Pi reads from its agent directory.
SYNCED_ENTRIES=(
	settings.json models.json mcp.json keybindings.json
	AGENTS.md SYSTEM.md APPEND_SYSTEM.md
	skills prompts themes extensions
)
CREDENTIAL_FILES=(auth.json mcp-auth.json)

# The session dir is mounted read-write in the container, so .pi-agent is
# untrusted: a symlink planted there would point this host-side rm/tar/mount
# at an arbitrary host directory. Replace anything that is not a real
# directory with one.
if [[ -L "${SESSION_AGENT_DIR}" ]] || { [[ -e "${SESSION_AGENT_DIR}" ]] && [[ ! -d "${SESSION_AGENT_DIR}" ]]; }; then
	echo "Warning: ${SESSION_AGENT_DIR} is not a real directory; recreating it." >&2
	rm -f "${SESSION_AGENT_DIR}"
fi

mkdir -p "${SESSION_AGENT_DIR}"

# Clear every allowlisted entry first, so an entry removed or renamed on the
# host does not linger in the session copy.
for entry in "${SYNCED_ENTRIES[@]}"; do
	rm -rf "${SESSION_AGENT_DIR:?}/${entry}"
done

if [[ -d "${HOST_AGENT_DIR}" ]]; then
	for entry in "${SYNCED_ENTRIES[@]}"; do
		# -e follows symlinks, so a dangling top-level symlink is skipped here.
		[[ -e "${HOST_AGENT_DIR}/${entry}" ]] || continue
		# Same dereferencing copy as agents/opencode/sync-settings.sh: under
		# find -L, valid symlinks report their target's type, so only broken
		# ones keep -type l and are filtered out before tar -h follows the rest.
		(
			cd "${HOST_AGENT_DIR}" &&
				find -L "./${entry}" ! -type l -print0 |
				tar -ch --null --no-recursion --files-from=- -f -
		) | tar -xf - -C "${SESSION_AGENT_DIR}/" --no-same-owner 2>/dev/null
	done
else
	echo "Notice: ${HOST_AGENT_DIR} not found on host — pi will use the container baseline." >&2
fi

echo "-v ${SESSION_AGENT_DIR}:${CONTAINER_AGENT_DIR}:z"

for file in "${CREDENTIAL_FILES[@]}"; do
	if [[ -f "${HOST_AGENT_DIR}/${file}" ]]; then
		echo "-v ${HOST_AGENT_DIR}/${file}:${CONTAINER_AGENT_DIR}/${file}:z"
	fi
done
