#!/usr/bin/env bash
# Shared helpers for agent-registry Venom tests.
# Source this file at the top of each test script.
#
# All tests in tests/agents.venom.yml are contract tests against the
# registry — they iterate over AGENT_REGISTRY and verify that every agent
# satisfies the same interface. Adding an agent automatically extends
# coverage; no test edits required.
set -euo pipefail

# Resolve the riotbox source root from the caller's RIOTBOX_DIR variable.
# Source the registry — this exports AGENT_REGISTRY and agent_call.
source_agent_registry() {
    : "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
    # shellcheck source=/dev/null
    source "${RIOTBOX_DIR}/agents/registry.sh"
}

# Print "FAIL: <agent> <message>" on stderr and bump the global FAIL_COUNT.
# Used by the contract loops to accumulate failures rather than aborting on
# the first one — gives more useful output when adding a new agent.
agent_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: $*" >&2
}

# Initialise the failure counter. Call once at the top of each test.
agent_test_init() {
    # shellcheck disable=SC2034  # consumed by agent_fail and end-of-test check
    FAIL_COUNT=0
}

# Assert that all checks accumulated zero failures. Call at end of test.
# Echoes "OK" on success so venom assertions can match it.
agent_test_done() {
    if [ "${FAIL_COUNT:-0}" -eq 0 ]; then
        echo "OK"
    else
        echo "FAILED with ${FAIL_COUNT} error(s)" >&2
        return 1
    fi
}
