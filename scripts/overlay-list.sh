#!/usr/bin/env bash
set -euo pipefail
# overlay-list.sh — List sessions with pending overlay data.
# Exit 0 if overlays exist, 1 if none.

session_root="${XDG_DATA_HOME:-$HOME/.local/share}/claude-riotbox"

if [ ! -d "${session_root}" ]; then
    echo "No pending overlays."
    exit 1
fi

found=0

for session_dir in "${session_root}"/*/; do
    [ -d "${session_dir}" ] || continue
    name="$(basename "${session_dir}")"
    [ "${name}" = "backups" ] && continue

    overlay_base="${session_dir}/overlay"
    [ -d "${overlay_base}" ] || continue

    # Check each overlay subdir for non-empty upper
    for overlay_dir in "${overlay_base}"/*/; do
        [ -d "${overlay_dir}/upper" ] || continue
        [ -n "$(ls -A "${overlay_dir}/upper" 2>/dev/null)" ] || continue

        # This overlay has changes
        if [ "${found}" -eq 0 ]; then
            echo "Pending overlays:"
            echo ""
        fi
        found=$((found + 1))

        # Read project paths from session metadata
        if [ -f "${session_dir}/.projects" ]; then
            mapfile -t project_paths < "${session_dir}/.projects"
        else
            project_paths=("(unknown)")
        fi

        # Timestamp from overlay dir mtime
        last_modified="$(stat -c '%y' "${overlay_dir}/upper" 2>/dev/null | cut -d. -f1)"

        # Count changes in upper dir
        local_added=0 local_deleted=0
        while IFS= read -r path; do
            base="$(basename "${path}")"
            if [[ "${base}" == .wh.* ]]; then
                local_deleted=$((local_deleted + 1))
            else
                local_added=$((local_added + 1))
            fi
        done < <(find "${overlay_dir}/upper" -mindepth 1 -not -type d 2>/dev/null)

        size="$(du -sh "${overlay_dir}" 2>/dev/null | cut -f1)"

        echo "  Project  ${project_paths[0]}"
        echo "  Changed  ${last_modified}"
        echo "  Files    ${local_added} added/modified, ${local_deleted} deleted  (${size} on disk)"
        echo "  Key      ${name}"
        echo ""
    done
done

if [ "${found}" -eq 0 ]; then
    echo "No pending overlays."
    exit 1
fi
