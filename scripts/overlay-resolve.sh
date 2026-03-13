#!/usr/bin/env bash
# overlay-resolve.sh — Resolve a project path to its overlay data directory.
#
# Sourced (not executed). Sets these variables:
#   OVERLAY_PROJECT_DIR  — the resolved host project path
#   OVERLAY_SESSION_DIR  — the session directory containing overlay data
#   OVERLAY_DIR          — the overlay subdirectory (contains upper/ and work/)
#
# Usage: source overlay-resolve.sh; resolve_overlay [project-path]
#   If no path given, uses pwd. Errors if no overlay data found.

# Requires ROOT_DIR to be set by the caller.
source "${ROOT_DIR}/scripts/mount-projects.sh"

resolve_overlay() {
    local project_path="${1:-$(pwd)}"

    # Resolve to absolute
    if [ -d "${project_path}" ]; then
        project_path="$(cd "${project_path}" && pwd)"
    else
        echo "ERROR: '${project_path}' is not a directory." >&2
        return 1
    fi

    # shellcheck disable=SC2034  # used by caller after sourcing
    OVERLAY_PROJECT_DIR="${project_path}"

    # Resolve to session dir
    resolve_projects "${project_path}"
    OVERLAY_SESSION_DIR="${RIOTBOX_SESSION_DIR}"

    if [ ! -d "${OVERLAY_SESSION_DIR}" ]; then
        echo "ERROR: No session found for '${project_path}'." >&2
        echo "Run 'claude-riotbox session-list' to see available sessions." >&2
        return 1
    fi

    # Find the overlay subdir
    # Single project: overlay/project/upper
    # Multi-project: overlay/<basename>/upper
    local overlay_base="${OVERLAY_SESSION_DIR}/overlay"
    if [ -d "${overlay_base}/project/upper" ]; then
        # shellcheck disable=SC2034  # used by caller after sourcing
        OVERLAY_DIR="${overlay_base}/project"
    else
        local name
        name="$(basename "${project_path}")"
        if [ -d "${overlay_base}/${name}/upper" ]; then
            # shellcheck disable=SC2034  # used by caller after sourcing
            OVERLAY_DIR="${overlay_base}/${name}"
        else
            echo "ERROR: No overlay data found for '${project_path}'." >&2
            echo "Run 'claude-riotbox overlays' to see pending overlays." >&2
            return 1
        fi
    fi
}

# Check if an overlay dir has any actual changes (non-empty upper).
overlay_has_changes() {
    local overlay_dir="$1"
    [ -d "${overlay_dir}/upper" ] && [ -n "$(ls -A "${overlay_dir}/upper" 2>/dev/null)" ]
}
