#!/usr/bin/env bash
# session-summary.sh — Print a human-readable summary of a session directory.
# Sourced by reset-session.sh and remove-session.sh.
# Usage: session_summary <session_dir>

session_summary() {
    local session_dir="$1"
    local last_used size
    last_used="$(stat -c '%y' "${session_dir}" 2>/dev/null | cut -d. -f1)"
    size="$(du -sh "${session_dir}" 2>/dev/null | cut -f1)"

    if [ -f "${session_dir}/.projects" ]; then
        mapfile -t paths < "${session_dir}/.projects"
        for p in "${paths[@]}"; do echo "  ${p}"; done
        echo "    last used: ${last_used}, ${size}"
    else
        echo "  $(basename "${session_dir}")  (last used: ${last_used}, ${size})"
    fi
}
