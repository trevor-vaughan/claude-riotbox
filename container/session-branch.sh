#!/usr/bin/env bash
# session-branch.sh — Session branch lifecycle management.
#
# Sourced by entrypoint.sh. Provides two functions:
#   session_branch_setup    — called before the main command
#   session_branch_teardown — called after the main command exits
#
# Environment variables (set by the launcher on the host):
#   SESSION_ID     — unique identifier for this container run
#   SESSION_BRANCH — "1" auto-create, "0" skip, unset = prompt
#
# State (set by setup, consumed by teardown):
#   _SB_BRANCH_PREFIX — the namespace prefix for session branches (e.g. riotbox)
#   _SB_BRANCH_NAME — the session branch we created (e.g. riotbox/20260309-...)
#   _SB_BASE_BRANCH — the branch we were on before (merge target on exit)

_SB_BRANCH_PREFIX="riotbox"
_SB_BRANCH_NAME=""
_SB_BASE_BRANCH=""

session_branch_setup() {
    # Only applies to single-project workspaces (single repo at /workspace)
    if [[ ! -d /workspace/.git ]]; then
        return 0
    fi

    # If SESSION_ID wasn't passed by the launcher, generate a fallback
    local session_id="${SESSION_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
    local branch_name="${_SB_BRANCH_PREFIX}/${session_id}"

    # Skip if HEAD is unborn (empty repo with no commits) — session branching
    # needs an existing commit to branch from.
    if ! git -C /workspace rev-parse --verify HEAD &>/dev/null; then
        echo "  [session-branch] Empty repo (no commits) — skipping session branch."
        echo "  Tip: make an initial commit first, then restart to get session branching:"
        echo "    git add <files> && git commit -m \"Initial commit\""
        return 0
    fi

    # Detect current branch (fails on detached HEAD)
    local current_branch
    if ! current_branch="$(git -C /workspace symbolic-ref --short HEAD 2>/dev/null)"; then
        echo "  [session-branch] Detached HEAD — skipping session branch."
        return 0
    fi

    # If we're already on a session branch (e.g. --continue resume), don't nest
    if [[ "${current_branch}" == ${_SB_BRANCH_PREFIX}/* ]]; then
        echo "  [session-branch] Already on session branch: ${current_branch}"
        return 0
    fi

    # Decide whether to create the branch
    local do_branch=false

    if [[ "${SESSION_BRANCH:-}" == "1" ]]; then
        do_branch=true
    elif [[ "${SESSION_BRANCH:-}" == "0" ]]; then
        return 0
    else
        # Interactive prompt — default Y (empty answer creates the branch)
        echo ""
        echo "  Git repo detected on branch '${current_branch}'."
        printf "  Create session branch '%s'? [Y/n] " "${branch_name}"
        local answer
        read -r answer
        echo ""
        if [[ ! "${answer}" =~ ^[Nn]$ ]]; then
            do_branch=true
        fi
    fi

    if [[ "${do_branch}" == true ]]; then
        if git -C /workspace checkout -b "${branch_name}"; then
            _SB_BRANCH_NAME="${branch_name}"
            _SB_BASE_BRANCH="${current_branch}"
            echo "  [session-branch] Created branch: ${branch_name}"
        else
            echo "  [session-branch] WARNING: Could not create branch ${branch_name} — continuing on ${current_branch}."
        fi
    fi
}

session_branch_teardown() {
    # Nothing to do if setup didn't create a branch
    [[ -z "${_SB_BRANCH_NAME}" ]] && return 0
    [[ -z "${_SB_BASE_BRANCH}" ]] && return 0

    echo ""
    echo "  [session-branch] Session complete. Merging ${_SB_BRANCH_NAME} → ${_SB_BASE_BRANCH}..."

    # Count commits on the session branch not yet in the base
    local commit_count
    commit_count="$(git -C /workspace rev-list --count "${_SB_BASE_BRANCH}..${_SB_BRANCH_NAME}" 2>/dev/null || echo 0)"

    if [[ "${commit_count}" == "0" ]]; then
        echo "  [session-branch] No new commits — removing empty session branch."
        git -C /workspace checkout "${_SB_BASE_BRANCH}" 2>/dev/null || true
        git -C /workspace branch -d "${_SB_BRANCH_NAME}" 2>/dev/null || true
        return 0
    fi

    echo "  [session-branch] ${commit_count} commit(s) to fast-forward."

    # Switch back to base branch
    if ! git -C /workspace checkout "${_SB_BASE_BRANCH}" 2>/dev/null; then
        echo "  [session-branch] MERGE FAILED — could not switch to '${_SB_BASE_BRANCH}'."
        echo "  Branch preserved: ${_SB_BRANCH_NAME}"
        echo "  Resolve manually: git checkout ${_SB_BASE_BRANCH} && git merge --ff-only ${_SB_BRANCH_NAME}"
        return 1
    fi

    # Fast-forward merge: all session commits land on the base branch as-is
    if ! git -C /workspace merge --ff-only "${_SB_BRANCH_NAME}" 2>/dev/null; then
        echo "  [session-branch] FAST-FORWARD FAILED — base branch has diverged since session started."
        echo "  Branch preserved: ${_SB_BRANCH_NAME}"
        echo "  Resolve manually: git rebase ${_SB_BASE_BRANCH} ${_SB_BRANCH_NAME} && git checkout ${_SB_BASE_BRANCH} && git merge --ff-only ${_SB_BRANCH_NAME}"
        return 1
    fi

    git -C /workspace branch -d "${_SB_BRANCH_NAME}" 2>/dev/null || true
    echo "  [session-branch] Fast-forward complete. ${commit_count} commit(s) on ${_SB_BASE_BRANCH}, session branch removed."
}
