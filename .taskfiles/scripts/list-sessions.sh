#!/usr/bin/env bash
set -euo pipefail
# List riotbox session directories with project paths and usage info.

session_root="${XDG_DATA_HOME:-$HOME/.local/share}/claude-riotbox"

if [ ! -d "${session_root}" ] || [ -z "$(ls -A "${session_root}" 2>/dev/null)" ]; then
    echo "No sessions found."
    exit 0
fi

found=0
for session_dir in "${session_root}"/*/; do
    [ -d "${session_dir}" ] || continue
    name="$(basename "${session_dir}")"
    [ "${name}" = "backups" ] && continue

    found=$((found + 1))

    # Project paths — written at launch time by mount-projects.sh
    have_projects=false
    if [ -f "${session_dir}/.projects" ]; then
        mapfile -t project_paths < "${session_dir}/.projects"
        have_projects=true
    else
        project_paths=("${name}")  # fallback: show the encoded key (pre-metadata sessions)
    fi

    # Last used: mtime of the session dir (updated on each launch)
    last_used="$(stat -c '%y' "${session_dir}" 2>/dev/null | cut -d. -f1)"

    # Size on disk
    size="$(du -sh "${session_dir}" 2>/dev/null | cut -f1)"

    # Contents inventory
    contents=()
    if [ -d "${session_dir}/skills" ]; then
        skill_count="$(find "${session_dir}/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
        contents+=("${skill_count} skills")
    fi
    [ -f "${session_dir}/.claude.json" ] && contents+=("config")
    [ -f "${session_dir}/statusline-command.sh" ] && contents+=("statusline")
    contents_str="$(IFS=', '; echo "${contents[*]:-empty}")"

    # Whether the projects still exist on disk (only check if we have real paths)
    missing=()
    if [ "${have_projects}" = true ]; then
        for p in "${project_paths[@]}"; do
            [ -d "${p}" ] || missing+=("${p}")
        done
    fi

    # Print
    if [ ${#project_paths[@]} -eq 1 ]; then
        echo "${project_paths[0]}"
    else
        echo "${#project_paths[@]} projects:"
        for p in "${project_paths[@]}"; do
            echo "  ${p}"
        done
    fi
    echo "  Last used:  ${last_used}"
    echo "  Size:       ${size}    Contents: ${contents_str}"
    echo "  Key:        ${name}"
    if [ ${#missing[@]} -gt 0 ]; then
        echo "  WARNING: project no longer exists: ${missing[*]}"
    fi
    echo ""
done

[ "${found}" -gt 0 ] || echo "No sessions found."
