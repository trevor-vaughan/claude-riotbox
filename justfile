# Claude Riotbox — justfile
#
# Usage from anywhere:
#   just -f ~/Projects/Claude_Sandbox/justfile run "fix all lint errors"
#   just -f ~/Projects/Claude_Sandbox/justfile shell
#
# Or add to your .bashrc:
#   alias claude-riotbox='just -f ~/Projects/Claude_Sandbox/justfile'

image_name := env("IMAGE_NAME", "claude-riotbox")
riotbox_dir := justfile_directory()

# Container runtime: prefer podman, fall back to docker
container_cmd := if `command -v podman 2>/dev/null` != "" { "podman" } else { "docker" }

# Podman rootless remaps UIDs by default, which breaks file ownership on
# bind-mounted volumes. --userns=keep-id preserves the host UID inside the
# container so mounted files aren't owned by root/nobody.
# Requires fuse-overlayfs for acceptable performance on large images.
userns_flag := if container_cmd == "podman" { "--userns=keep-id" } else { "" }

# catatonit (podman's --init process) segfaults on EL10 (catatonit-0.2.1-3).
# Not needed — our entrypoint.sh handles signal forwarding.
init_flag := if container_cmd == "podman" { "--init=false" } else { "" }

[private]
default:
    @just --list --unsorted --list-heading $'Claude Riotbox\n\n'

[private]
ensure-image:
    #!/usr/bin/env bash
    if ! {{ container_cmd }} inspect {{ image_name }} &>/dev/null; then
        echo "ERROR: Image '{{ image_name }}' not found. Run 'claude-riotbox build' first." >&2
        exit 1
    fi

# Helper: set up mounts and launch a container with the given command.
# Sourced by run/resume/shell to avoid duplicating the launch block.
[private]
[no-cd]
launch +cmd: ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ riotbox_dir }}/scripts/mount-projects.sh"
    setup_projects "${RIOTBOX_PROJECTS:-}"
    MOUNTS="$("{{ riotbox_dir }}/scripts/detect-mounts.sh")"
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
    {{ container_cmd }} run --rm -it {{ userns_flag }} {{ init_flag }} \
        ${NET_FLAG} \
        ${NESTED_FLAGS} \
        ${PROJECT_VOLUME_FLAGS} \
        ${MOUNTS} \
        ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
        -w "${WORKDIR}" \
        {{ image_name }} \
        {{ cmd }}

[doc("Build the riotbox image (detects your local toolchains)")]
build:
    @{{ riotbox_dir }}/scripts/build.sh

[doc("Rebuild from scratch (no cache)")]
rebuild:
    @DOCKER_EXTRA_ARGS="--no-cache" {{ riotbox_dir }}/scripts/build.sh

[doc('Run Claude: claude-riotbox run "fix the bug" [dir1 dir2 ...]')]
[no-cd]
run task *projects: ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ riotbox_dir }}/scripts/mount-projects.sh"
    setup_projects "{{ projects }}"
    echo "Launching Claude Code in riotbox..."
    echo "   Projects: ${PROJECT_SUMMARY}"
    echo "   Task    : {{ task }}"
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
    export RIOTBOX_PROJECTS="{{ projects }}"
    just -f "{{ justfile() }}" launch claude -p '{{ task }}'

[doc("Continue the last Claude session [dir1 dir2 ...]")]
[no-cd]
resume *projects: ensure-image
    RIOTBOX_PROJECTS="{{ projects }}" just -f "{{ justfile() }}" launch claude --continue

[doc("Audit untrusted repo (read-only workspace) [dir1 dir2 ...]")]
[no-cd]
audit task *projects: ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Launching Claude Code in AUDIT mode (read-only workspace)..."
    # Read-only mount prevents the agent from modifying project files.
    # Network stays enabled because Claude needs the Anthropic API.
    # To also disable network (e.g. for a shell): RIOTBOX_NETWORK=none just shell
    export RIOTBOX_READONLY=1
    export RIOTBOX_PROJECTS="{{ projects }}"
    just -f "{{ justfile() }}" launch claude -p '{{ task }}'

