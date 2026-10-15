#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-opencode-settings.sh — Copy host opencode config into a RiotBox
# session's state dir, and print volume flags to bind-mount it into the
# container.
#
# Usage: sync-opencode-settings.sh \
#            <host-config-dir> <host-data-dir> <state-dir>
#
# <state-dir> is the session's ${XDG_DATA_HOME}/riotbox-state/<key>, never the
# session dir: the container has the session dir read-write and could swap
# anything nested in it for a symlink (see scripts/lib/session-state.sh).
#
# Behavior:
#   * <state-dir>/opencode-config/ — host config copy, refreshed in place,
#       minus opencode's plugin-install output (node_modules/, package.json,
#       package-lock.json, bun.lock, .gitignore) which the container rebuilds
#       from the persistent riotbox-cache-opencode volume, and minus the
#       host's Context Mode data (context-mode/, memory/). Those entries
#       belong to the session and survive a re-sync.
#   * <state-dir>/opencode-data/   — empty session-owned data dir
#
# Volume flags printed to stdout:
#   -v <state>/opencode-config:/home/llm/.config/opencode:z
#   -v <state>/opencode-data:/home/llm/.local/share/opencode:z
#
# If <host-data-dir>/auth.json exists, an additional RW bind is emitted so
# OAuth refresh tokens write back to the host file:
#   -v <host-data-dir>/auth.json:/home/llm/.local/share/opencode/auth.json:z
#
# Exit codes:
#   0 — success (including the no-host-config case, which prints a notice)
#   1 — wrong number of arguments, or an entry changed during sync
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "Usage: $0 <host-config-dir> <host-data-dir> <state-dir>" >&2
	exit 1
fi

HOST_CONFIG_DIR="$1"
HOST_DATA_DIR="$2"
STATE_DIR="$3"

RIOTBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/session-state.sh
source "${RIOTBOX_ROOT}/scripts/lib/session-state.sh"

CONTAINER_HOME="/home/llm"
STATE_CONFIG="${STATE_DIR}/opencode-config"
STATE_DATA="${STATE_DIR}/opencode-data"

ensure_real_dir "${STATE_CONFIG}"
ensure_real_dir "${STATE_DATA}"

# ── Host config copy ─────────────────────────────────────────────────────────
# Re-copy on each launch so renamed/removed agents, commands, and themes
# do not linger. -L dereferences symlinks (host configs may include
# symlinked dev checkouts).
#
# Top-level entries the copy skips because the session writes them at
# runtime (see the exclusion notes below). The re-sync leaves them in place.
RUNTIME_ENTRIES=(
	node_modules package.json package-lock.json bun.lock .gitignore
	context-mode memory
)
RUNTIME_PRUNE=()
for entry in "${RUNTIME_ENTRIES[@]}"; do
	RUNTIME_PRUNE+=(-path "./${entry}" -prune -o)
done

