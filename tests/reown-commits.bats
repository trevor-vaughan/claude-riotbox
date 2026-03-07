#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Tests for scripts/reown-commits.sh
#
# Each test creates a temporary git repo (with a bare remote) in BATS_TMPDIR,
# populates it with a mix of "claude" and "human" commits, then exercises the
# reown script and verifies the results.
# ─────────────────────────────────────────────────────────────────────────────

# ── Helpers ──────────────────────────────────────────────────────────────────

# Set up a fresh git repo with a bare "origin" remote.
setup() {
    export TEST_DIR="${BATS_TMPDIR}/reown-test-$$"
    mkdir -p "${TEST_DIR}"

    export RIOTBOX_DIR="${RIOTBOX_DIR:-/home/testuser/riotbox}"
    export REOWN="${RIOTBOX_DIR}/scripts/reown-commits.sh"

    # Human identity (what reown should rewrite TO)
    export HUMAN_NAME="Test Human"
    export HUMAN_EMAIL="human@example.com"

    # Claude identity (what reown should rewrite FROM)
    export CLAUDE_NAME="Claude"
    export CLAUDE_EMAIL="claude@riotbox"

    # Create bare remote
    export BARE_DIR="${TEST_DIR}/remote.git"
    git init --bare --initial-branch=main "${BARE_DIR}" >/dev/null 2>&1

    # Create working repo
    export REPO_DIR="${TEST_DIR}/project"
    git init --initial-branch=main "${REPO_DIR}" >/dev/null 2>&1
    cd "${REPO_DIR}"

    git config user.name "${HUMAN_NAME}"
    git config user.email "${HUMAN_EMAIL}"
    git config init.defaultBranch main
    git remote add origin "${BARE_DIR}"

    # Isolate from the host's global git config (commit.gpgsign, signingkey,
    # core.hooksPath, etc.) so tests don't depend on the machine they run on.
    export GIT_CONFIG_GLOBAL="${TEST_DIR}/isolated.gitconfig"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Commit as the human identity.
human_commit() {
    local msg="${1}"
    echo "${msg}" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${HUMAN_NAME}" \
    GIT_AUTHOR_EMAIL="${HUMAN_EMAIL}" \
    GIT_COMMITTER_NAME="${HUMAN_NAME}" \
    GIT_COMMITTER_EMAIL="${HUMAN_EMAIL}" \
        git commit -m "${msg}" --allow-empty-message >/dev/null
}

# Commit as the claude identity.
claude_commit() {
    local msg="${1}"
    echo "${msg}" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${CLAUDE_NAME}" \
    GIT_AUTHOR_EMAIL="${CLAUDE_EMAIL}" \
    GIT_COMMITTER_NAME="${CLAUDE_NAME}" \
    GIT_COMMITTER_EMAIL="${CLAUDE_EMAIL}" \
        git commit -m "${msg}" --allow-empty-message >/dev/null
}

# Count commits authored by a given email in the specified range.
count_by_author() {
    local email="${1}"
    shift
    git log "$@" --author="${email}" --format='%H' | wc -l | tr -d ' '
}

# ── Happy path ───────────────────────────────────────────────────────────────

@test "reown rewrites claude-authored commits to human identity" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "feature A"
    claude_commit "feature B"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]

    # All commits should now be human-authored
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
    [ "$(count_by_author "${HUMAN_EMAIL}")" -eq 4 ]
}

@test "reown preserves non-claude commits unchanged" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    human_commit "human work"
    claude_commit "claude work"

    "${REOWN}" --force

    # Verify commit messages are preserved in order
    local msgs
    msgs="$(git log --format='%s' --reverse)"
    echo "${msgs}" | grep -qx "initial"
    echo "${msgs}" | grep -qx "checkpoint: pre-claude"
    echo "${msgs}" | grep -qx "human work"
    echo "${msgs}" | grep -qx "claude work"
}

@test "reown preserves Co-Authored-By trailers" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"

    echo "trailer test" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${CLAUDE_NAME}" \
    GIT_AUTHOR_EMAIL="${CLAUDE_EMAIL}" \
    GIT_COMMITTER_NAME="${CLAUDE_NAME}" \
    GIT_COMMITTER_EMAIL="${CLAUDE_EMAIL}" \
        git commit -m "feature with trailer

Co-Authored-By: Claude <noreply@anthropic.com>" >/dev/null

    "${REOWN}" --force

    git log -1 --format='%B' | grep -q "Co-Authored-By: Claude <noreply@anthropic.com>"
}

# ── Range modes ──────────────────────────────────────────────────────────────

