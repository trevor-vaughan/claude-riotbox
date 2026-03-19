#!/usr/bin/env bash
# Shared helpers for CLI wrapper Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create a test environment with the wrapper installed and a mock task binary.
# The mock captures all args to a file for assertion via print_task_args.
# Sets: TEST_DIR, MOCK_TASK_ARGS
# Exports: PATH (prepends TEST_DIR/bin)
setup_wrapper_test() {
    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/projects/foo" "${TEST_DIR}/projects/bar"

    # Install the real wrapper
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}/bin" >/dev/null

    # Create mock task that captures args.
    # Unquoted heredoc (<<MOCK) so MOCK_TASK_ARGS is expanded at write time,
    # making the mock self-contained (no runtime env dependency).
    MOCK_TASK_ARGS="${TEST_DIR}/task-args"
    cat > "${TEST_DIR}/bin/task" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${MOCK_TASK_ARGS}"
MOCK
    chmod +x "${TEST_DIR}/bin/task"
    export MOCK_TASK_ARGS PATH="${TEST_DIR}/bin:${PATH}"
}

# Print captured task args to stdout (for Venom assertions).
print_task_args() {
    cat "${MOCK_TASK_ARGS}"
}
