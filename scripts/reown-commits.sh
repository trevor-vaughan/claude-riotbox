#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reown-commits.sh — Rewrite Claude-authored commits to use your identity.
#
# After a riotbox run, Claude's commits will have the container's git identity.
# This script rewrites the author/committer on those commits so the history
# looks like yours, while preserving the Co-Authored-By trailer.
#
# Usage:
#   ./reown-commits.sh                     # rewrite since last checkpoint
#   ./reown-commits.sh <since-ref>         # rewrite since a specific ref
#   ./reown-commits.sh --all               # rewrite ALL claude-authored commits
#
# Your name/email are read from your git config.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

YOUR_NAME="$(git config user.name)"
YOUR_EMAIL="$(git config user.email)"

if [ -z "${YOUR_NAME}" ] || [ -z "${YOUR_EMAIL}" ]; then
    echo "ERROR: git user.name and user.email must be configured." >&2
    exit 1
fi

# Determine the range of commits to rewrite
if [ "${1:-}" = "--all" ]; then
    REF_RANGE="--all"
    echo "Rewriting ALL Claude-authored commits..."
elif [ -n "${1:-}" ]; then
    REF_RANGE="${1}..HEAD"
    echo "Rewriting Claude-authored commits since ${1}..."
else
    # Find the most recent checkpoint commit
    CHECKPOINT="$(git log --oneline --grep='checkpoint: pre-claude' -1 --format='%H' 2>/dev/null || true)"
    if [ -n "${CHECKPOINT}" ]; then
        REF_RANGE="${CHECKPOINT}..HEAD"
        echo "Rewriting Claude-authored commits since checkpoint $(git log -1 --format='%h %s' "${CHECKPOINT}")..."
    else
        echo "No checkpoint commit found. Specify a ref or use --all."
        echo "Usage: $0 [<since-ref>|--all]"
        exit 1
    fi
fi

# Count commits that will be affected
if [ "${REF_RANGE}" = "--all" ]; then
    COUNT="$(git log --all --author='claude' --format='%H' | wc -l)"
else
    COUNT="$(git log "${REF_RANGE}" --author='claude' --format='%H' | wc -l)"
fi

if [ "${COUNT}" -eq 0 ]; then
    echo "No Claude-authored commits found in range. Nothing to do."
    exit 0
fi

echo "Found ${COUNT} commit(s) to rewrite."
echo "  New author: ${YOUR_NAME} <${YOUR_EMAIL}>"
echo ""

# Use git filter-branch to rewrite author/committer
# Only touches commits where the author name contains "claude"
export YOUR_NAME YOUR_EMAIL
git filter-branch -f --env-filter '
if echo "${GIT_AUTHOR_NAME}" | grep -qi "claude"; then
    export GIT_AUTHOR_NAME="${YOUR_NAME}"
    export GIT_AUTHOR_EMAIL="${YOUR_EMAIL}"
    export GIT_COMMITTER_NAME="${YOUR_NAME}"
    export GIT_COMMITTER_EMAIL="${YOUR_EMAIL}"
fi
' -- ${REF_RANGE}

echo ""
echo "Done. ${COUNT} commit(s) rewritten."
echo ""
echo "Review with:  git log --oneline -${COUNT}"
echo "The old refs are backed up under refs/original/ — to remove them:"
echo "  git update-ref -d refs/original/refs/heads/$(git branch --show-current)"
