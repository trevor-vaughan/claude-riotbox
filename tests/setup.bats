#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Tests for setup.sh
# Uses a fake HOME to isolate config file creation from the real system.
# ─────────────────────────────────────────────────────────────────────────────

setup() {
    export FAKE_HOME="${BATS_TMPDIR}/setup-test-$$-${BATS_TEST_NUMBER}"
    mkdir -p "${FAKE_HOME}/bin"
    export REAL_HOME="${HOME}"
    export HOME="${FAKE_HOME}"
    export RIOTBOX_DIR="${RIOTBOX_DIR:-/home/testuser/riotbox}"
    # Ensure no stale auth leaks between tests
    unset ANTHROPIC_API_KEY 2>/dev/null || true
}

teardown() {
    export HOME="${REAL_HOME}"
    rm -rf "${FAKE_HOME}"
}

# Helper: run setup.sh non-interactively, skip build
run_setup() {
    run "${RIOTBOX_DIR}/setup.sh" --yes --no-build "$@"
}

# ── Detection tests ──────────────────────────────────────────────────────────

@test "setup.sh detects podman" {
    run_setup
    [[ "$output" == *"[ok]"*"podman"* ]]
}

@test "setup.sh detects just" {
    run_setup
    [[ "$output" == *"[ok]"*"just"* ]]
}

@test "setup.sh detects fuse-overlayfs" {
    run_setup
    [[ "$output" == *"[ok]"*"fuse-overlayfs"* ]]
}

@test "setup.sh warns about missing auth" {
    run_setup
    [[ "$output" == *"No authentication found"* ]]
}

@test "setup.sh detects ANTHROPIC_API_KEY" {
    export ANTHROPIC_API_KEY="sk-test-fake-key"
    run_setup
    [[ "$output" == *"[ok]"*"ANTHROPIC_API_KEY"* ]]
}

@test "setup.sh detects OAuth tokens" {
    echo '{"token": "fake"}' > "${HOME}/.claude.json"
    run_setup
    [[ "$output" == *"[ok]"*"OAuth tokens"* ]]
}

# ── Config creation tests ────────────────────────────────────────────────────

@test "setup.sh creates storage.conf" {
    run_setup
    [ -f "${HOME}/.config/containers/storage.conf" ]
    grep -q 'fuse-overlayfs' "${HOME}/.config/containers/storage.conf"
}

@test "storage.conf has correct structure" {
    run_setup
    local conf="${HOME}/.config/containers/storage.conf"
    grep -q '^\[storage\]' "${conf}"
    grep -q 'driver = "overlay"' "${conf}"
    grep -q '^\[storage.options.overlay\]' "${conf}"
    grep -q 'mount_program = "/usr/bin/fuse-overlayfs"' "${conf}"
}

@test "setup.sh creates containers.conf" {
    run_setup
    [ -f "${HOME}/.config/containers/containers.conf" ]
    grep -q 'init = false' "${HOME}/.config/containers/containers.conf"
}

@test "setup.sh skips storage.conf if already correct" {
    mkdir -p "${HOME}/.config/containers"
    cat > "${HOME}/.config/containers/storage.conf" <<'TOML'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "metacopy=on"
TOML
    run_setup
    [[ "$output" == *"storage.conf already configured"* ]]
}

@test "setup.sh skips containers.conf if already correct" {
    mkdir -p "${HOME}/.config/containers"
    cat > "${HOME}/.config/containers/containers.conf" <<'TOML'
[containers]
init = false
TOML
    run_setup
    [[ "$output" == *"containers.conf already disables catatonit"* ]]
}

# ── Install tests ────────────────────────────────────────────────────────────

@test "setup.sh installs the CLI wrapper" {
    run_setup
    [ -x "${HOME}/bin/claude-riotbox" ]
}

@test "setup.sh wrapper references correct justfile" {
    run_setup
    grep -q "${RIOTBOX_DIR}/justfile" "${HOME}/bin/claude-riotbox"
}

@test "setup.sh skips CLI install if already present" {
    # First run installs it
    run_setup
    [ -x "${HOME}/bin/claude-riotbox" ]

    # Second run detects it
    run_setup
    [[ "$output" == *"claude-riotbox already installed"* ]]
}

# ── Idempotency tests ───────────────────────────────────────────────────────

@test "setup.sh is idempotent (two runs produce same config)" {
    run_setup
    local storage_hash containers_hash
    storage_hash="$(sha256sum "${HOME}/.config/containers/storage.conf" | awk '{print $1}')"
    containers_hash="$(sha256sum "${HOME}/.config/containers/containers.conf" | awk '{print $1}')"

    run_setup
    local storage_hash2 containers_hash2
    storage_hash2="$(sha256sum "${HOME}/.config/containers/storage.conf" | awk '{print $1}')"
    containers_hash2="$(sha256sum "${HOME}/.config/containers/containers.conf" | awk '{print $1}')"

    [ "${storage_hash}" = "${storage_hash2}" ]
    [ "${containers_hash}" = "${containers_hash2}" ]
}

# ── Build skip tests ────────────────────────────────────────────────────────

@test "setup.sh exits cleanly with --no-build" {
    export ANTHROPIC_API_KEY="sk-test-fake-key"
    run_setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipped (--no-build)"* ]]
}

# ── --yes mode tests ────────────────────────────────────────────────────────

@test "--yes does not auto-approve podman system reset" {
    run_setup
    [[ "$output" != *"Podman storage reset complete"* ]]
}

@test "--yes disables color codes" {
    run_setup
    # Output should not contain ANSI escape sequences
    ! echo "$output" | grep -qP '\033\['
}

# ── Exit code tests ─────────────────────────────────────────────────────────

@test "setup.sh exits 0 when everything is available" {
    export ANTHROPIC_API_KEY="sk-test-fake-key"
    run_setup
    [ "$status" -eq 0 ]
}

@test "setup.sh exits 0 with warnings (missing auth is a warning, not error)" {
    run_setup
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning(s)"* ]]
}
