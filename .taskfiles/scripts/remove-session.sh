#!/usr/bin/env bash
set -euo pipefail
# Remove one or more riotbox sessions by session key or project path.
# Required env: ROOT_DIR
# Arguments: <session-key-or-path> [...] | --all

source "${ROOT_DIR}/scripts/mount-projects.sh"
source "${ROOT_DIR}/.taskfiles/scripts/session-summary.sh"
session_root="${XDG_DATA_HOME:-$HOME/.local/share}/claude-riotbox"

if [ $# -eq 0 ]; then
    cat >&2 <<EOF
Error: specify one or more sessions to remove, or --all.

Usage:
  task session-remove -- <session-key-or-path> [...]
  task session-remove -- --all

Arguments can be:
  session key   The encoded key shown by 'task session-list'
  project path  A path to a project directory (e.g. . or /home/user/myapp)
  --all         Remove all sessions

Run 'task session-list' to see available sessions.
EOF
    exit 1
fi

# Collect session dirs to remove
to_remove=()

if [ "$1" = "--all" ]; then
    if [ -d "${session_root}" ]; then
        for d in "${session_root}"/*/; do
            [ -d "${d}" ] || continue
            [ "$(basename "${d}")" = "backups" ] && continue
            to_remove+=("${d}")
        done
    fi
    if [ ${#to_remove[@]} -eq 0 ]; then
        echo "No sessions found."
        exit 0
    fi
else
    for arg in "$@"; do
        # Try as an exact session key
        candidate="${session_root}/${arg}"
        if [ -d "${candidate}" ]; then
            to_remove+=("${candidate}")
            continue
        fi
        # Try as a project path — resolve to session key
        if [ -e "${arg}" ]; then
            resolve_projects "${arg}"
            if [ -d "${RIOTBOX_SESSION_DIR}" ]; then
                to_remove+=("${RIOTBOX_SESSION_DIR}")
                continue
            else
                echo "ERROR: no session found for project '${arg}'" >&2
                echo "Run 'task session-list' to see available sessions." >&2
                exit 1
            fi
        fi
        echo "ERROR: '${arg}' is not a session key or an existing path." >&2
        echo "Run 'task session-list' to see available sessions." >&2
        exit 1
    done
fi

echo "Sessions to remove:"
for d in "${to_remove[@]}"; do session_summary "${d}"; done
echo ""

read -rp "Remove ${#to_remove[@]} session(s)? [y/N] " answer
[[ "${answer}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

for d in "${to_remove[@]}"; do rm -rf "${d}"; done
echo "Removed ${#to_remove[@]} session(s)."
