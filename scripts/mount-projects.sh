#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mount-projects.sh — Resolves project directories into container mount flags.
#
# Sourced (not executed) by justfile recipes. Sets these variables:
#   PROJECT_DIRS         — bash array of resolved host paths
#   PROJECT_VOLUME_FLAGS — -v flags for podman/docker run (includes riotbox session mount)
#   PROJECT_SUMMARY      — human-readable list for status output
#   WORKDIR              — container working directory
#
# Single project:  mounted at /workspace (backward compatible)
# Multiple projects: each mounted at /workspace/<dirname>
# No projects:     current directory mounted at /workspace
# ─────────────────────────────────────────────────────────────────────────────

setup_projects() {
    local raw_projects="$1"
    PROJECT_DIRS=()
    PROJECT_VOLUME_FLAGS=""
    PROJECT_SUMMARY=""
    WORKDIR="/workspace"

    # RIOTBOX_READONLY=1 mounts projects read-only (for untrusted repos)
    local mount_suffix=":z"
    if [ "${RIOTBOX_READONLY:-}" = "1" ]; then
        mount_suffix=":ro,z"
    fi

    # Default to current directory if no projects specified
    if [ -z "${raw_projects}" ]; then
        raw_projects="$(pwd)"
    fi

    # Resolve each path to absolute
    for p in ${raw_projects}; do
        local resolved
        resolved="$(cd "${p}" && pwd)"
        PROJECT_DIRS+=("${resolved}")
    done

    if [ ${#PROJECT_DIRS[@]} -eq 1 ]; then
        # Single project: mount at /workspace (backward compatible)
        PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:/workspace${mount_suffix}"
        PROJECT_SUMMARY="${PROJECT_DIRS[0]}"
    else
        # Multiple projects: mount each at /workspace/<dirname>
        for dir in "${PROJECT_DIRS[@]}"; do
            local name
            name="$(basename "${dir}")"
            PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:/workspace/${name}${mount_suffix}"
            if [ -n "${PROJECT_SUMMARY}" ]; then
                PROJECT_SUMMARY="${PROJECT_SUMMARY}, ${name}"
            else
                PROJECT_SUMMARY="${name}"
            fi
        done
        PROJECT_SUMMARY="${#PROJECT_DIRS[@]} projects: ${PROJECT_SUMMARY}"
    fi

    # ── Session isolation ────────────────────────────────────────────
    # Each unique set of project paths gets its own Claude session directory
    # under ~/.claude-riotbox/, preventing session bleed between projects.
    # The key is a mangled version of the sorted absolute paths, matching
    # Claude Code's own convention (e.g. -home-user-Projects-foo).
    # Mangle: sort paths, join with +, replace / with -, strip leading -
    local session_key
    session_key="$(printf '%s\n' "${PROJECT_DIRS[@]}" | sort | sed 's|/|-|g; s|^-||' | paste -sd'+' -)"
    local riotbox_session_dir="${HOME}/.claude-riotbox/${session_key}"
    mkdir -p "${riotbox_session_dir}"
    chmod 700 "${riotbox_session_dir}"
    # Bail if a previous run without --userns=keep-id left dirs owned by
    # a subordinate UID.
    if [ ! -w "${riotbox_session_dir}" ]; then
        echo "ERROR: ${riotbox_session_dir} is not writable (wrong UID from a previous run)." >&2
        echo "  Fix with: sudo chown -R $(id -u):$(id -g) ${riotbox_session_dir}" >&2
        exit 1
    fi
    PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${riotbox_session_dir}:/home/claude/.claude:z"

    # Copy auth files into the session directory so Claude Code can read/write
    # them inside the container. Each session gets its own copy, avoiding both
    # permission issues (600 file + userns) and EBUSY with concurrent runs.
    # ~/.claude.json — account config and cached state
    # ~/.claude/.credentials.json — actual OAuth tokens
    for auth_file in "${HOME}/.claude.json" "${HOME}/.claude/.credentials.json"; do
        if [ -f "${auth_file}" ]; then
            dest="${riotbox_session_dir}/$(basename "${auth_file}")"
            cp "${auth_file}" "${dest}"
            chmod 600 "${dest}"
        fi
    done
}
