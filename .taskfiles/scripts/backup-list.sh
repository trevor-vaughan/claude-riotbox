#!/usr/bin/env bash
set -euo pipefail
# List available backups.

backup_root="${HOME}/.claude-riotbox/backups"
if [ ! -d "${backup_root}" ] || [ -z "$(ls -A "${backup_root}" 2>/dev/null)" ]; then
    echo "No backups found."
    exit 0
fi

echo "Available backups:"
for backup in "${backup_root}"/*.git; do
    name="$(basename "${backup}" .git)"
    count="$(git -C "${backup}" tag -l 'claude-checkpoint/*' 2>/dev/null | wc -l)"
    latest="$(git -C "${backup}" tag -l 'claude-checkpoint/*' 2>/dev/null | sort | tail -1)"
    echo "  ${name}  (${count} checkpoints, latest: ${latest:-none})"
done
