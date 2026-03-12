#!/usr/bin/env bash
set -euo pipefail
# ─────────────────────────────────────────────────────────────────────────────
# checkpoint.sh — Create pre-session backup of all project git repos.
#
# Creates a checkpoint commit, tags it, and pushes to a local bare backup repo
# under ~/.claude-riotbox/backups/. The backup is outside the container mount
# tree so Claude cannot access or modify it.
#
# Required env: ROOT_DIR
# Optional env: RIOTBOX_PROJECTS (space-separated project paths; defaults to CWD)
# ─────────────────────────────────────────────────────────────────────────────

source "${ROOT_DIR}/scripts/mount-projects.sh"
setup_projects "${RIOTBOX_PROJECTS:-}"

timestamp="$(date +%Y%m%d-%H%M%S)"
for dir in "${PROJECT_DIRS[@]}"; do
    if ! git -C "${dir}" rev-parse --git-dir &>/dev/null; then
        echo "  WARNING: ${dir} is not a git repo — no checkpoint protection!" >&2
        continue
    fi
    project_name="$(basename "${dir}")"

    # Commit any uncommitted work, then create a checkpoint commit.
    # --allow-empty ensures the checkpoint commit is always created even when
    # the repo is clean — reown-commits.sh locates the range by searching for
    # this commit message, so it must exist regardless of repo state.
    if ! git -C "${dir}" diff --quiet || ! git -C "${dir}" diff --cached --quiet; then
        git -C "${dir}" add -A
    fi
    git -C "${dir}" commit --allow-empty -m "checkpoint: pre-claude-${timestamp}"

    # Tag the current HEAD
    tag_name="claude-checkpoint/${timestamp}"
    git -C "${dir}" tag "${tag_name}"

    # Push everything to a local bare backup repo
    backup_dir="${HOME}/.claude-riotbox/backups/${project_name}.git"
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
