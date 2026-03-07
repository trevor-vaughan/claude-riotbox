#!/usr/bin/env just --justfile
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

# --- Variables ---
caller_dir := invocation_directory()

# --- Recipes ---

# List recipes in this module
_default:
    @just --list --unsorted

# Restore a project from its backup after a botched run
# project_name - name of the project to restore
restore project_name:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    backup_dir="${HOME}/.claude-riotbox/backups/{{project_name}}.git"
    if [ ! -d "${backup_dir}" ]; then
        echo "ERROR: no backup found at ${backup_dir}" >&2
        echo "Available backups:" >&2
        ls "${HOME}/.claude-riotbox/backups/" 2>/dev/null | sed 's/\.git$//' | sed 's/^/  /' >&2
        exit 1
    fi
    echo "Backup refs for {{project_name}}:"
    git -C "${backup_dir}" tag -l 'claude-checkpoint/*' | sort | while read -r tag; do
        echo "  ${tag}  ($(git -C "${backup_dir}" log -1 --format='%s' "${tag}" 2>/dev/null))"
    done
    echo ""
    echo "To restore in your project directory:"
    echo "  git fetch ${backup_dir} --all --tags"
    echo "  git reset --hard claude-checkpoint/<timestamp>"
    echo ""
    echo "Or to clone a fresh copy:"
    echo "  git clone ${backup_dir} {{project_name}}-restored"

# List available backups
list:
    #!/usr/bin/env bash
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