if [[ -d "${HOST_CONFIG_DIR}" ]]; then
	# Two sessions of one project share opencode-config/, so a hostile
	# container can plant a link in it at any moment. Extract into a staging
	# dir the container cannot reach (the state dir itself is never mounted),
	# then rename each entry into place: rename(2) replaces a planted link
	# instead of following it, and fails rather than merging into a directory
	# that appeared meanwhile.
	STAGE_DIR="$(mktemp -d "${STATE_DIR}/.sync.XXXXXX")"
	trap 'rm -rf -- "${STAGE_DIR}"' EXIT
	# cp -rL aborts on dangling symlinks under set -e, leaving the config
	# copy empty and the volume flags unprinted. Pre-filter with `find -L`:
	# under -L, valid symlinks report their target's type, so only broken
	# symlinks retain -type l. Stream paths through tar -h to dereference
	# and copy. Mirrors the fix in container/plugin-setup.sh (commit 0f0ed53).
	#
	# Exclude opencode's plugin-install output. When opencode.jsonc declares
	# plugins it runs `bun install` at startup and writes node_modules/ plus
	# package.json/package-lock.json/bun.lock/.gitignore into the config dir
	# (these are exactly the entries opencode's own generated .gitignore
	# marks disposable). They are large and platform-specific (native
	# node_modules), and the container rebuilds them in ~2s from the
	# persistent riotbox-cache-opencode volume, so carrying the host copy
	# across would only risk host/container ABI mismatch. Prune the
	# node_modules tree and skip the four generated top-level files.
	#
	# Also prune context-mode/ and memory/, upstream's default homes for a
	# host's opencode Context Mode session DB and ctx_* stores, and for its
	# auto-memory: host data (verbatim tool output, and memory gathered across
	# every host project), not config. The session keeps its own under
	# opencode-data (agents/opencode/context-mode.sh), and a context-mode/ copy
	# here would trip that file's one-time migration: moved into an empty
	# store, or a both-exist warning on every later launch. Upstream reads
	# <config>/memory only when CONTEXT_MODE_DATA_DIR is unset, i.e. RiotBox's
	# Context Mode is off and the host opencode config loads context-mode as a
	# plugin itself. That session starts with no auto-memory, by decision,
	# rather than with a copy of the host's, and what it writes there stays
	# with the session.
	(
		cd "${HOST_CONFIG_DIR}" &&
			find -L . "${RUNTIME_PRUNE[@]}" ! -type l -print0 |
			tar -ch --null --no-recursion --files-from=- -f -
	) | tar -xf - -C "${STAGE_DIR}/" --no-same-owner 2>/dev/null

	# opencode-config/ is the bind-mount source of every running session of
	# this project, and a bind mount holds the directory's inode, not its path.
	# Replacing the directory would leave those sessions holding a deleted,
	# empty one, so swap the entries inside it instead. Clear every entry the
	# sync owns first, so one removed or renamed on the host does not linger.
	# shellcheck disable=SC2312 # the listing's status is checked through wait below
	mapfile -d '' -t synced < <(cd "${STATE_CONFIG}" && find . -mindepth 1 -maxdepth 1 "${RUNTIME_PRUNE[@]}" -printf '%P\0')
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	wait "$!" || {
		echo "Error: could not list ${STATE_CONFIG}; aborting before an entry removed on the host could linger." >&2
		exit 1
	}
	for entry in "${synced[@]}"; do
		rm -rf -- "${STATE_CONFIG:?}/${entry}"
	done
	# shellcheck disable=SC2312 # the listing's status is checked through wait below
	mapfile -d '' -t staged < <(find "${STAGE_DIR}" -mindepth 1 -maxdepth 1 -printf '%P\0')
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	wait "$!" || {
		echo "Error: could not list the staged opencode config in ${STAGE_DIR}; aborting." >&2
		exit 1
	}
	for entry in "${staged[@]}"; do
		mv -T -- "${STAGE_DIR}/${entry}" "${STATE_CONFIG}/${entry}" || {
			echo "Error: ${entry} in ${STATE_CONFIG} changed during sync (another process, possibly a running session of this project, modified it); aborting." >&2
			exit 1
		}
	done
else
	echo "Notice: ${HOST_CONFIG_DIR} not found on host — opencode will use container baseline." >&2
fi

# ── Volume flags for state-dir config and data ──────────────────────────────
echo "-v ${STATE_CONFIG}:${CONTAINER_HOME}/.config/opencode:z"
echo "-v ${STATE_DATA}:${CONTAINER_HOME}/.local/share/opencode:z"

# ── Auth (RW bind, nested mount inside the data dir bind) ───────────────────
# OAuth refresh writes back to the host file so subsequent runs stay logged in.
if [[ -f "${HOST_DATA_DIR}/auth.json" ]]; then
	echo "-v ${HOST_DATA_DIR}/auth.json:${CONTAINER_HOME}/.local/share/opencode/auth.json:z"
fi
