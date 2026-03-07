#!/usr/bin/env bash
set -euo pipefail
# Restore a project from its backup after a botched run.
# Arguments: project_name

project_name="${1:?Usage: backup-restore.sh <project_name>}"
backup_dir="${HOME}/.claude-riotbox/backups/${project_name}.git"

if [ ! -d "${backup_dir}" ]; then
    echo "ERROR: no backup found at ${backup_dir}" >&2
    echo "Available backups:" >&2
    ls "${HOME}/.claude-riotbox/backups/" 2>/dev/null | sed 's/\.git$//' | sed 's/^/  /' >&2
    exit 1
fi

echo "Backup refs for ${project_name}:"
git -C "${backup_dir}" tag -l 'claude-checkpoint/*' | sort | while read -r tag; do
    echo "  ${tag}  ($(git -C "${backup_dir}" log -1 --format='%s' "${tag}" 2>/dev/null))"
done
echo ""
echo "To restore in your project directory:"
echo "  git fetch ${backup_dir} --all --tags"
echo "  git reset --hard claude-checkpoint/<timestamp>"
echo ""
echo "Or to clone a fresh copy:"
echo "  git clone ${backup_dir} ${project_name}-restored"
