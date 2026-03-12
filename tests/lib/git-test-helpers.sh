#!/usr/bin/env bash
# Shared helpers for git-based Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

HUMAN_NAME="Test Human"
HUMAN_EMAIL="human@example.com"
CLAUDE_NAME="Claude"
CLAUDE_EMAIL="claude@riotbox"

# Create a test directory with a git repo and optional bare remote.
# Sets: TEST_DIR, REPO_DIR, BARE_DIR, GIT_CONFIG_GLOBAL
init_test_repo() {
    TEST_DIR="$(mktemp -d)"
    REPO_DIR="${TEST_DIR}/project"
    BARE_DIR="${TEST_DIR}/remote.git"

    git init --bare --initial-branch=main "${BARE_DIR}" >/dev/null 2>&1
    git init --initial-branch=main "${REPO_DIR}" >/dev/null 2>&1
    cd "${REPO_DIR}"
    git config user.name "${HUMAN_NAME}"
    git config user.email "${HUMAN_EMAIL}"
    git config init.defaultBranch main
    git remote add origin "${BARE_DIR}"

    # Isolate from host git config
    export GIT_CONFIG_GLOBAL="${TEST_DIR}/isolated.gitconfig"
}

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

count_by_author() {
    local email="${1}"
    shift
    git log "$@" --author="${email}" --format='%H' | wc -l | tr -d ' '
}
