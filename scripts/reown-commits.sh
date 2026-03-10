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

# Primary container identity (current)
CLAUDE_EMAIL="claude@riotbox"
# Legacy identity used by old squash-merge code (pre-ff-only fix)
CLAUDE_EMAIL_LEGACY="riotbox@local"

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
            echo "Usage: task reown -- [<since-ref>|--all] [--force]" >&2
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

# ── GPG pre-flight check ─────────────────────────────────────────────────────
# Fail fast before touching history if GPG signing is enabled but the key is
# not available. filter-repo runs first (Pass 1), so a signing failure in
# Pass 2 would leave the repo in a rewritten-but-unsigned state.

if [ "$(git config --bool commit.gpgsign 2>/dev/null)" = "true" ]; then
    SIGNING_KEY="$(git config user.signingkey 2>/dev/null || true)"
    if [ -z "${SIGNING_KEY}" ]; then
        echo "ERROR: commit.gpgsign is true but no user.signingkey is configured." >&2
        echo "Set it with:  git config --global user.signingkey <key-id>" >&2
        exit 1
    fi
    if ! echo "riotbox-gpg-preflight" \
            | gpg --local-user "${SIGNING_KEY}" --sign --batch --no-tty --pinentry-mode loopback --output /dev/null 2>/dev/null; then
        echo "ERROR: GPG key '${SIGNING_KEY}' is not unlocked or not accessible." >&2
        echo "Unlock your key before running reown. For example:" >&2
        echo "  echo test | gpg --local-user ${SIGNING_KEY} --sign --output /dev/null" >&2
        exit 1
    fi
    echo "GPG key ${SIGNING_KEY} is unlocked and ready."
    echo ""
fi

# ── Determine the range of commits to rewrite ───────────────────────────────

GIT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${GIT_TOPLEVEL}" ]; then
    echo "ERROR: not inside a git repository." >&2
    echo "  CWD: $(pwd)" >&2
    exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ -z "${CURRENT_BRANCH}" ]; then
    echo "ERROR: detached HEAD state — checkout a branch first." >&2
    exit 1
fi

echo "Repository: ${GIT_TOPLEVEL}"
echo "Branch:     ${CURRENT_BRANCH}"
echo ""

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
        echo "Usage: task reown -- [<since-ref>|--all] [--force]"
        exit 1
    fi
fi

# ── Count affected commits ──────────────────────────────────────────────────

TOTAL_IN_RANGE="$(git rev-list --count "${LOG_RANGE[@]}")"
CLAUDE_COUNT="$(git rev-list --count "${LOG_RANGE[@]}" --author="${CLAUDE_EMAIL}" --author="${CLAUDE_EMAIL_LEGACY}")"

if [ "${CLAUDE_COUNT}" -eq 0 ]; then
    echo "No Claude-authored commits found in range (${RANGE_DESC}). Nothing to do."
    exit 0
fi

echo "Found ${CLAUDE_COUNT} Claude-authored commit(s) in range (${RANGE_DESC})."
echo "  ${TOTAL_IN_RANGE} total commit(s) in hash chain will be rewritten."
echo "  New author: ${YOUR_NAME} <${YOUR_EMAIL}>"
echo ""

# List the Claude-authored commits that will be rewritten
echo "Commits to reown:"
git --no-pager log "${LOG_RANGE[@]}" --author="${CLAUDE_EMAIL}" --author="${CLAUDE_EMAIL_LEGACY}" --format="  %C(yellow)%h%Creset %s" --reverse
echo ""

# Show any non-Claude commits in the range (they get rewritten too due to hash chain)
NON_CLAUDE_COUNT=$(( TOTAL_IN_RANGE - CLAUDE_COUNT ))
if [ "${NON_CLAUDE_COUNT}" -gt 0 ]; then
    echo "Also in range (${NON_CLAUDE_COUNT} commit(s) by other authors — hashes will change):"
    # --invert-grep only works with --grep, not --author; use grep -v to exclude
    git log "${LOG_RANGE[@]}" --format="%ae %C(dim)%h%Creset %s %C(dim)(%an)%Creset" --reverse \
        | grep -Ev "^${CLAUDE_EMAIL} |^${CLAUDE_EMAIL_LEGACY} " \
        | sed 's/^[^ ]* /  /'
    echo ""
fi

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

# ── Save remote URLs and upstream tracking (filter-repo removes both) ───────

declare -A REMOTES
while IFS= read -r remote_name; do
    REMOTES["${remote_name}"]="$(git remote get-url "${remote_name}")"
done < <(git remote)

# Capture upstream tracking ref so we can restore it after filter-repo wipes
# refs/remotes/*. Without this, `git push` sees no remote tracking ref, fetches
# from origin, and incorrectly tells the user to rebase instead of force-push.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"

# ── Pass 1: Rewrite author/committer via filter-repo ────────────────────────

MAILMAP="$(mktemp)"
trap 'rm -f "${MAILMAP}"' EXIT

# mailmap format: New Name <new@email> <old@email>
# Include both current and legacy container identities.
printf '%s <%s> <%s>\n' "${YOUR_NAME}" "${YOUR_EMAIL}" "${CLAUDE_EMAIL}"        > "${MAILMAP}"
printf '%s <%s> <%s>\n' "${YOUR_NAME}" "${YOUR_EMAIL}" "${CLAUDE_EMAIL_LEGACY}" >> "${MAILMAP}"

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

# Restore the upstream tracking ref so push commands know where to push.
# filter-repo deletes refs/remotes/* for rewritten refs, so without this step
# `git push` would not know the remote-side state and would suggest rebasing.
if [ -n "${UPSTREAM}" ]; then
    if git branch --set-upstream-to="${UPSTREAM}" "${CURRENT_BRANCH}" 2>/dev/null; then
        echo "Restored upstream tracking: ${CURRENT_BRANCH} -> ${UPSTREAM}"
    else
        echo "NOTE: Could not restore upstream tracking to '${UPSTREAM}' — set it manually if needed." >&2
    fi
fi

# ── Pass 2: Re-sign commits with GPG (if enabled) ───────────────────────────

if [ "$(git config --bool commit.gpgsign 2>/dev/null)" = "true" ]; then
    SIGNING_KEY="$(git config user.signingkey 2>/dev/null || true)"
    if [ "${TOTAL_IN_RANGE}" -gt 0 ]; then
        echo ""
        echo "Pass 2: Re-signing ${TOTAL_IN_RANGE} rewritten commit(s) with GPG key ${SIGNING_KEY}..."

        REBASE_ARGS=(--committer-date-is-author-date --exec 'git commit --amend --no-edit -S -n')

        # Re-verify the upstream ref post-filter-repo: filter-repo only rewrites
        # commits unique to this branch, so HEAD~N may not exist if the range
        # abuts or includes the root of the rewritten portion.
        if git rev-parse --verify "HEAD~${TOTAL_IN_RANGE}" &>/dev/null; then
            git rebase "${REBASE_ARGS[@]}" "HEAD~${TOTAL_IN_RANGE}"
        else
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
echo "IMPORTANT: History was rewritten — commit hashes have changed."
echo "A normal 'git push' will be rejected because the remote has different hashes."
echo "You must force-push:"
echo "  git push --force-with-lease"
echo ""
echo "Once satisfied, delete the backup tag:"
echo "  git tag -d ${BACKUP_TAG}/${CURRENT_BRANCH}"
