#!/usr/bin/env bash
set -euo pipefail
# Run Claude with a task prompt, checkpointing all project repos first.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Arguments: task [projects...]

task_prompt="${1:?Usage: run.sh <task> [projects...]}"
shift
projects="${*:-}"

source "${ROOT_DIR}/scripts/mount-projects.sh"
setup_projects "${projects}"

echo "Launching Claude Code in riotbox..."
echo "   Projects: ${PROJECT_SUMMARY}"
echo "   Task    : ${task_prompt}"
echo "   Workdir : ${WORKDIR}"
echo "   Network : enabled (no host credentials mounted)"
echo ""

# Checkpoint: commit uncommitted work, tag, and push to a local backup.
# The backup is a bare repo under ~/.claude-riotbox/backups/ that Claude
# cannot access. Even if Claude deletes everything and rewrites history,
# the backup is intact.
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

# Non-interactive runs (-p) should never prompt for a session branch.
# Allow explicit override via SESSION_BRANCH=1 if the caller wants it.
export SESSION_BRANCH="${SESSION_BRANCH:-0}"
export RIOTBOX_PROJECTS="${projects}"
exec "${ROOT_DIR}/.taskfiles/scripts/launch.sh" claude -p "${task_prompt}"
