#!/usr/bin/env bash
set -euo pipefail
# Reset session cache (forces fresh skill/config copy).
# Required env: ROOT_DIR
# Arguments: [all] [force]

source "${ROOT_DIR}/scripts/mount-projects.sh"
source "${ROOT_DIR}/.taskfiles/scripts/session-summary.sh"
session_root="${XDG_DATA_HOME:-$HOME/.local/share}/claude-riotbox"

confirm() {
    [ "${force}" = true ] && return 0
    read -rp "$1 [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]]
}

all=false
force=false
for flag in "$@"; do
    case "${flag}" in
        all)   all=true ;;
        force) force=true ;;
        *)     echo "Unknown flag: ${flag}. Usage: task reset-session -- [all] [force]" >&2; exit 1 ;;
    esac
done

if [ "${all}" = true ]; then
    dirs=()
    if [ -d "${session_root}" ]; then
        for d in "${session_root}"/*/; do
            [ "$(basename "${d}")" = "backups" ] && continue
            dirs+=("${d}")
        done
    fi
    if [ ${#dirs[@]} -eq 0 ]; then
        echo "No session dirs found."
        exit 0
    fi
    echo "Sessions to remove:"
    for d in "${dirs[@]}"; do session_summary "${d}"; done
    echo ""
    confirm "Remove ${#dirs[@]} session(s)?" || { echo "Aborted."; exit 0; }
    for d in "${dirs[@]}"; do rm -rf "${d}"; done
    echo "Removed ${#dirs[@]} session(s). Next run will create fresh copies."
else
    resolve_projects ""
    if [ ! -d "${RIOTBOX_SESSION_DIR}" ]; then
        echo "No session dir found for $(pwd)."
        exit 0
    fi
    echo "Session to remove:"
    session_summary "${RIOTBOX_SESSION_DIR}"
    echo ""
    confirm "Remove this session?" || { echo "Aborted."; exit 0; }
    rm -rf "${RIOTBOX_SESSION_DIR}"
    echo "Removed. Next run will create a fresh copy."
fi
