#!/usr/bin/env bash
# Shared helpers for inject-claude-md Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create a test environment for inject-claude-md tests.
# Args:
#   $1 — prompt content (written to prompt.md)
# Sets: TEST_DIR, PROMPT_FILE, MANAGED_POLICY_MD
# Exports: RIOTBOX_PROMPT, RIOTBOX_MANAGED_POLICY_DIR, HOME
setup_inject_test() {
    local prompt_content="${1:-You are in a riotbox.}"
    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/managed-policy"
    PROMPT_FILE="${TEST_DIR}/prompt.md"
    echo "${prompt_content}" > "${PROMPT_FILE}"
    # Used by templates
    # shellcheck disable=SC2034
    MANAGED_POLICY_MD="${TEST_DIR}/managed-policy/CLAUDE.md"
    export RIOTBOX_PROMPT="${PROMPT_FILE}"
    export RIOTBOX_MANAGED_POLICY_DIR="${TEST_DIR}/managed-policy"
    export HOME="${TEST_DIR}"
}

# Run the inject script (sources it in current shell).
run_inject() {
    source "${RIOTBOX_DIR}/container/inject-claude-md.sh"
}
