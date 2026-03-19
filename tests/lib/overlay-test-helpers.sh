#!/usr/bin/env bash
# Shared helpers for overlay Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create an overlay test environment with a project and session directory.
# Args:
#   $1 — tmpdir base (default: /tmp). Use /dev/shm for whiteout tests.
# Sets: TEST_DIR, PROJECT, SESSION, OVERLAY
# Exports: XDG_DATA_HOME, ROOT_DIR
setup_overlay_test() {
    local tmpbase="${1:-/tmp}"
    TEST_DIR="$(mktemp -d --tmpdir="${tmpbase}")"

    PROJECT="${TEST_DIR}/myproject"
    mkdir -p "${PROJECT}"

    local session_key
    session_key="$(echo "${PROJECT}" | sed 's|/|-|g; s|^-||')"
    export XDG_DATA_HOME="${TEST_DIR}/data"
    SESSION="${XDG_DATA_HOME}/claude-riotbox/${session_key}"
    OVERLAY="${SESSION}/overlay/project"
    mkdir -p "${OVERLAY}/upper" "${OVERLAY}/work"
    echo "${PROJECT}" > "${SESSION}/.projects"

    export ROOT_DIR="${RIOTBOX_DIR}"
}
