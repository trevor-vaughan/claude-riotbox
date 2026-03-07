#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Tests for the claude-riotbox CLI wrapper argument routing.
#
# Uses a mock `task` that records the arguments it receives, so we can
# verify the wrapper routes each command correctly without needing the
# container image or any real infrastructure.
# ─────────────────────────────────────────────────────────────────────────────

setup() {
    export RIOTBOX_DIR="${RIOTBOX_DIR:-/home/testuser/riotbox}"
    export TEST_DIR="${BATS_TMPDIR}/wrapper-test-$$"
    mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/projects/foo" "${TEST_DIR}/projects/bar"

    # Install the wrapper
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}/bin"

    # Create a mock task that records its args instead of executing
    cat > "${TEST_DIR}/bin/task" <<'MOCK'
#!/usr/bin/env bash
# Write all arguments to a file for inspection
printf '%s\n' "$@" > "${MOCK_TASK_ARGS}"
MOCK
    chmod +x "${TEST_DIR}/bin/task"

    export MOCK_TASK_ARGS="${TEST_DIR}/task-args"
    export PATH="${TEST_DIR}/bin:${PATH}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Helper: run the wrapper with given arguments and return the recorded task args
run_wrapper() {
    cd "${TEST_DIR}/projects"
    run "${TEST_DIR}/bin/claude-riotbox" "$@"
    [ "$status" -eq 0 ]
}

# Helper: read the recorded task args as an array
read_task_args() {
    mapfile -t TASK_ARGS < "${MOCK_TASK_ARGS}"
}

# ─────────────────────────────────────────────────────────────────────────────
# No arguments → shell in CWD
# ─────────────────────────────────────────────────────────────────────────────

@test "no args → shell in CWD" {
    run_wrapper
    read_task_args
    [[ "${TASK_ARGS[0]}" == --taskfile* ]] || [[ "${TASK_ARGS[0]}" == "--taskfile" ]]
    # Find the task name in the args
    local found=false
    for arg in "${TASK_ARGS[@]}"; do
        if [ "$arg" = "shell" ]; then found=true; fi
    done
    [ "$found" = true ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Path arguments → shell with projects
# ─────────────────────────────────────────────────────────────────────────────

@test "single path → shell with that path" {
    run_wrapper "${TEST_DIR}/projects/foo"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"shell"* ]]
    [[ "$args_str" == *"${TEST_DIR}/projects/foo"* ]]
}

@test "multiple paths → shell with all paths" {
    run_wrapper "${TEST_DIR}/projects/foo" "${TEST_DIR}/projects/bar"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"shell"* ]]
    [[ "$args_str" == *"${TEST_DIR}/projects/foo"* ]]
    [[ "$args_str" == *"${TEST_DIR}/projects/bar"* ]]
}

@test "dot path → shell with dot" {
    run_wrapper .
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"shell"* ]]
    [[ "$args_str" == *"."* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Explicit shell command
# ─────────────────────────────────────────────────────────────────────────────

@test "shell with no projects → shell in CWD" {
    run_wrapper shell
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"shell"* ]]
    [[ "$args_str" == *"."* ]]
}

@test "shell with project → shell with that project" {
    run_wrapper shell "${TEST_DIR}/projects/foo"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"shell"* ]]
    [[ "$args_str" == *"${TEST_DIR}/projects/foo"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# run command
# ─────────────────────────────────────────────────────────────────────────────

@test "run routes prompt and projects" {
    run_wrapper run "implement the feature" "${TEST_DIR}/projects/foo"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"run"* ]]
    [[ "$args_str" == *"implement the feature"* ]]
    [[ "$args_str" == *"${TEST_DIR}/projects/foo"* ]]
}

@test "run with prompt only (no projects)" {
    run_wrapper run "do something"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"run"* ]]
    [[ "$args_str" == *"do something"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# resume command
# ─────────────────────────────────────────────────────────────────────────────

@test "resume with no projects → resume in CWD" {
    run_wrapper resume
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"resume"* ]]
    [[ "$args_str" == *"."* ]]
}

@test "resume with project" {
    run_wrapper resume "${TEST_DIR}/projects/foo"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"resume"* ]]
    [[ "$args_str" == *"${TEST_DIR}/projects/foo"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# reown command
# ─────────────────────────────────────────────────────────────────────────────

@test "reown with no flags" {
    run_wrapper reown
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"reown"* ]]
}

@test "reown with --force flag" {
    run_wrapper reown --force
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"reown"* ]]
    [[ "$args_str" == *"--force"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Pass-through commands (build, test, clean, etc.)
# ─────────────────────────────────────────────────────────────────────────────

@test "build passes through to task" {
    run_wrapper build
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"build"* ]]
}

@test "test passes through to task" {
    run_wrapper test
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"test"* ]]
}

@test "clean passes through to task" {
    run_wrapper clean
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"clean"* ]]
}

@test "namespaced task passes through" {
    run_wrapper session:audit -- "review this"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"session:audit"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Edge cases
# ─────────────────────────────────────────────────────────────────────────────

@test "non-existent path is not treated as a project" {
    run_wrapper "/nonexistent/path"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    # Should pass through to task, not route to shell
    [[ "$args_str" != *"shell"* ]]
    [[ "$args_str" == *"/nonexistent/path"* ]]
}

@test "mix of path and non-path is not treated as all-paths" {
    run_wrapper "${TEST_DIR}/projects/foo" "not-a-path"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    # First arg looks like a task name to task, not routed to shell
    [[ "$args_str" != *"shell"* ]]
}

@test "-- separator is passed through for advanced usage" {
    run_wrapper session:nested-run -- "do something" "${TEST_DIR}/projects/foo"
    read_task_args
    local args_str="${TASK_ARGS[*]}"
    [[ "$args_str" == *"session:nested-run"* ]]
    [[ "$args_str" == *"--"* ]]
    [[ "$args_str" == *"do something"* ]]
}
