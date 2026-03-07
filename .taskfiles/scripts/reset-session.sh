#!/usr/bin/env bash
set -euo pipefail
# Reset session cache (forces fresh skill/config copy).
# Required env: ROOT_DIR
# Arguments: [all] [force]

source "${ROOT_DIR}/scripts/mount-projects.sh"
session_root="${HOME}/.claude-riotbox"

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
        *)     echo "Unknown flag: ${flag}. Usage: reset-session [all] [force]" >&2; exit 1 ;;
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
    confirm "Remove ${#dirs[@]} session dir(s)?" || { echo "Aborted."; exit 0; }
    for d in "${dirs[@]}"; do rm -rf "${d}"; done
    echo "Removed ${#dirs[@]} session dir(s). Next run will create fresh copies."
else
    resolve_projects ""
    if [ ! -d "${RIOTBOX_SESSION_DIR}" ]; then
        echo "No session dir found for $(pwd)."
        exit 0
    fi
    confirm "Remove session dir for ${PROJECT_SUMMARY}?" || { echo "Aborted."; exit 0; }
    rm -rf "${RIOTBOX_SESSION_DIR}"
    echo "Removed session for ${PROJECT_SUMMARY}. Next run will create a fresh copy."
fi
