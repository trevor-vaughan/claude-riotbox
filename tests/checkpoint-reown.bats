#!/usr/bin/env bats
# ─────────────────────────────────────────────────────────────────────────────
# Integration tests for the checkpoint → Claude runs → reown workflow.
#
# These tests validate the full pipeline:
#   1. run.sh creates a checkpoint commit + tag + backup before launching Claude
#   2. "Claude" makes commits inside the container (simulated here)
#   3. reown-commits.sh finds the checkpoint and rewrites Claude's commits
#
# The do_checkpoint() helper mirrors run.sh's checkpoint logic exactly, so
# these tests will catch any divergence between the two scripts.
# ─────────────────────────────────────────────────────────────────────────────

setup() {
    export TEST_DIR="${BATS_TMPDIR}/checkpoint-reown-test-$$-${BATS_TEST_NUMBER}"
    mkdir -p "${TEST_DIR}"

    export RIOTBOX_DIR="${RIOTBOX_DIR:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}"
    export REOWN="${RIOTBOX_DIR}/scripts/reown-commits.sh"

    export HUMAN_NAME="Test Human"
    export HUMAN_EMAIL="human@example.com"
    export CLAUDE_NAME="Claude"
    export CLAUDE_EMAIL="claude@riotbox"

    export REPO_DIR="${TEST_DIR}/project"
    git init --initial-branch=main "${REPO_DIR}" >/dev/null 2>&1
    cd "${REPO_DIR}"
    git config user.name "${HUMAN_NAME}"
    git config user.email "${HUMAN_EMAIL}"

    # Backup directory — mirrors ~/.claude-riotbox/backups/
    export BACKUP_BASE="${TEST_DIR}/backups"
    mkdir -p "${BACKUP_BASE}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

human_commit() {
    local msg="${1}"
    echo "${msg}" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${HUMAN_NAME}" GIT_AUTHOR_EMAIL="${HUMAN_EMAIL}" \
    GIT_COMMITTER_NAME="${HUMAN_NAME}" GIT_COMMITTER_EMAIL="${HUMAN_EMAIL}" \
        git commit -m "${msg}" >/dev/null
}

claude_commit() {
    local msg="${1}"
    echo "${msg}" >> history.txt
    git add -A
    GIT_AUTHOR_NAME="${CLAUDE_NAME}" GIT_AUTHOR_EMAIL="${CLAUDE_EMAIL}" \
    GIT_COMMITTER_NAME="${CLAUDE_NAME}" GIT_COMMITTER_EMAIL="${CLAUDE_EMAIL}" \
        git commit -m "${msg}" >/dev/null
}

count_by_author() {
    local email="${1}"
    shift
    git log "$@" --author="${email}" --format='%H' | wc -l | tr -d ' '
}

# Counter to ensure unique timestamps when do_checkpoint is called multiple
# times within a single second (common in fast tests).
_checkpoint_seq=0

# Mirrors run.sh's checkpoint logic. Sets CHECKPOINT_TAG to the tag created.
# This helper must stay in sync with .taskfiles/scripts/run.sh.
do_checkpoint() {
    local dir="${1:-${REPO_DIR}}"
    _checkpoint_seq=$((_checkpoint_seq + 1))
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)-${_checkpoint_seq}"
    local project_name
    project_name="$(basename "${dir}")"

    if ! git -C "${dir}" diff --quiet 2>/dev/null || \
       ! git -C "${dir}" diff --cached --quiet 2>/dev/null; then
        git -C "${dir}" add -A
    fi
    git -C "${dir}" -c "user.name=${HUMAN_NAME}" -c "user.email=${HUMAN_EMAIL}" \
        commit --allow-empty -m "checkpoint: pre-claude-${timestamp}" >/dev/null

    CHECKPOINT_TAG="claude-checkpoint/${timestamp}"
    git -C "${dir}" tag "${CHECKPOINT_TAG}"

    local backup_dir="${BACKUP_BASE}/${project_name}.git"
    if [ ! -d "${backup_dir}" ]; then
        git clone --bare "${dir}" "${backup_dir}" >/dev/null 2>&1
    else
        git -C "${dir}" push --no-verify --force "${backup_dir}" --all >/dev/null 2>&1
        git -C "${dir}" push --no-verify --force "${backup_dir}" --tags >/dev/null 2>&1
    fi
}

# ── Checkpoint creation ───────────────────────────────────────────────────────

@test "checkpoint commit is created when repo has uncommitted changes" {
    human_commit "initial"
    echo "dirty work" >> dirty.txt

    do_checkpoint

    git log --format='%s' | grep -q "^checkpoint: pre-claude-"
}

@test "checkpoint commit is created when repo is clean (no uncommitted changes)" {
    human_commit "initial"
    # Repo is clean — this is the case that was previously broken

    do_checkpoint

    git log --format='%s' | grep -q "^checkpoint: pre-claude-"
}

@test "checkpoint commit stages and includes dirty tracked files" {
    human_commit "initial"
    # Modify an already-tracked file (untracked files don't affect git diff --quiet)
    echo "additional content" >> history.txt

    do_checkpoint

    git show HEAD -- history.txt | grep -q "additional content"
}

@test "checkpoint commit is authored by the human identity" {
    human_commit "initial"
    do_checkpoint

    local author
    author="$(git log --grep='checkpoint: pre-claude' -1 --format='%ae')"
    [ "${author}" = "${HUMAN_EMAIL}" ]
}

