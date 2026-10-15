#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/sync-settings.sh — Copy host Pi config into a RiotBox session's
# state dir, and print the volume flags that mount it into the container.
#
# Usage: sync-settings.sh <host-agent-dir> <state-dir>
#
# <host-agent-dir> is the host's Pi agent directory: $PI_CODING_AGENT_DIR when
# the user relocated it, otherwise ~/.pi/agent (agents/pi/manifest.sh decides).
# <state-dir> is the session's ${XDG_DATA_HOME}/riotbox-state/<key>, never the
# session dir: the container has the session dir read-write and could swap
# anything nested in it for a symlink (see scripts/lib/session-state.sh).
#
# Pi keeps its own state in the same directory as the config it reads, so this
# does NOT mirror the whole host tree, as opencode's sync does. Only the allowlisted
# entries below are replaced on each launch; everything else under
# <state-dir>/pi-agent/ belongs to Pi and survives — above all sessions/,
# which holds the conversation history `riotbox resume` continues.
#
# Never copied from the host, because they are Pi-managed state or host-only
# install trees whose absolute paths cannot resolve in the container:
# sessions/, trust.json, models-store.json, npm/, git/, bin/, install/, ...
#
# Volume flags printed to stdout:
#   -v <state>/pi-agent:/home/llm/.pi/agent:z
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
#   1 — wrong number of arguments, a non-absolute <state-dir>, or an entry
#       changed during sync
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 <host-agent-dir> <state-dir>" >&2
	exit 1
fi

HOST_AGENT_DIR="$1"
STATE_DIR="$2"

[[ "${STATE_DIR}" = /* ]] || {
	echo "sync-settings.sh: state dir must be an absolute path: ${STATE_DIR}" >&2
	exit 1
}

RIOTBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/session-state.sh
source "${RIOTBOX_ROOT}/scripts/lib/session-state.sh"

CONTAINER_AGENT_DIR="/home/llm/.pi/agent"
STATE_AGENT_DIR="${STATE_DIR}/pi-agent"

# Host-authored config and resources Pi reads from its agent directory.
SYNCED_ENTRIES=(
	settings.json models.json mcp.json keybindings.json
	AGENTS.md SYSTEM.md APPEND_SYSTEM.md
	skills prompts themes extensions
)
CREDENTIAL_FILES=(auth.json mcp-auth.json)

# A symlink or file at pi-agent would point the mv/mount below at an
# arbitrary host directory, so replace it with a real directory first.
ensure_real_dir "${STATE_AGENT_DIR}"

# Two sessions of one project share pi-agent/, so a hostile container can
# plant a link in it at any moment. Extract into a staging dir the container
# cannot reach (the state dir itself is never mounted), then rename each
# entry into place: rename(2) replaces a planted link instead of following it,
# and fails rather than merging into a directory that appeared meanwhile.
STAGE_DIR="$(mktemp -d "${STATE_DIR}/.sync.XXXXXX")"
trap 'rm -rf -- "${STAGE_DIR}"' EXIT

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
		) | tar -xf - -C "${STAGE_DIR}/" --no-same-owner 2>/dev/null
	done
else
	echo "Notice: ${HOST_AGENT_DIR} not found on host — pi will use the container baseline." >&2
fi

# Clear every allowlisted entry, so an entry removed or renamed on the host
# does not linger in the session copy, then install the staged ones.
for entry in "${SYNCED_ENTRIES[@]}"; do
	rm -rf -- "${STATE_AGENT_DIR:?}/${entry}"
	if [[ -e "${STAGE_DIR}/${entry}" ]]; then
		mv -T -- "${STAGE_DIR}/${entry}" "${STATE_AGENT_DIR}/${entry}" || {
			echo "Error: ${entry} in ${STATE_AGENT_DIR} changed during sync (another process, possibly a running session of this project, modified it); aborting." >&2
			exit 1
		}
	fi
done

echo "-v ${STATE_AGENT_DIR}:${CONTAINER_AGENT_DIR}:z"

for file in "${CREDENTIAL_FILES[@]}"; do
	if [[ -f "${HOST_AGENT_DIR}/${file}" ]]; then
		echo "-v ${HOST_AGENT_DIR}/${file}:${CONTAINER_AGENT_DIR}/${file}:z"
	fi
done
