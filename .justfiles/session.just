#!/usr/bin/env just --justfile
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# --- Variables ---
root := source_directory() / ".."
root_justfile := source_directory() / ".." / "Justfile"
caller_dir := invocation_directory()
image_name := env_var_or_default("IMAGE_NAME", "claude-riotbox")
container_cmd := if `command -v podman 2>/dev/null` != "" { "podman" } else { "docker" }

# Podman rootless remaps UIDs by default, which breaks file ownership on
# bind-mounted volumes. --userns=keep-id preserves the host UID inside the
# container so mounted files aren't owned by root/nobody.
userns_flag := if container_cmd == "podman" { "--userns=keep-id" } else { "" }

# catatonit (podman's --init process) segfaults on EL10 (catatonit-0.2.1-3).
# Not needed — our entrypoint.sh handles signal forwarding.
init_flag := if container_cmd == "podman" { "--init=false" } else { "" }

# --- Recipes ---

# List recipes in this module
_default:
    @just --list --unsorted

# Verify the container image exists
_ensure-image:
    #!/usr/bin/env bash
    if ! {{container_cmd}} inspect {{image_name}} &>/dev/null; then
        echo "ERROR: Image '{{image_name}}' not found. Run 'just docker build' first." >&2
        exit 1
    fi

# Set up mounts and launch a container with the given command
_launch +cmd: _ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    source "{{root}}/scripts/mount-projects.sh"
    export CONTAINER_CMD="{{container_cmd}}"
    setup_projects "${RIOTBOX_PROJECTS:-}"
    MOUNTS="$("{{root}}/scripts/detect-mounts.sh")"
    # RIOTBOX_NETWORK=none disables outbound network (prevents exfiltration)
    NET_FLAG=""
    if [ "${RIOTBOX_NETWORK:-}" = "none" ]; then
        NET_FLAG="--network=none"
    fi
    # RIOTBOX_NESTED=1 enables podman-in-podman (disables SELinux confinement)
    NESTED_FLAGS=""
    if [ "${RIOTBOX_NESTED:-}" = "1" ]; then
        NESTED_FLAGS="--device /dev/fuse --security-opt label=disable"
    fi
    {{container_cmd}} run --rm -it {{userns_flag}} {{init_flag}} \
        --name "${CONTAINER_NAME}" \
        ${NET_FLAG} \
        ${NESTED_FLAGS} \
        ${PROJECT_VOLUME_FLAGS} \
        ${MOUNTS} \
        ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
        -w "${WORKDIR}" \
        {{image_name}} \
        {{cmd}}

# Run Claude with a task prompt
# task - the task/prompt to give Claude
# projects - project directories to mount (default: cwd)
run task *projects: _ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    source "{{root}}/scripts/mount-projects.sh"
    setup_projects "{{projects}}"
    echo "Launching Claude Code in riotbox..."
    echo "   Projects: ${PROJECT_SUMMARY}"
    echo "   Task    : {{task}}"
    echo "   Workdir : ${WORKDIR}"
    echo "   Network : enabled (no host credentials mounted)"
    echo ""
    # Checkpoint: commit uncommitted work, tag, and push to a local backup.
    # The backup is a bare repo under ~/.claude-riotbox/backups/ that Claude
    # cannot access. Even if Claude deletes everything and rewrites history,
    # the backup is intact.
    timestamp="$(date +%Y%m%d-%H%M%S)"
    for dir in "${PROJECT_DIRS[@]}"; do
        if ! git -C "${dir}" rev-parse --git-dir &>/dev/null; then
            echo "  WARNING: ${dir} is not a git repo — no checkpoint protection!" >&2
            continue
        fi
        project_name="$(basename "${dir}")"
        # Commit any uncommitted work first
        if ! git -C "${dir}" diff --quiet || ! git -C "${dir}" diff --cached --quiet; then
            git -C "${dir}" add -A && \
            git -C "${dir}" commit -m "checkpoint: pre-claude-${timestamp}"
        fi
        # Tag the current HEAD
        tag_name="claude-checkpoint/${timestamp}"
        git -C "${dir}" tag "${tag_name}"
        # Push everything to a local bare backup repo
        backup_dir="${HOME}/.claude-riotbox/backups/${project_name}.git"
        if [ ! -d "${backup_dir}" ]; then
            git clone --bare "${dir}" "${backup_dir}" 2>/dev/null
        else
            git -C "${dir}" push --force "${backup_dir}" --all --tags 2>/dev/null
        fi
        echo "  checkpoint: ${project_name} → ${tag_name} (backed up)"
    done
    export RIOTBOX_PROJECTS="{{projects}}"
    just -f "{{root_justfile}}" session _launch claude -p '{{task}}'

# Continue the last Claude session
# projects - project directories to mount (default: cwd)
resume *projects: _ensure-image
    cd "{{caller_dir}}" && RIOTBOX_PROJECTS="{{projects}}" just -f "{{root_justfile}}" session _launch claude --continue

# Audit untrusted repo (read-only workspace)
# task - the audit task/prompt to give Claude
# projects - project directories to mount (default: cwd)
audit task *projects: _ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    echo "Launching Claude Code in AUDIT mode (read-only workspace)..."
    export RIOTBOX_READONLY=1
    export RIOTBOX_PROJECTS="{{projects}}"
    just -f "{{root_justfile}}" session _launch claude -p '{{task}}'

# Run with nested podman support (WARNING: disables SELinux confinement)
# task - the task/prompt to give Claude
# projects - project directories to mount (default: cwd)
nested-run task *projects: _ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    echo "WARNING: Nested container mode disables SELinux confinement (--security-opt label=disable)." >&2
    echo "         The container has reduced isolation from the host." >&2
    echo ""
    export RIOTBOX_NESTED=1
    export RIOTBOX_PROJECTS="{{projects}}"
    just -f "{{root_justfile}}" session run '{{task}}' {{projects}}

# Open a shell inside the riotbox
# projects - project directories to mount (default: cwd)
shell *projects: _ensure-image
    cd "{{caller_dir}}" && RIOTBOX_PROJECTS="{{projects}}" just -f "{{root_justfile}}" session _launch bash

# Shell with nested podman support (WARNING: disables SELinux confinement)
# projects - project directories to mount (default: cwd)
nested-shell *projects: _ensure-image
    #!/usr/bin/env bash
    cd "{{caller_dir}}"
    echo "WARNING: Nested container mode disables SELinux confinement." >&2
    export RIOTBOX_NESTED=1
    export RIOTBOX_PROJECTS="{{projects}}"
    just -f "{{root_justfile}}" session _launch bash

# Reset session cache (forces fresh skill/config copy)
# flags - "all" clears all sessions, "force" skips prompt (default: current session)
reset-session *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    source "{{root}}/scripts/mount-projects.sh"
    session_root="${HOME}/.claude-riotbox"
    confirm() { [ "${force}" = true ] && return 0; read -rp "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
    all=false
    force=false
    for flag in {{flags}}; do
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
