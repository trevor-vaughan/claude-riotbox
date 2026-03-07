#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Tests for inject-claude-md.sh
#
# Verifies the CLAUDE.md injection logic: creation, idempotent replacement,
# preservation of non-riotbox content, and prompt file resolution.
# ─────────────────────────────────────────────────────────────────────────────

setup() {
    export TEST_DIR="${BATS_TMPDIR}/inject-test-$$-${BATS_TEST_NUMBER}"
    mkdir -p "${TEST_DIR}/config" "${TEST_DIR}/riotbox"
    export CLAUDE_CONFIG_DIR="${TEST_DIR}/config"
    export HOME="${TEST_DIR}"
    export RIOTBOX_DIR="${RIOTBOX_DIR:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}"

    # Default prompt content
    echo "You are in a riotbox." > "${TEST_DIR}/prompt.md"
    export RIOTBOX_PROMPT="${TEST_DIR}/prompt.md"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Helper: run the injection script
run_inject() {
    source "${RIOTBOX_DIR}/container/inject-claude-md.sh"
}

# ── Creation ────────────────────────────────────────────────────────────────

@test "creates CLAUDE.md when it does not exist" {
    run_inject
    [ -f "${CLAUDE_CONFIG_DIR}/CLAUDE.md" ]
}

@test "created file contains the prompt content" {
    run_inject
    grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "created file has begin and end markers" {
    run_inject
    grep -qF "<!-- BEGIN RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "<!-- END RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

# ── Idempotency ─────────────────────────────────────────────────────────────

@test "running twice produces exactly one riotbox block" {
    run_inject
    run_inject
    local count
    count=$(grep -cF "<!-- BEGIN RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md")
    [ "$count" -eq 1 ]
}

@test "running twice produces the same content" {
    run_inject
    local first
    first="$(cat "${CLAUDE_CONFIG_DIR}/CLAUDE.md")"

    run_inject
    local second
    second="$(cat "${CLAUDE_CONFIG_DIR}/CLAUDE.md")"

    [ "$first" = "$second" ]
}

# ── Replacement ─────────────────────────────────────────────────────────────

@test "updates riotbox block when prompt content changes" {
    run_inject

    echo "Updated prompt." > "${TEST_DIR}/prompt.md"
    run_inject

    grep -qF "Updated prompt." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    ! grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "old prompt content is fully removed after update" {
    echo -e "Line one.\nLine two.\nLine three." > "${TEST_DIR}/prompt.md"
    run_inject

    echo "Replacement." > "${TEST_DIR}/prompt.md"
    run_inject

    ! grep -qF "Line one." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    ! grep -qF "Line two." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    ! grep -qF "Line three." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "Replacement." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

# ── Preservation of existing content ────────────────────────────────────────

@test "preserves content before the riotbox block" {
    echo "# My Project Notes" > "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    run_inject

    grep -qF "# My Project Notes" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "preserves content after the riotbox block on re-inject" {
    # Create file with riotbox block in the middle and user content after
    cat > "${CLAUDE_CONFIG_DIR}/CLAUDE.md" <<'EOF'
# Project header

<!-- BEGIN RIOTBOX -->
Old prompt.
<!-- END RIOTBOX -->

# User notes
Remember to use pytest.
EOF
    run_inject

    grep -qF "# Project header" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "# User notes" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "Remember to use pytest." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    ! grep -qF "Old prompt." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "preserves content both before and after the block" {
    cat > "${CLAUDE_CONFIG_DIR}/CLAUDE.md" <<'EOF'
# Before

<!-- BEGIN RIOTBOX -->
Original.
<!-- END RIOTBOX -->

# After
EOF
    run_inject

    # Verify ordering: before content, then after content, then riotbox block
    grep -qF "# Before" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "# After" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

# ── Prompt file resolution ──────────────────────────────────────────────────

@test "resolves user override prompt from ~/.riotbox/" {
    unset RIOTBOX_PROMPT
    mkdir -p "${HOME}/.riotbox"
    echo "User override." > "${HOME}/.riotbox/CLAUDE.md"

    run_inject
    grep -qF "User override." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "resolves system default prompt from /etc/riotbox/" {
    # This test only works if /etc/riotbox/CLAUDE.md exists (in-container)
    if [ ! -f /etc/riotbox/CLAUDE.md ]; then
        skip "not running inside the riotbox container"
    fi
    unset RIOTBOX_PROMPT
    run_inject
    grep -qF "<!-- BEGIN RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "does nothing when no prompt file is available" {
    unset RIOTBOX_PROMPT
    # Override HOME to a dir without .riotbox/ so fallback resolution finds nothing.
    # /etc/riotbox/CLAUDE.md may exist in the container, so hide it too.
    local saved_home="${HOME}"
    local saved_etc="/etc/riotbox/CLAUDE.md"
    HOME="${TEST_DIR}/empty-home"
    mkdir -p "${HOME}"
    if [ -f "${saved_etc}" ]; then
        sudo mv "${saved_etc}" "${saved_etc}.bak"
    fi
    run_inject
    if [ -f "${saved_etc}.bak" ]; then
        sudo mv "${saved_etc}.bak" "${saved_etc}"
    fi
    HOME="${saved_home}"
    [ ! -f "${CLAUDE_CONFIG_DIR}/CLAUDE.md" ]
}

# ── Edge cases ──────────────────────────────────────────────────────────────

@test "handles empty existing CLAUDE.md" {
    touch "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    run_inject
    grep -qF "<!-- BEGIN RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "handles multi-line prompt content" {
    cat > "${TEST_DIR}/prompt.md" <<'EOF'
First line.
Second line.
Third line.
EOF
    run_inject

    grep -qF "First line." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "Second line." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    grep -qF "Third line." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}

@test "markers are not duplicated across multiple runs with changing content" {
    run_inject

    echo "V2." > "${TEST_DIR}/prompt.md"
    run_inject

    echo "V3." > "${TEST_DIR}/prompt.md"
    run_inject

    local begin_count end_count
    begin_count=$(grep -cF "<!-- BEGIN RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md")
    end_count=$(grep -cF "<!-- END RIOTBOX -->" "${CLAUDE_CONFIG_DIR}/CLAUDE.md")
    [ "$begin_count" -eq 1 ]
    [ "$end_count" -eq 1 ]
    grep -qF "V3." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    ! grep -qF "V2." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
    ! grep -qF "You are in a riotbox." "${CLAUDE_CONFIG_DIR}/CLAUDE.md"
}
