#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reown-commits.sh — Rewrite Claude-authored commits to use your identity.
#
# After a riotbox run, Claude's commits will have the container's git identity.
# This script rewrites the author/committer on those commits so the history
# looks like yours, while preserving the Co-Authored-By trailer.
#
# Uses git-filter-repo (the officially recommended replacement for
# filter-branch) with a two-pass approach:
#   Pass 1: Rewrite author/committer fields via filter-repo
#   Pass 2: Re-sign commits with GPG (if commit.gpgsign is enabled)
#
# A backup tag is created before rewriting so you can verify the result
# and easily restore if needed.
#
# Usage:
#   ./reown-commits.sh                     # rewrite since last checkpoint
#   ./reown-commits.sh <since-ref>         # rewrite since a specific ref
#   ./reown-commits.sh --all               # rewrite all claude-authored commits on current branch
#   ./reown-commits.sh --force             # skip confirmation prompt
#
# Your name/email are read from your git config.
# Requires: git-filter-repo (pip install git-filter-repo)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLAUDE_EMAIL="claude@riotbox"

# ── Dependency check ─────────────────────────────────────────────────────────

if ! command -v git-filter-repo &>/dev/null; then
    echo "ERROR: git-filter-repo is not installed." >&2
    echo "Install it with:  pip install git-filter-repo" >&2
    exit 1
fi

# ── Parse arguments ──────────────────────────────────────────────────────────

FORCE=false
REF_ARG=""
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=true ;;
        --all)      REF_ARG="--all" ;;
        -*)
            echo "ERROR: Unknown option '${arg}'." >&2
            echo "Usage: $0 [<since-ref>|--all] [--force]" >&2
            exit 1
            ;;
        *)  REF_ARG="${arg}" ;;
    esac
done

YOUR_NAME="$(git config user.name)"
YOUR_EMAIL="$(git config user.email)"

if [ -z "${YOUR_NAME}" ] || [ -z "${YOUR_EMAIL}" ]; then
    echo "ERROR: git user.name and user.email must be configured." >&2
    exit 1
fi

# ── Determine the range of commits to rewrite ───────────────────────────────

CURRENT_BRANCH="$(git branch --show-current)"
if [ -z "${CURRENT_BRANCH}" ]; then
    echo "ERROR: detached HEAD state — checkout a branch first." >&2
    exit 1
fi

if [ "${REF_ARG}" = "--all" ]; then
    RANGE_DESC="all Claude-authored commits on ${CURRENT_BRANCH}"
    LOG_RANGE=("${CURRENT_BRANCH}")
elif [ -n "${REF_ARG}" ]; then
    # Validate that the ref exists (also prevents flag injection via --)
    if ! git rev-parse --verify "${REF_ARG}" &>/dev/null; then
        echo "ERROR: '${REF_ARG}' is not a valid git ref." >&2
        exit 1
    fi
    RANGE_DESC="commits since ${REF_ARG}"
    LOG_RANGE=("${REF_ARG}..HEAD")
else
    # Find the most recent checkpoint commit
    CHECKPOINT="$(git log --grep='checkpoint: pre-claude' -1 --format='%H' 2>/dev/null || true)"
    if [ -n "${CHECKPOINT}" ]; then
        RANGE_DESC="commits since checkpoint $(git log -1 --format='%h %s' "${CHECKPOINT}")"
        LOG_RANGE=("${CHECKPOINT}..HEAD")
    else
        echo "No checkpoint commit found. Specify a ref or use --all."
        echo "Usage: $0 [<since-ref>|--all] [--force]"
        exit 1
    fi
fi

# ── Count affected commits ──────────────────────────────────────────────────

TOTAL_IN_RANGE="$(git rev-list --count "${LOG_RANGE[@]}")"
CLAUDE_COUNT="$(git rev-list --count "${LOG_RANGE[@]}" --author="${CLAUDE_EMAIL}")"

if [ "${CLAUDE_COUNT}" -eq 0 ]; then
    echo "No Claude-authored commits found in range (${RANGE_DESC}). Nothing to do."
    exit 0
fi

echo "Found ${CLAUDE_COUNT} Claude-authored commit(s) in range (${RANGE_DESC})."
echo "  ${TOTAL_IN_RANGE} total commit(s) will be rewritten (hash chain)."
echo "  New author: ${YOUR_NAME} <${YOUR_EMAIL}>"
echo ""