[doc("Run with nested podman support (WARNING: disables SELinux confinement)")]
[no-cd]
nested-run task *projects: ensure-image
    #!/usr/bin/env bash
    set -euo pipefail
    echo "WARNING: Nested container mode disables SELinux confinement (--security-opt label=disable)." >&2
    echo "         The container has reduced isolation from the host." >&2
    echo ""
    export RIOTBOX_NESTED=1
    export RIOTBOX_PROJECTS="{{ projects }}"
    just -f "{{ justfile() }}" run '{{ task }}' {{ projects }}

[doc("Open a shell inside the riotbox [dir1 dir2 ...]")]
[no-cd]
shell *projects: ensure-image
    RIOTBOX_PROJECTS="{{ projects }}" just -f "{{ justfile() }}" launch bash

[doc("Shell with nested podman support (WARNING: disables SELinux confinement)")]
[no-cd]
nested-shell *projects: ensure-image
    #!/usr/bin/env bash
    echo "WARNING: Nested container mode disables SELinux confinement." >&2
    export RIOTBOX_NESTED=1
    export RIOTBOX_PROJECTS="{{ projects }}"
    just -f "{{ justfile() }}" launch bash

[doc("Show what would be mounted from your home directory")]
[no-cd]
mounts:
    @echo "Auto-detected mounts:"
    @{{ riotbox_dir }}/scripts/detect-mounts.sh | while read -r flag path; do echo "  ${path}"; done

[doc("Rewrite Claude's commits to use your git identity [ref|--all]")]
[no-cd]
reown ref="":
    @{{ riotbox_dir }}/scripts/reown-commits.sh {{ ref }}

[doc("Restore a project from its backup after a botched run")]
[no-cd]
restore project_name:
    #!/usr/bin/env bash
    set -euo pipefail
    backup_dir="${HOME}/.claude-riotbox/backups/{{ project_name }}.git"
    if [ ! -d "${backup_dir}" ]; then
        echo "ERROR: no backup found at ${backup_dir}" >&2
        echo "Available backups:" >&2
        ls "${HOME}/.claude-riotbox/backups/" 2>/dev/null | sed 's/\.git$//' | sed 's/^/  /' >&2
        exit 1
    fi
    echo "Backup refs for {{ project_name }}:"
    git -C "${backup_dir}" tag -l 'claude-checkpoint/*' | sort | while read -r tag; do
        echo "  ${tag}  ($(git -C "${backup_dir}" log -1 --format='%s' "${tag}" 2>/dev/null))"
    done
    echo ""
    echo "To restore in your project directory:"
    echo "  git fetch ${backup_dir} --all --tags"
    echo "  git reset --hard claude-checkpoint/<timestamp>"
    echo ""
    echo "Or to clone a fresh copy:"
    echo "  git clone ${backup_dir} {{ project_name }}-restored"

[doc("List available backups")]
backups:
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

[doc("Run tests in a container (setup.sh, install.sh)")]
test *filter:
    #!/usr/bin/env bash
    set -euo pipefail
    test_image="claude-riotbox-test"
    echo "Building test image..."
    {{ container_cmd }} build \
        --build-arg "HOST_UID=$(id -u)" \
        -f "{{ riotbox_dir }}/tests/Dockerfile.test" \
        -t "${test_image}" \
        "{{ riotbox_dir }}"
    echo ""
    echo "Running tests..."
    {{ container_cmd }} run --rm \
        {{ userns_flag }} \
        {{ init_flag }} \
        -v "{{ riotbox_dir }}:/home/testuser/riotbox:ro,z" \
        -e RIOTBOX_DIR=/home/testuser/riotbox \
        "${test_image}" \
        bats {{ if filter == "" { "/home/testuser/riotbox/tests/" } else { filter } }}

[doc("Remove the riotbox image")]
clean:
    {{ container_cmd }} rmi {{ image_name }} 2>/dev/null || true
    @echo "Image removed"
