#!/usr/bin/env bash
# Shared helpers for agents/claude/sync-settings.sh Venom tests.
# Source this file at the top of each test script.
#
# sync-settings.sh copies host ~/.claude/ resources into a per-session
# directory that the container later bind-mounts as its ~/.claude. Tests
# stage a fake host home, run the script, and inspect the session dir.
set -euo pipefail

# Stage a fresh test environment.
# Sets: TEST_DIR, HOST_CLAUDE, SESSION_DIR, EXTERNAL_DIR
# Exports: HOME
#
# Layout under TEST_DIR:
#   home/.claude/           — fake HOST_CLAUDE_DIR (arg 1 to sync-settings.sh)
#   home/.claude/plugins/   — pre-created so the "plugins not found" notice
#                              (harmless, but noisy) is suppressed
#   session/                — fake SESSION_DIR (arg 2)
#   external/               — outside the host claude dir; symlink target
#                              fixtures live here to exercise dereferencing
setup_sync_test() {
    TEST_DIR="$(mktemp -d)"
    HOST_CLAUDE="${TEST_DIR}/home/.claude"
    SESSION_DIR="${TEST_DIR}/session"
    # shellcheck disable=SC2034  # read by test cases after setup_sync_test
    # returns; bash function-scope leaks into the caller without `local`.
    EXTERNAL_DIR="${TEST_DIR}/external"
    mkdir -p "${HOST_CLAUDE}/plugins" "${SESSION_DIR}" "${EXTERNAL_DIR}"
    export HOME="${TEST_DIR}/home"
}

# Run sync-settings.sh against the staged fixtures. Stdout (bind-mount flags
# meant for the launcher) is captured per call so tests can inspect it; stderr
# (user-facing notices) is left attached.
run_sync() {
    : "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
    "${RIOTBOX_DIR}/agents/claude/sync-settings.sh" \
        "${HOST_CLAUDE}" \
        "${SESSION_DIR}"
}