@test "reown with ref reports correct range in output" {
    human_commit "initial"
    claude_commit "old claude work"
    local ref
    ref="$(git rev-parse HEAD)"

    claude_commit "new claude work"
    claude_commit "newest claude work"

    run "${REOWN}" --force "${ref}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"commits since ${ref}"* ]]

    # filter-repo rewrites all matching authors on the branch,
    # so all claude commits become human-authored
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
}

@test "reown --all rewrites all claude commits on current branch" {
    claude_commit "root claude commit"
    human_commit "human commit"
    claude_commit "later claude commit"

    "${REOWN}" --force --all

    [ "$(count_by_author "${CLAUDE_EMAIL}" main)" -eq 0 ]
    [ "$(count_by_author "${HUMAN_EMAIL}" main)" -eq 3 ]
}

@test "reown auto-detects checkpoint commit" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "claude work after checkpoint"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"checkpoint"* ]]
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
}

@test "reown errors when no checkpoint and no ref given" {
    human_commit "initial"
    claude_commit "some work"

    run "${REOWN}" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"No checkpoint commit found"* ]]
}

# ── Backup tags ──────────────────────────────────────────────────────────────

@test "reown creates a backup tag before rewriting" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    local pre_rewrite_head
    pre_rewrite_head="$(git rev-parse HEAD)"

    "${REOWN}" --force

    # A backup tag should exist under backup/pre-reown-*
    local backup_tag
    backup_tag="$(git tag -l 'backup/pre-reown-*' | head -1)"
    [ -n "${backup_tag}" ]

    # The backup tag should point to the pre-rewrite HEAD
    [ "$(git rev-parse "${backup_tag}")" = "${pre_rewrite_head}" ]
}

@test "reown backup allows full restore via git reset" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    local pre_rewrite_head
    pre_rewrite_head="$(git rev-parse HEAD)"

    "${REOWN}" --force

    local backup_tag
    backup_tag="$(git tag -l 'backup/pre-reown-*' | head -1)"

    git reset --hard "${backup_tag}"
    [ "$(git rev-parse HEAD)" = "${pre_rewrite_head}" ]
    # Claude commit should be back
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 1 ]
}

@test "reown --all only rewrites current branch" {
    human_commit "main initial"
    claude_commit "main claude"
    local branch_point
    branch_point="$(git rev-parse HEAD)"

    git checkout -b feature >/dev/null 2>&1
    claude_commit "feature claude"
    git checkout main >/dev/null 2>&1

    "${REOWN}" --force --all

    # main branch should be rewritten
    [ "$(count_by_author "${CLAUDE_EMAIL}" main)" -eq 0 ]
    # feature branch tip should still be claude-authored (untouched)
    [ "$(git log -1 feature --format='%ae')" = "${CLAUDE_EMAIL}" ]
}

# ── Remote preservation ──────────────────────────────────────────────────────

@test "reown preserves the origin remote URL" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"
    git push origin main >/dev/null 2>&1

    "${REOWN}" --force

    local remote_url
    remote_url="$(git remote get-url origin)"
    [ "${remote_url}" = "${BARE_DIR}" ]
}

@test "reown preserves multiple remotes" {
    local second_bare="${TEST_DIR}/upstream.git"
    git init --bare "${second_bare}" >/dev/null 2>&1
    git remote add upstream "${second_bare}"

    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    "${REOWN}" --force

    [ "$(git remote get-url origin)" = "${BARE_DIR}" ]
    [ "$(git remote get-url upstream)" = "${second_bare}" ]
}

# ── Edge cases ───────────────────────────────────────────────────────────────

@test "reown exits cleanly when no claude commits in range" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    human_commit "all human"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Claude-authored commits found"* ]]
}

@test "reown errors on invalid ref" {
    human_commit "initial"

    run "${REOWN}" --force "nonexistent-ref"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a valid git ref"* ]]
}

@test "reown errors on unknown flags" {
    human_commit "initial"

    run "${REOWN}" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "reown errors in detached HEAD state" {
    human_commit "initial"
    human_commit "second"
    git checkout HEAD~1 >/dev/null 2>&1

    run "${REOWN}" --force --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"detached HEAD"* ]]
}

@test "reown handles interleaved claude and human commits" {
    human_commit "checkpoint: pre-claude"
    claude_commit "claude 1"
    human_commit "human 1"
    claude_commit "claude 2"
    human_commit "human 2"
    claude_commit "claude 3"

    "${REOWN}" --force

    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
    # All 6 commits (checkpoint + 5) should be human-authored
    [ "$(count_by_author "${HUMAN_EMAIL}")" -eq 6 ]

    # Verify file content is preserved (each commit appended a line)
    [ "$(wc -l < history.txt | tr -d ' ')" -eq 6 ]
}

@test "reown works when all commits are claude-authored (--all)" {
    claude_commit "first"
    claude_commit "second"
    claude_commit "third"

    "${REOWN}" --force --all

    [ "$(count_by_author "${CLAUDE_EMAIL}" main)" -eq 0 ]
    [ "$(count_by_author "${HUMAN_EMAIL}" main)" -eq 3 ]
}

