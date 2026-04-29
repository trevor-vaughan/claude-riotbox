#!/usr/bin/env bash
# Shared helpers for opencode-related Venom tests.
# Source this file at the top of each test script.
#
# After the agent-registry refactor, the in-container wrapper is generic
# (container/agent-wrapper.sh). Tests install it as `opencode` via the same
# symlink-or-copy pattern the Dockerfile uses, plus the agents/ manifests
# and find-real-bin.sh, so the wrapper's runtime dependencies resolve.
set -euo pipefail

# Set up a fake PATH containing a riotbox bin (with a wrapper stub) and a
# fake real opencode. Sets:
#   TEST_DIR, FAKE_REAL_OPENCODE, FAKE_WRAPPER_OPENCODE
# Exports:
#   HOME, PATH (with .riotbox/bin first, then a dir holding the fake real opencode)
setup_opencode_path_test() {
    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/home/.riotbox/bin" "${TEST_DIR}/home/.riotbox/agents" \
             "${TEST_DIR}/realbin"

    # Fake WRAPPER inside .riotbox/bin — find-real-bin.sh must skip this.
    # Prints a distinct sentinel so the test can assert it was bypassed.
    FAKE_WRAPPER_OPENCODE="${TEST_DIR}/home/.riotbox/bin/opencode"
    cat > "${FAKE_WRAPPER_OPENCODE}" <<'WRAPPER'
#!/usr/bin/env bash
echo "FAKE_WRAPPER_INVOKED_INCORRECTLY"
WRAPPER
    chmod +x "${FAKE_WRAPPER_OPENCODE}"

    # Fake REAL opencode further down PATH — what find should resolve to.
    # Print args with `arg=VALUE` rather than `arg: VALUE`: a colon-space
    # inside an unquoted YAML scalar (the venom assertion line) is parsed
    # as a mapping separator, breaking ShouldContainSubstring assertions.
    FAKE_REAL_OPENCODE="${TEST_DIR}/realbin/opencode"
    cat > "${FAKE_REAL_OPENCODE}" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE_REAL_OPENCODE_INVOKED"
printf 'arg=%s\n' "$@"
FAKE
    chmod +x "${FAKE_REAL_OPENCODE}"

    export HOME="${TEST_DIR}/home"
    # Strip the system PATH down to coreutils-only locations. Tests that
    # delete FAKE_REAL_OPENCODE expect REAL_BIN to come back empty, so any
    # real opencode installed on the test host (e.g. when running tests
    # outside the dedicated container) must not be discoverable. Keep just
    # /usr/bin and /bin so jq, mktemp, etc. still resolve.
    export PATH="${TEST_DIR}/home/.riotbox/bin:${TEST_DIR}/realbin:/usr/bin:/bin"
}

# Install the generic agent-wrapper at $HOME/.riotbox/bin/opencode plus its
# runtime dependencies (find-real-bin.sh and the agents/ manifests). Used by
# the wrapper-behavior tests after setup_opencode_path_test has built the
# directory layout.
install_generic_opencode_wrapper() {
    : "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
    : "${TEST_DIR:?call setup_opencode_path_test before install_generic_opencode_wrapper}"
    cp "${RIOTBOX_DIR}/container/agent-wrapper.sh" \
       "${TEST_DIR}/home/.riotbox/bin/opencode"
    chmod +x "${TEST_DIR}/home/.riotbox/bin/opencode"
    cp "${RIOTBOX_DIR}/container/find-real-bin.sh" \
       "${TEST_DIR}/home/.riotbox/find-real-bin.sh"
    cp -r "${RIOTBOX_DIR}/agents/." \
          "${TEST_DIR}/home/.riotbox/agents/"
}

# Set up a fake HOME with a stub opencode config and data dir.
# Args: $1 — "withconfig" | "noconfig", $2 — "withauth" | "noauth"
# Sets: TEST_DIR, FAKE_HOME
setup_opencode_sync_test() {
    local config_mode="${1:-noconfig}"
    local auth_mode="${2:-noauth}"

    TEST_DIR="$(mktemp -d)"
    FAKE_HOME="${TEST_DIR}/home"
    mkdir -p "${FAKE_HOME}"

    if [ "${config_mode}" = "withconfig" ]; then
        mkdir -p "${FAKE_HOME}/.config/opencode/agents"
        printf '{"model": "anthropic/claude-sonnet-4-5"}\n' \
            > "${FAKE_HOME}/.config/opencode/opencode.json"
        printf '# Custom agent\n' \
            > "${FAKE_HOME}/.config/opencode/agents/myagent.md"
    fi

    if [ "${auth_mode}" = "withauth" ]; then
        mkdir -p "${FAKE_HOME}/.local/share/opencode"
        printf '{"anthropic": {"type": "api"}}\n' \
            > "${FAKE_HOME}/.local/share/opencode/auth.json"
    fi
}

# Set up a fake HOME with a riotbox layout for opencode-setup tests.
# Args: $1 — "preconfig" | "noconfig" (preconfig means a host opencode.json
#         was already synced into ~/.config/opencode/)
#       $2 — "withprompt" | "noprompt" (withprompt sets RIOTBOX_PROMPT)
# Sets: TEST_DIR, AGENTS_TARGET, OPENCODE_JSON, TEMPLATE_PATH
# Exports: HOME, RIOTBOX_PROMPT (if withprompt)
setup_opencode_setup_test() {
    local config_mode="${1:-noconfig}"
    local prompt_mode="${2:-noprompt}"

    TEST_DIR="$(mktemp -d)"
    export HOME="${TEST_DIR}/home"
    mkdir -p "${HOME}/.riotbox" "${HOME}/.config/opencode"

    # shellcheck disable=SC2034  # consumed by callers that source this helper
    TEMPLATE_PATH="${HOME}/.riotbox/AGENTS.md.template"
    # shellcheck disable=SC2034  # consumed by callers that source this helper
    AGENTS_TARGET="${HOME}/.config/opencode/AGENTS.md"
    # shellcheck disable=SC2034  # consumed by callers that source this helper
    OPENCODE_JSON="${HOME}/.config/opencode/opencode.json"

    # Image-baked template (build-time render of CLAUDE.md)
    cat > "${TEMPLATE_PATH}" <<'TEMPLATE'
You are in a riotbox running Linux.

This is the autonomy prompt.
TEMPLATE

    if [ "${config_mode}" = "preconfig" ]; then
        printf '{"model": "anthropic/claude-sonnet-4-5"}\n' > "${OPENCODE_JSON}"
    fi

    if [ "${prompt_mode}" = "withprompt" ]; then
        local override="${TEST_DIR}/override-prompt.md"
        printf 'Custom prompt content.\n' > "${override}"
        export RIOTBOX_PROMPT="${override}"
    else
        unset RIOTBOX_PROMPT
    fi
}
