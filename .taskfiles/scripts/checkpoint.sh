#!/usr/bin/env bash
set -euo pipefail
# ─────────────────────────────────────────────────────────────────────────────
# checkpoint.sh — Create pre-session backup of all project git repos.
#
# Creates a checkpoint commit, tags it, and pushes to a local bare backup repo
# under $XDG_DATA_HOME/claude-riotbox/backups/. The backup is outside the
# container mount tree so Claude cannot access or modify it.
#
# Required env: ROOT_DIR
# Optional env: RIOTBOX_PROJECTS (space-separated project paths; defaults to CWD)
# ─────────────────────────────────────────────────────────────────────────────

source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_projects "${RIOTBOX_PROJECTS:-}"

timestamp="$(date +%Y%m%d-%H%M%S)"
for dir in "${PROJECT_DIRS[@]}"; do
    if ! git -C "${dir}" rev-parse --git-dir &>/dev/null; then
        echo "  WARNING: ${dir} is not a git repo — no checkpoint protection!" >&2
        continue
    fi
    project_name="$(basename "${dir}")"

    # Commit any uncommitted work so it's safely captured before Claude runs.
    # Includes untracked files — the goal is a complete snapshot.
    if ! git -C "${dir}" diff --quiet || ! git -C "${dir}" diff --cached --quiet || \
       [ -n "$(git -C "${dir}" ls-files --others --exclude-standard)" ]; then
        git -C "${dir}" add -A
        git -C "${dir}" commit -m "checkpoint: pre-claude-${timestamp}"
    fi

    # Tag the current HEAD
    tag_name="claude-checkpoint/${timestamp}"
    git -C "${dir}" tag "${tag_name}"

    # Push everything to a local bare backup repo
    backup_dir="${RIOTBOX_DATA_DIR}/backups/${project_name}.git"
    if [ ! -d "${backup_dir}" ]; then
        git clone --bare "${dir}" "${backup_dir}" 2>/dev/null
    else
        # --no-verify: skip the pre-push hook (which blocks claude@riotbox commits)
        # The backup is a local bare repo, not a shared remote, so the hook
        # intent (prevent publishing unowned commits) does not apply here.
        git -C "${dir}" push --no-verify --force "${backup_dir}" --all 2>/dev/null
        git -C "${dir}" push --no-verify --force "${backup_dir}" --tags 2>/dev/null
    fi
    echo "  checkpoint: ${project_name} → ${tag_name} (backed up)"
done
