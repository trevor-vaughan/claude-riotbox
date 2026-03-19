#!/usr/bin/env bash
# Shared helpers for inject-claude-md Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create a test environment for inject-claude-md tests.
# Args:
#   $1 — prompt content (written to prompt.md)
# Sets: TEST_DIR, PROMPT_FILE, CLAUDE_MD
# Exports: CLAUDE_CONFIG_DIR, RIOTBOX_PROMPT, HOME
setup_inject_test() {
    local prompt_content="${1:-You are in a riotbox.}"
    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/config"
    PROMPT_FILE="${TEST_DIR}/prompt.md"
    echo "${prompt_content}" > "${PROMPT_FILE}"
    CLAUDE_MD="${TEST_DIR}/config/CLAUDE.md"
    export CLAUDE_CONFIG_DIR="${TEST_DIR}/config"
    export RIOTBOX_PROMPT="${PROMPT_FILE}"
    export HOME="${TEST_DIR}"
}

# Run the inject script (sources it in current shell).
run_inject() {
    source "${RIOTBOX_DIR}/container/inject-claude-md.sh"
}