@test "reown with --force skips confirmation" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    # --force should not hang waiting for input
    run timeout 10 "${REOWN}" --force
    [ "$status" -eq 0 ]
}

@test "reown without --force prompts and aborts on N" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    run bash -c 'echo "n" | "${REOWN}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aborted"* ]]

    # Commit should still be claude-authored
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 1 ]
}

# ── GPG signing (Pass 2) ─────────────────────────────────────────────────────

# Generate a throwaway GPG key for signing tests.
# Sets GNUPGHOME and returns the key fingerprint.
# IMPORTANT: GNUPGHOME must be exported BEFORE calling this in a subshell,
# because exports inside $() don't propagate to the parent.
generate_test_gpg_key() {
    mkdir -p "${GNUPGHOME}"
    chmod 700 "${GNUPGHOME}"

    gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "Test User <${HUMAN_EMAIL}>" default default never \
        2>/dev/null

    gpg --list-keys --with-colons "${HUMAN_EMAIL}" 2>/dev/null \
        | awk -F: '/^fpr:/ { print $10; exit }'
}

@test "reown re-signs commits when commit.gpgsign is enabled" {
    command -v gpg &>/dev/null || skip "gpg not installed"

    local key_fp
    export GNUPGHOME="${TEST_DIR}/gnupg"
    key_fp="$(generate_test_gpg_key)"
    [ -n "${key_fp}" ] || skip "failed to generate GPG key"

    # Create commits BEFORE enabling signing
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "unsigned claude work"

    # Enable signing — only the reown script should use it
    git config user.signingkey "${key_fp}"
    git config commit.gpgsign true
    git config gpg.program gpg

    "${REOWN}" --force

    # The rewritten commit should have a GPG signature
    local sig_status
    sig_status="$(git log -1 --format='%G?')"
    [ "${sig_status}" != "N" ]
}

@test "reown re-signing preserves author dates" {
    command -v gpg &>/dev/null || skip "gpg not installed"

    local key_fp
    export GNUPGHOME="${TEST_DIR}/gnupg"
    key_fp="$(generate_test_gpg_key)"
    [ -n "${key_fp}" ] || skip "failed to generate GPG key"

    # Create commits BEFORE enabling signing
    human_commit "initial"
    human_commit "checkpoint: pre-claude"

    # Commit with a distinctive date
    echo "dated work" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${CLAUDE_NAME}" GIT_AUTHOR_EMAIL="${CLAUDE_EMAIL}" \
    GIT_COMMITTER_NAME="${CLAUDE_NAME}" GIT_COMMITTER_EMAIL="${CLAUDE_EMAIL}" \
    GIT_AUTHOR_DATE="2025-01-15T12:00:00" \
    GIT_COMMITTER_DATE="2025-01-15T12:00:00" \
        git commit -m "dated claude work" >/dev/null

    local original_date
    original_date="$(git log -1 --format='%ai')"

    # Enable signing — only the reown script should use it
    git config user.signingkey "${key_fp}"
    git config commit.gpgsign true
    git config gpg.program gpg

    "${REOWN}" --force

    local rewritten_date
    rewritten_date="$(git log -1 --format='%ai')"
    [ "${original_date}" = "${rewritten_date}" ]
}

@test "reown skips signing when commit.gpgsign is false" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    git config commit.gpgsign false

    run "${REOWN}" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"GPG signing not enabled"* ]]
}

@test "reown errors when gpgsign is true but no signingkey configured" {
    command -v gpg &>/dev/null || skip "gpg not installed"

    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "work"

    git config --global commit.gpgsign true
    # Deliberately do NOT set user.signingkey

    run "${REOWN}" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"no user.signingkey is configured"* ]]
}

# ── Content integrity ────────────────────────────────────────────────────────

@test "reown diff between backup and rewritten branch shows no content changes" {
    human_commit "initial"
    human_commit "checkpoint: pre-claude"
    claude_commit "feature work"
    echo "extra content" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${CLAUDE_NAME}" GIT_AUTHOR_EMAIL="${CLAUDE_EMAIL}" \
    GIT_COMMITTER_NAME="${CLAUDE_NAME}" GIT_COMMITTER_EMAIL="${CLAUDE_EMAIL}" \
        git commit -m "more feature work" >/dev/null

    "${REOWN}" --force

    local backup_tag
    backup_tag="$(git tag -l 'backup/pre-reown-*' | head -1)"

    # Tree content should be identical — only metadata changed
    local diff_output
    diff_output="$(git diff "${backup_tag}..HEAD" 2>&1)"
    [ -z "${diff_output}" ]
}