@test "checkpoint creates claude-checkpoint tag pointing to HEAD" {
    human_commit "initial"
    do_checkpoint

    local tag_ref head_ref
    tag_ref="$(git rev-parse "${CHECKPOINT_TAG}")"
    head_ref="$(git rev-parse HEAD)"
    [ "${tag_ref}" = "${head_ref}" ]
}

@test "checkpoint pushes to a bare backup repo" {
    human_commit "initial"
    do_checkpoint

    local backup_dir="${BACKUP_BASE}/project.git"
    [ -d "${backup_dir}" ]
    git -C "${backup_dir}" tag -l 'claude-checkpoint/*' | grep -q 'claude-checkpoint/'
}

@test "second checkpoint pushes to the existing backup repo" {
    human_commit "initial"
    do_checkpoint

    human_commit "more human work"
    do_checkpoint

    local tag_count
    tag_count="$(git -C "${BACKUP_BASE}/project.git" tag -l 'claude-checkpoint/*' | wc -l | tr -d ' ')"
    [ "${tag_count}" -eq 2 ]
}

# ── Full workflow: checkpoint → Claude commits → reown ────────────────────────

@test "reown finds checkpoint and rewrites claude commits (dirty repo at checkpoint)" {
    human_commit "initial"
    echo "unsaved work" >> dirty.txt  # dirty repo

    do_checkpoint
    claude_commit "claude feature A"
    claude_commit "claude feature B"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]

    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
    [[ "$output" == *"checkpoint"* ]]
}

@test "reown finds checkpoint and rewrites claude commits (clean repo at checkpoint)" {
    human_commit "initial"
    # Clean repo at checkpoint time — the case that was previously broken

    do_checkpoint
    claude_commit "claude work"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]

    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
    [[ "$output" == *"checkpoint"* ]]
}

@test "reown uses the most recent checkpoint when multiple runs have occurred" {
    human_commit "initial"
    do_checkpoint
    claude_commit "old claude work"

    # Second run: human reviews, then runs again
    human_commit "human review commit"
    do_checkpoint
    claude_commit "new claude work"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 0 ]
}

@test "reown does not touch commits before the checkpoint" {
    human_commit "pre-checkpoint human work"
    do_checkpoint
    claude_commit "claude work"

    "${REOWN}" --force

    # The pre-checkpoint commit should remain human-authored
    local msg_author
    msg_author="$(git log --all --format='%ae %s' | grep 'pre-checkpoint human work')"
    [[ "${msg_author}" == "${HUMAN_EMAIL} "* ]]
}

@test "reown preserves file content after rewriting" {
    human_commit "initial"
    do_checkpoint

    echo "feature content" >> feature.txt
    git add -A
    GIT_AUTHOR_NAME="${CLAUDE_NAME}" GIT_AUTHOR_EMAIL="${CLAUDE_EMAIL}" \
    GIT_COMMITTER_NAME="${CLAUDE_NAME}" GIT_COMMITTER_EMAIL="${CLAUDE_EMAIL}" \
        git commit -m "add feature" >/dev/null

    "${REOWN}" --force

    [ "$(cat feature.txt)" = "feature content" ]
}

@test "reown exits cleanly with no output when there are no claude commits after checkpoint" {
    human_commit "initial"
    do_checkpoint
    human_commit "more human work"

    run "${REOWN}" --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"No Claude-authored commits found"* ]]
}

# ── Backup and recovery ───────────────────────────────────────────────────────

@test "backup repo survives a Claude history rewrite" {
    human_commit "precious work"
    do_checkpoint
    claude_commit "claude work"

    local backup_dir="${BACKUP_BASE}/project.git"

    # Simulate Claude wiping history
    git reset --hard HEAD~2

    # Verify backup still has the checkpoint tag
    git -C "${backup_dir}" tag -l "${CHECKPOINT_TAG}" | grep -q "${CHECKPOINT_TAG}"
}

@test "project is recoverable from backup after history destruction" {
    human_commit "precious work"
    do_checkpoint
    claude_commit "claude work"

    local backup_dir="${BACKUP_BASE}/project.git"
    local original_head
    original_head="$(git rev-parse "${CHECKPOINT_TAG}")"

    # Simulate Claude wiping everything
    git reset --hard HEAD~2

    # Recover via backup: fetch the specific tag (--all with a path URL is unreliable)
    git fetch "${backup_dir}" "refs/tags/${CHECKPOINT_TAG}:refs/tags/${CHECKPOINT_TAG}" >/dev/null 2>&1
    git reset --hard "${CHECKPOINT_TAG}"

    git log --format='%s' | grep -q "precious work"
    [ "$(git rev-parse HEAD)" = "${original_head}" ]
}

@test "reown backup tag allows restore to pre-reown state" {
    human_commit "initial"
    do_checkpoint
    claude_commit "claude work"

    local pre_reown_head
    pre_reown_head="$(git rev-parse HEAD)"

    "${REOWN}" --force

    local backup_tag
    backup_tag="$(git tag -l 'backup/pre-reown-*' | head -1)"
    [ -n "${backup_tag}" ]

    git reset --hard "${backup_tag}"
    [ "$(git rev-parse HEAD)" = "${pre_reown_head}" ]
    [ "$(count_by_author "${CLAUDE_EMAIL}")" -eq 1 ]
}
