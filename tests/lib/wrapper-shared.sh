#!/usr/bin/env bash
# Shared helpers for testing the generic agent-wrapper installed under any
# agent name. Used by tests/wrapper-claude.venom.yml and the parametric
# negative-case tests in tests/agents.venom.yml.
set -euo pipefail

# Build a sandboxed PATH with a fake real binary at <agent>'s name and the
# generic wrapper installed at $HOME/.riotbox/bin/<agent>. Sets:
#   TEST_DIR, FAKE_REAL_BIN, FAKE_WRAPPER_BIN
# Exports HOME, PATH (with .riotbox/bin first, then realbin, then coreutils).
#
# Args: $1 — agent name (e.g. claude, opencode, or a non-registered one)
setup_wrapper_sandbox() {
    : "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
    local agent="${1:?setup_wrapper_sandbox requires an agent name}"

    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/home/.riotbox/bin" "${TEST_DIR}/home/.riotbox/agents" \
             "${TEST_DIR}/realbin"

    # Stub wrapper at .riotbox/bin/<agent>: the test will overwrite this with
    # the generic agent-wrapper.sh once it's ready to exercise it. Until then,
    # the stub stands in so find-real-bin tests can verify "skip the riotbox
    # bin path".
    FAKE_WRAPPER_BIN="${TEST_DIR}/home/.riotbox/bin/${agent}"
    cat > "${FAKE_WRAPPER_BIN}" <<'WRAPPER'
#!/usr/bin/env bash
echo "FAKE_WRAPPER_INVOKED_INCORRECTLY"
WRAPPER
    chmod +x "${FAKE_WRAPPER_BIN}"

    # Fake REAL <agent> at a separate PATH dir. Prints arg=VALUE rather than
    # arg: VALUE because colon-space inside an unquoted YAML scalar parses
    # as a mapping separator and breaks venom assertions.
    FAKE_REAL_BIN="${TEST_DIR}/realbin/${agent}"
    cat > "${FAKE_REAL_BIN}" <<FAKE
#!/usr/bin/env bash
echo "FAKE_REAL_${agent}_INVOKED"
echo "CI=\${CI:-unset}"
printf 'arg=%s\n' "\$@"
FAKE
    chmod +x "${FAKE_REAL_BIN}"

    export HOME="${TEST_DIR}/home"
    # Coreutils-only system PATH so any real agent installed on the test
    # host (e.g. /home/claude/.local/bin/opencode) is invisible. The
    # wrapper's find-real-bin must resolve to FAKE_REAL_BIN, not the host.
    export PATH="${TEST_DIR}/home/.riotbox/bin:${TEST_DIR}/realbin:/usr/bin:/bin"
}

# Replace the stub at .riotbox/bin/<agent> with the real generic wrapper +
# its dependencies (find-real-bin.sh and agents/ tree). Call after
# setup_wrapper_sandbox when the test is ready to exercise the wrapper.
install_generic_wrapper_for() {
    : "${RIOTBOX_DIR:?RIOTBOX_DIR must be set}"
    : "${TEST_DIR:?call setup_wrapper_sandbox first}"
    local agent="${1:?install_generic_wrapper_for requires an agent name}"
    cp "${RIOTBOX_DIR}/container/agent-wrapper.sh" \
       "${TEST_DIR}/home/.riotbox/bin/${agent}"
    chmod +x "${TEST_DIR}/home/.riotbox/bin/${agent}"
    cp "${RIOTBOX_DIR}/container/find-real-bin.sh" \
       "${TEST_DIR}/home/.riotbox/find-real-bin.sh"
    cp -r "${RIOTBOX_DIR}/agents/." \
          "${TEST_DIR}/home/.riotbox/agents/"
}
