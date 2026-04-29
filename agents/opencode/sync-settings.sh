#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-opencode-settings.sh — Copy host opencode config into a riotbox
# session dir, and print volume flags to bind-mount it into the container.
#
# Usage: sync-opencode-settings.sh \
#            <host-config-dir> <host-data-dir> <session-dir>
#
# Behavior:
#   * <session-dir>/.config-opencode/      — host config copy, refreshed
#   * <session-dir>/.local-share-opencode/ — empty session-owned data dir
#
# Volume flags printed to stdout:
#   -v <session>/.config-opencode:/home/claude/.config/opencode:z
#   -v <session>/.local-share-opencode:/home/claude/.local/share/opencode:z
#
# If <host-data-dir>/auth.json exists, an additional RW bind is emitted so
# OAuth refresh tokens write back to the host file:
#   -v <host-data-dir>/auth.json:/home/claude/.local/share/opencode/auth.json:z
#
# Exit codes:
#   0 — success (including the no-host-config case, which prints a notice)
#   1 — wrong number of arguments
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 <host-config-dir> <host-data-dir> <session-dir>" >&2
    exit 1
fi

HOST_CONFIG_DIR="$1"
HOST_DATA_DIR="$2"
SESSION_DIR="$3"

CONTAINER_HOME="/home/claude"
SESSION_CONFIG="${SESSION_DIR}/.config-opencode"
SESSION_DATA="${SESSION_DIR}/.local-share-opencode"

mkdir -p "${SESSION_CONFIG}" "${SESSION_DATA}"

# ── Host config copy ─────────────────────────────────────────────────────────
# Re-copy on each launch so renamed/removed agents, commands, and themes
# do not linger. -L dereferences symlinks (host configs may include
# symlinked dev checkouts).
if [ -d "${HOST_CONFIG_DIR}" ]; then
    rm -rf "${SESSION_CONFIG:?SESSION_CONFIG is required}"
    mkdir -p "${SESSION_CONFIG}"
    # cp -rL aborts on dangling symlinks under set -e, leaving the session
    # dir empty and the volume flags unprinted. Pre-filter with `find -L`:
    # under -L, valid symlinks report their target's type, so only broken
    # symlinks retain -type l. Stream paths through tar -h to dereference
    # and copy. Mirrors the fix in container/plugin-setup.sh (commit 0f0ed53).
    ( cd "${HOST_CONFIG_DIR}" \
        && find -L . ! -type l -print0 \
        | tar -ch --null --no-recursion --files-from=- -f - \
    ) | tar -xf - -C "${SESSION_CONFIG}/" --no-same-owner 2>/dev/null
else
    echo "Notice: ${HOST_CONFIG_DIR} not found on host — opencode will use container baseline." >&2
fi

# ── Volume flags for session-mounted config and data ────────────────────────
echo "-v ${SESSION_CONFIG}:${CONTAINER_HOME}/.config/opencode:z"
echo "-v ${SESSION_DATA}:${CONTAINER_HOME}/.local/share/opencode:z"

# ── Auth (RW bind, nested mount inside the data dir bind) ───────────────────
# OAuth refresh writes back to the host file so subsequent runs stay logged in.
if [ -f "${HOST_DATA_DIR}/auth.json" ]; then
    echo "-v ${HOST_DATA_DIR}/auth.json:${CONTAINER_HOME}/.local/share/opencode/auth.json:z"
fi
