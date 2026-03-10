#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Tests for install.sh
# ─────────────────────────────────────────────────────────────────────────────

setup() {
    export TEST_DIR="${BATS_TMPDIR}/install-test-$$"
    mkdir -p "${TEST_DIR}"
    # RIOTBOX_DIR is set by the test runner to the repo root
    export RIOTBOX_DIR="${RIOTBOX_DIR:-/home/testuser/riotbox}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

@test "install.sh creates the wrapper script" {
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    [ -f "${TEST_DIR}/claude-riotbox" ]
}

@test "install.sh makes the wrapper executable" {
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    [ -x "${TEST_DIR}/claude-riotbox" ]
}

@test "wrapper references the correct riotbox directory" {
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    grep -q "RIOTBOX_DIR=\"${RIOTBOX_DIR}\"" "${TEST_DIR}/claude-riotbox"
}

@test "wrapper routes path arguments to shell command" {
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    grep -q 'run_task shell -- "${cmd}" "$@"' "${TEST_DIR}/claude-riotbox"
}

@test "wrapper shows help when no args given" {
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    grep -q 'usage' "${TEST_DIR}/claude-riotbox"
    grep -q 'exit 0' "${TEST_DIR}/claude-riotbox"
}

@test "install.sh is idempotent" {
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    local first_hash
    first_hash="$(sha256sum "${TEST_DIR}/claude-riotbox" | awk '{print $1}')"

    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}"
    local second_hash
    second_hash="$(sha256sum "${TEST_DIR}/claude-riotbox" | awk '{print $1}')"

    [ "${first_hash}" = "${second_hash}" ]
}

@test "install.sh warns when target dir is not in PATH" {
    run "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}/not-in-path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not in your PATH"* ]]
}

@test "install.sh creates target directory if it doesn't exist" {
    local new_dir="${TEST_DIR}/nested/dir"
    "${RIOTBOX_DIR}/install.sh" "${new_dir}"
    [ -x "${new_dir}/claude-riotbox" ]
}