if [ "${FORCE}" != true ]; then
    read -rp "Proceed with rewrite? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# ── Create backup tags ──────────────────────────────────────────────────────

BACKUP_TAG="backup/pre-reown-$(date +%Y%m%d-%H%M%S)"

git tag "${BACKUP_TAG}/${CURRENT_BRANCH}" "${CURRENT_BRANCH}"
echo "Backup tag created: ${BACKUP_TAG}/${CURRENT_BRANCH}"
echo "  Restore with:  git reset --hard ${BACKUP_TAG}/${CURRENT_BRANCH}"
echo ""

# ── Save remote URLs (filter-repo removes them) ─────────────────────────────

declare -A REMOTES
while IFS= read -r remote_name; do
    REMOTES["${remote_name}"]="$(git remote get-url "${remote_name}")"
done < <(git remote)

# ── Save rebase base commit before rewrite ───────────────────────────────────

REBASE_BASE=""
if [ "${TOTAL_IN_RANGE}" -gt 0 ]; then
    REBASE_BASE="$(git rev-parse "HEAD~${TOTAL_IN_RANGE}" 2>/dev/null || true)"
fi

# ── Pass 1: Rewrite author/committer via filter-repo ────────────────────────

MAILMAP="$(mktemp)"
trap 'rm -f "${MAILMAP}"' EXIT

# mailmap format: New Name <new@email> <old@email>
echo "${YOUR_NAME} <${YOUR_EMAIL}> <${CLAUDE_EMAIL}>" > "${MAILMAP}"

echo "Pass 1: Rewriting author/committer fields..."

FILTER_REPO_ARGS=(
    --mailmap "${MAILMAP}"
    --force
    --refs "${CURRENT_BRANCH}"
)

git filter-repo "${FILTER_REPO_ARGS[@]}"

echo "Pass 1 complete."

# ── Restore remotes ─────────────────────────────────────────────────────────

for remote_name in "${!REMOTES[@]}"; do
    if git remote add "${remote_name}" "${REMOTES[${remote_name}]}" 2>/dev/null; then
        echo "Restored remote: ${remote_name} -> ${REMOTES[${remote_name}]}"
    elif git remote set-url "${remote_name}" "${REMOTES[${remote_name}]}" 2>/dev/null; then
        echo "Updated remote: ${remote_name} -> ${REMOTES[${remote_name}]}"
    else
        echo "WARNING: Failed to restore remote '${remote_name}'." >&2
    fi
done

# ── Pass 2: Re-sign commits with GPG (if enabled) ───────────────────────────

if [ "$(git config --bool commit.gpgsign 2>/dev/null)" = "true" ]; then
    SIGNING_KEY="$(git config user.signingkey 2>/dev/null || true)"
    if [ -z "${SIGNING_KEY}" ]; then
        echo "" >&2
        echo "WARNING: commit.gpgsign is true but no user.signingkey configured." >&2
        echo "Skipping re-signing. Commits will be unsigned." >&2
    elif [ "${TOTAL_IN_RANGE}" -gt 0 ]; then
        echo ""
        echo "Pass 2: Re-signing ${TOTAL_IN_RANGE} rewritten commit(s) with GPG key ${SIGNING_KEY}..."

        REBASE_ARGS=(--committer-date-is-author-date --exec 'git commit --amend --no-edit -S -n')

        if [ -n "${REBASE_BASE}" ]; then
            # Find the corresponding new commit for the pre-rewrite base
            git rebase "${REBASE_ARGS[@]}" "HEAD~${TOTAL_IN_RANGE}"
        else
            # Range includes root commit
            git rebase "${REBASE_ARGS[@]}" --root
        fi

        echo "Pass 2 complete. Commits signed with key ${SIGNING_KEY}."
    fi
else
    echo ""
    echo "GPG signing not enabled — skipping Pass 2."
fi

echo ""
echo "Done. ${CLAUDE_COUNT} commit(s) rewritten."
echo ""
echo "Review with:  git log --oneline -${TOTAL_IN_RANGE}"
echo "Compare with: git diff ${BACKUP_TAG}/${CURRENT_BRANCH}..${CURRENT_BRANCH}"
echo ""
echo "Once satisfied, delete the backup tag:"
echo "  git tag -d ${BACKUP_TAG}/${CURRENT_BRANCH}"
