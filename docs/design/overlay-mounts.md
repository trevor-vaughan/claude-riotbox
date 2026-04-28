# Overlay Mounts: Implementation Plan

## Overview

Mount host projects read-only inside the container. Use fuse-overlayfs to give
Claude a writable `/workspace` where all writes go to a separate "upper"
directory. The host project is never modified directly. After the session exits,
the user reviews changes from the host CLI and explicitly accepts or rejects.

**Podman-only.** Docker has no equivalent for overlay mounts on bind-mounted
host directories. Detect Docker and error.

**Opt-in.** `RIOTBOX_OVERLAY=1` env var or `~/.config/claude-riotbox/config`.

## Architecture

```
Host                                Container
──────────────────────────          ──────────────────────────
project/ ──(bind :ro,z)──────→     /mnt/lower/           (read-only)
session/overlay/ ──(bind :z)──→    /mnt/overlay/         (upper + work)
                                   /workspace/            (fuse-overlayfs)
                                      lower = /mnt/lower
                                      upper = /mnt/overlay/upper
                                      work  = /mnt/overlay/work
```

Overlay data lives at `~/.local/share/claude-riotbox/<session-key>/overlay/`.
Single project uses `overlay/project/{upper,work}`. Multi-project uses
`overlay/<basename>/{upper,work}` per project.

## Implementation steps

Execute in this order. Each step produces a testable checkpoint.

---

### Step 1: `scripts/overlay-resolve.sh` (new file)

Shared helper sourced by overlay-list, overlay-diff, overlay-accept,
overlay-reject. Resolves a project path argument to the overlay directory.

```bash
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
        OVERLAY_DIR="${overlay_base}/project"
    else
        local name
        name="$(basename "${project_path}")"
        if [ -d "${overlay_base}/${name}/upper" ]; then
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
```

---

### Step 2: `scripts/overlay-list.sh` (new file)

Lists all sessions with pending overlay data. Called from host (not container).

```bash
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
        local_added=0 local_modified=0 local_deleted=0
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
```

---

### Step 3: `scripts/overlay-diff.sh` (new file)

Shows what changed in the overlay upper dir vs the lower (host project).

```bash
#!/usr/bin/env bash
set -euo pipefail
# overlay-diff.sh — Show changes in overlay upper dir.
# Usage: overlay-diff.sh [project-path]
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/overlay-resolve.sh"
resolve_overlay "${1:-}"

upper="${OVERLAY_DIR}/upper"
project="${OVERLAY_PROJECT_DIR}"

echo "Overlay diff for: ${project}"
echo ""

found=0
while IFS= read -r path; do
    rel="${path#${upper}/}"
    base="$(basename "${path}")"
    dir="$(dirname "${rel}")"

    if [[ "${base}" == ".wh..wh..opq" ]]; then
        found=$((found + 1))
        echo "D  ${dir}/  (directory replaced)"
    elif [[ "${base}" == .wh.* ]]; then
        found=$((found + 1))
        real_name="${base#.wh.}"
        echo "D  ${dir}/${real_name}"
    elif [ -f "${path}" ]; then
        found=$((found + 1))
        if [ -f "${project}/${rel}" ]; then
            echo "M  ${rel}"
            # Show diff if both are text files
            if file "${path}" | grep -q text && file "${project}/${rel}" | grep -q text; then
                diff -u "${project}/${rel}" "${path}" \
                    --label "a/${rel}" --label "b/${rel}" 2>/dev/null || true
            else
                echo "   (binary file)"
            fi
        else
            echo "A  ${rel}"
            if file "${path}" | grep -q text; then
                # Show the new file content as a unified diff against /dev/null
                diff -u /dev/null "${path}" --label /dev/null --label "b/${rel}" 2>/dev/null || true
            else
                echo "   (binary file)"
            fi
        fi
    fi
done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null | sort)

if [ "${found}" -eq 0 ]; then
    echo "No changes."
fi
```

---

### Step 4: `scripts/overlay-accept.sh` (new file)

Applies overlay upper dir to the real host project. Handles whiteouts.

```bash
#!/usr/bin/env bash
set -euo pipefail
# overlay-accept.sh — Apply overlay changes to host project.
# Usage: overlay-accept.sh [--force] [project-path]
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/overlay-resolve.sh"

FORCE=false
PROJECT_ARG=""
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=true ;;
        *) PROJECT_ARG="${arg}" ;;
    esac
done

resolve_overlay "${PROJECT_ARG}"

upper="${OVERLAY_DIR}/upper"
work="${OVERLAY_DIR}/work"
project="${OVERLAY_PROJECT_DIR}"

if ! overlay_has_changes "${OVERLAY_DIR}"; then
    echo "No overlay changes to apply for ${project}."
    exit 0
fi

echo "Overlay changes to apply to: ${project}"
echo ""

# Dry-run: list what will happen
added=0 modified=0 deleted=0
while IFS= read -r path; do
    rel="${path#${upper}/}"
    base="$(basename "${path}")"
    dir="$(dirname "${rel}")"

    if [[ "${base}" == ".wh..wh..opq" ]]; then
        echo "  REPLACE  ${dir}/"
        deleted=$((deleted + 1))
    elif [[ "${base}" == .wh.* ]]; then
        real_name="${base#.wh.}"
        echo "  DELETE   ${dir}/${real_name}"
        deleted=$((deleted + 1))
    elif [ -f "${path}" ]; then
        if [ -f "${project}/${rel}" ]; then
            echo "  MODIFY   ${rel}"
            modified=$((modified + 1))
        else
            echo "  ADD      ${rel}"
            added=$((added + 1))
        fi
    fi
done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null | sort)

echo ""
echo "Summary: ${added} added, ${modified} modified, ${deleted} deleted"
echo ""

if [ "${FORCE}" != true ]; then
    read -rp "Apply these changes? [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Apply changes
# Process opaque whiteouts first (directory-level), then file whiteouts, then copies.
# This ordering prevents copying into a directory that's about to be replaced.

# Pass 1: opaque dirs
while IFS= read -r path; do
    rel="${path#${upper}/}"
    dir="$(dirname "${rel}")"
    base="$(basename "${path}")"
    if [[ "${base}" == ".wh..wh..opq" ]]; then
        rm -rf "${project}/${dir}"
        mkdir -p "${project}/${dir}"
    fi
done < <(find "${upper}" -name ".wh..wh..opq" 2>/dev/null)

# Pass 2: file whiteouts
while IFS= read -r path; do
    rel="${path#${upper}/}"
    dir="$(dirname "${rel}")"
    base="$(basename "${path}")"
    if [[ "${base}" == .wh.* ]] && [[ "${base}" != ".wh..wh..opq" ]]; then
        real_name="${base#.wh.}"
        rm -rf "${project}/${dir}/${real_name}"
    fi
done < <(find "${upper}" -name ".wh.*" 2>/dev/null)

# Pass 3: copy new/modified files and directories
while IFS= read -r path; do
    rel="${path#${upper}/}"
    base="$(basename "${path}")"
    [[ "${base}" == .wh.* ]] && continue
    if [ -d "${path}" ]; then
        mkdir -p "${project}/${rel}"
    else
        dir="$(dirname "${rel}")"
        mkdir -p "${project}/${dir}"
        # Drop context+xattr: SELinux denies relabel-to onto the host
        # project mount, and container_t-derived labels don't belong on
        # host artifacts anyway.
        cp -a --no-preserve=context,xattr "${path}" "${project}/${rel}"
    fi
done < <(find "${upper}" -mindepth 1 2>/dev/null | sort)

# Clean up overlay data
rm -rf "${upper}" "${work}"
mkdir -p "${upper}" "${work}"

echo "Applied. Overlay data cleaned."
```

---

### Step 5: `scripts/overlay-reject.sh` (new file)

Deletes overlay data without applying.

```bash
#!/usr/bin/env bash
set -euo pipefail
# overlay-reject.sh — Discard overlay changes.
# Usage: overlay-reject.sh [--force] [project-path]
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/overlay-resolve.sh"

FORCE=false
PROJECT_ARG=""
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=true ;;
        *) PROJECT_ARG="${arg}" ;;
    esac
done

resolve_overlay "${PROJECT_ARG}"

if ! overlay_has_changes "${OVERLAY_DIR}"; then
    echo "No overlay changes to discard for ${OVERLAY_PROJECT_DIR}."
    exit 0
fi

echo "Discarding overlay changes for: ${OVERLAY_PROJECT_DIR}"

if [ "${FORCE}" != true ]; then
    read -rp "Discard all changes? This cannot be undone. [y/N] " confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

rm -rf "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"
mkdir -p "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"
echo "Overlay data discarded."
```

---

### Step 6: `container/overlay-setup.sh` (new file)

Entrypoint helper. Sourced inside the container. Provides `overlay_setup` and
`overlay_teardown` functions.

```bash
#!/usr/bin/env bash
# overlay-setup.sh — fuse-overlayfs setup/teardown inside the container.
#
# Sourced by entrypoint.sh. Provides:
#   overlay_setup    — mount fuse-overlayfs at /workspace
#   overlay_teardown — print exit summary with change stats

overlay_setup() {
    # Only activate if the lower mount exists (overlay mode)
    [[ -d /mnt/lower ]] || return 0

    # Disable session branches — overlay IS the isolation
    export SESSION_BRANCH=0

    if [ -d /mnt/lower/.git ] || [ -f /mnt/lower/.git ]; then
        # Single project mode
        fuse-overlayfs \
            -o lowerdir=/mnt/lower \
            -o upperdir=/mnt/overlay/upper \
            -o workdir=/mnt/overlay/work \
            /workspace
        echo "  [overlay] Project mounted with overlay protection."
        echo "  [overlay] Host project is read-only. All writes go to the overlay."
    else
        # Multi-project mode: overlay each subdirectory
        for lower_dir in /mnt/lower/*/; do
            [ -d "${lower_dir}" ] || continue
            local name
            name="$(basename "${lower_dir}")"
            mkdir -p "/workspace/${name}"
            fuse-overlayfs \
                -o "lowerdir=${lower_dir}" \
                -o "upperdir=/mnt/overlay/${name}/upper" \
                -o "workdir=/mnt/overlay/${name}/work" \
                "/workspace/${name}"
            echo "  [overlay] ${name} mounted with overlay protection."
        done
    fi
}

overlay_teardown() {
    [[ -d /mnt/lower ]] || return 0

    echo ""
    echo "  [overlay] Session complete. Changes preserved in overlay."

    # Collect stats from upper dir(s)
    local upper_dirs=()
    if [ -d /mnt/overlay/upper ]; then
        upper_dirs=(/mnt/overlay/upper)
    else
        for d in /mnt/overlay/*/upper; do
            [ -d "${d}" ] && upper_dirs+=("${d}")
        done
    fi

    local added=0 modified=0 deleted=0
    for upper in "${upper_dirs[@]}"; do
        local lower
        if [ "${upper}" = "/mnt/overlay/upper" ]; then
            lower="/mnt/lower"
        else
            local name
            name="$(basename "$(dirname "${upper}")")"
            lower="/mnt/lower/${name}"
        fi
        while IFS= read -r path; do
            local base
            base="$(basename "${path}")"
            if [[ "${base}" == .wh.* ]]; then
                deleted=$((deleted + 1))
            elif [ -f "${path}" ]; then
                local rel="${path#${upper}/}"
                if [ -f "${lower}/${rel}" ]; then
                    modified=$((modified + 1))
                else
                    added=$((added + 1))
                fi
            fi
        done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null)
    done

    if [ $((added + modified + deleted)) -gt 0 ]; then
        echo "    ${modified} modified, ${added} added, ${deleted} deleted"
    else
        echo "    No changes detected."
    fi

    echo ""
    echo "  Next steps (run from your host):"
    echo "    claude-riotbox overlay-diff      Review changes"
    echo "    claude-riotbox overlay-accept     Apply to project"
    echo "    claude-riotbox overlay-reject     Discard changes"
}
```

---

### Step 7: Modify `scripts/mount-projects.sh`

In `setup_projects()`, after `resolve_projects` is called (line 143) and before
the existing mount logic (lines 145-161), add an overlay branch. The overlay
branch replaces the normal mount logic entirely — it must be an if/else, not
additive.

**Replace lines 145-161** (from `# RIOTBOX_READONLY=1` through the closing
`fi` of the multi-project block) with:

```bash
    if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
        # ── Overlay mode: project read-only + overlay data volume ─────
        if [ ${#PROJECT_DIRS[@]} -eq 1 ]; then
            PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:/mnt/lower:ro,z"
            local overlay_dir="${RIOTBOX_SESSION_DIR}/overlay/project"
            mkdir -p "${overlay_dir}/upper" "${overlay_dir}/work"
            PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${overlay_dir}:/mnt/overlay:z"
        else
            for dir in "${PROJECT_DIRS[@]}"; do
                local name
                name="$(basename "${dir}")"
                PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:/mnt/lower/${name}:ro,z"
                local overlay_dir="${RIOTBOX_SESSION_DIR}/overlay/${name}"
                mkdir -p "${overlay_dir}/upper" "${overlay_dir}/work"
                PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${overlay_dir}:/mnt/overlay/${name}:z"
            done
        fi
    else
        # ── Normal mode: direct bind mount ────────────────────────────
        # RIOTBOX_READONLY=1 mounts projects read-only (for untrusted repos)
        local mount_suffix=":z"
        if [ "${RIOTBOX_READONLY:-}" = "1" ]; then
            mount_suffix=":ro,z"
        fi

        if [ ${#PROJECT_DIRS[@]} -eq 1 ]; then
            PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:/workspace${mount_suffix}"
        else
            for dir in "${PROJECT_DIRS[@]}"; do
                local name
                name="$(basename "${dir}")"
                PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:/workspace/${name}${mount_suffix}"
            done
        fi
    fi
```

The rest of `setup_projects()` (session dir creation, sync, container name)
stays unchanged.

---

### Step 8: Modify `.taskfiles/scripts/launch.sh`

Three additions, in this order within the file:

**A. Docker detection** — Insert after line 15 (`setup_projects` call), before
line 16 (`MOUNTS`):

```bash
# RIOTBOX_OVERLAY=1 requires podman (Docker has no equivalent)
if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
    if [ "$(basename "${CONTAINER_CMD}")" != "podman" ]; then
        echo "ERROR: Overlay mode requires podman. Docker is not supported." >&2
        exit 1
    fi
fi
```

**B. Concurrent session guard** — Insert immediately after the Docker detection
block above:

```bash
# Overlay guard: block launch if pending overlay data exists
if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
    overlay_base="${RIOTBOX_SESSION_DIR}/overlay"
    if [ -d "${overlay_base}" ]; then
        for overlay_subdir in "${overlay_base}"/*/; do
            [ -d "${overlay_subdir}/upper" ] || continue
            if [ -n "$(ls -A "${overlay_subdir}/upper" 2>/dev/null)" ]; then
                echo "ERROR: Pending overlay data exists. Accept or reject before starting a new session." >&2
                echo "  claude-riotbox overlay-diff      Review changes" >&2
                echo "  claude-riotbox overlay-accept     Apply to project" >&2
                echo "  claude-riotbox overlay-reject     Discard changes" >&2
                exit 1
            fi
        done
    fi
fi
```

**C. Overlay flags** — Insert after the `NESTED_FLAGS` block (after line 41),
before the `container run` command:

```bash
# RIOTBOX_OVERLAY=1 needs FUSE device access for fuse-overlayfs
OVERLAY_FLAGS=""
if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
    OVERLAY_FLAGS="--device /dev/fuse"
fi
```

**D. Add `${OVERLAY_FLAGS}` to the container run command** — On line 44 (the
`${CONTAINER_CMD} run` line), add `${OVERLAY_FLAGS}` alongside
`${NESTED_FLAGS}`:

```bash
# shellcheck disable=SC2086  # intentional word splitting for multi-flag vars
${CONTAINER_CMD} run --rm -it ${USERNS_FLAG} ${INIT_FLAG} \
    --name "${CONTAINER_NAME}" \
    ${NET_FLAG} \
    ${NESTED_FLAGS} \
    ${OVERLAY_FLAGS} \
    ${PROJECT_VOLUME_FLAGS} \
    ${MOUNTS} \
    ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
    -e SESSION_ID="${SESSION_ID}" \
    ${SESSION_BRANCH:+-e SESSION_BRANCH="${SESSION_BRANCH}"} \
    -w "${WORKDIR}" \
    "${IMAGE_NAME}" \
    "$@"
```

---

### Step 9: Modify `container/entrypoint.sh`

**A. Source overlay-setup.sh** — Add after line 37 (`source session-branch.sh`):

```bash
source "${RIOTBOX_SCRIPT_DIR}/overlay-setup.sh"
```

**B. Call overlay_setup** — Add before line 105 (`session_branch_setup`):

```bash
# Overlay: mount fuse-overlayfs at /workspace (sets SESSION_BRANCH=0 if active)
overlay_setup
```

**C. Call overlay_teardown** — Add after line 115 (`_exit_code=$?`), before
line 120 (`session_branch_teardown`):

```bash
# Overlay: print exit summary with change stats
overlay_teardown
```

Result: the entrypoint's main-command section becomes:

```bash
overlay_setup
session_branch_setup

if [ $# -eq 0 ]; then
    bash
else
    "$@"
fi
_exit_code=$?

overlay_teardown
session_branch_teardown

exit $_exit_code
```

---

### Step 10: Modify `Dockerfile`

Add the overlay-setup.sh COPY alongside the other entrypoint files. Insert
after line 373 (`COPY container/session-branch.sh`):

```dockerfile
COPY --chown=claude:claude container/overlay-setup.sh /home/claude/.riotbox/overlay-setup.sh
```

Update the `chmod` on line 375-376 to include the new file:

```dockerfile
RUN chmod +x /home/claude/.riotbox/entrypoint.sh /home/claude/.riotbox/inject-claude-md.sh \
    /home/claude/.riotbox/session-branch.sh /home/claude/.riotbox/overlay-setup.sh
```

---

### Step 11: Modify `.taskfiles/session.yml`

Add four new tasks after `reset-session` (line 129):

```yaml
  overlays:
    desc: List sessions with pending overlay data
    dir: "{{.USER_WORKING_DIR}}"
    env:
      ROOT_DIR: "{{.ROOT_DIR}}"
    cmd: "{{.ROOT_DIR}}/scripts/overlay-list.sh"

  overlay-diff:
    desc: Show changes in overlay (vs host project)
    dir: "{{.USER_WORKING_DIR}}"
    vars:
      ARGS: "{{.ARGS | default .CLI_ARGS}}"
    env:
      ROOT_DIR: "{{.ROOT_DIR}}"
    cmd: "{{.ROOT_DIR}}/scripts/overlay-diff.sh {{.ARGS}}"

  overlay-accept:
    desc: Apply overlay changes to host project
    dir: "{{.USER_WORKING_DIR}}"
    vars:
      ARGS: "{{.ARGS | default .CLI_ARGS}}"
    env:
      ROOT_DIR: "{{.ROOT_DIR}}"
    cmd: "{{.ROOT_DIR}}/scripts/overlay-accept.sh {{.ARGS}}"

  overlay-reject:
    desc: Discard overlay changes
    dir: "{{.USER_WORKING_DIR}}"
    vars:
      ARGS: "{{.ARGS | default .CLI_ARGS}}"
    env:
      ROOT_DIR: "{{.ROOT_DIR}}"
    cmd: "{{.ROOT_DIR}}/scripts/overlay-reject.sh {{.ARGS}}"
```

---

### Step 12: Modify `Taskfile.yml`

Add four aliases after `session-reset` (line 142):

```yaml
  overlays:
    desc: "Alias for session:overlays"
    cmds:
      - task: session:overlays

  overlay-diff:
    desc: "Alias for session:overlay-diff"
    cmds:
      - task: session:overlay-diff
        vars:
          ARGS: "{{.CLI_ARGS}}"

  overlay-accept:
    desc: "Alias for session:overlay-accept"
    cmds:
      - task: session:overlay-accept
        vars:
          ARGS: "{{.CLI_ARGS}}"

  overlay-reject:
    desc: "Alias for session:overlay-reject"
    cmds:
      - task: session:overlay-reject
        vars:
          ARGS: "{{.CLI_ARGS}}"
```

---

### Step 13: Modify `install.sh`

**A. Add to usage text** — After line 38 (`session-reset`) in the usage
heredoc, add:

```
  overlays                     List sessions with pending overlay data
  overlay-diff [project]       Show overlay changes vs host project
  overlay-accept [project]     Apply overlay changes to host project
  overlay-reject [project]     Discard overlay changes
```

**B. Add to case statement** — After the `session-reset` case (line 85), add:

```bash
    overlays)
        run_task overlays
        ;;
    overlay-diff)
        run_task overlay-diff -- "$@"
        ;;
    overlay-accept)
        run_task overlay-accept -- "$@"
        ;;
    overlay-reject)
        run_task overlay-reject -- "$@"
        ;;
```

---

### Step 14: Tests

Create `tests/overlay.venom.yml`. These tests mock the overlay directory
structure on the host filesystem (no container needed). They test the
accept/reject/diff/list scripts by creating fake upper dirs with files and
whiteouts.

Test cases:

```
Positive:
1.  Accept copies new files from upper to project
2.  Accept overwrites modified files in project
3.  Accept deletes files marked with .wh.<name> whiteouts
4.  Accept handles .wh..wh..opq (opaque dir replacement)
5.  Accept preserves file permissions (cp -a)
6.  Accept cleans up upper/work dirs after apply
7.  Reject deletes upper/work dirs
8.  Reject --force skips confirmation
9.  Diff shows A for added files
10. Diff shows M for modified files
11. Diff shows D for deleted files (whiteouts)
12. List shows pending overlays with file counts
13. List exits 0 when overlays exist
14. Resolve finds overlay by project path

Negative:
15. Accept with no changes exits cleanly
16. Reject with no changes exits cleanly
17. List exits 1 when no overlays exist
18. Resolve errors when project path has no session
19. Resolve errors when session has no overlay data
20. Docker detection in launch.sh errors for non-podman
```

Test helper pattern: each test creates a temp dir, sets up a fake session
structure (`session-key/overlay/project/{upper,work}`), and a fake project dir.
Runs the script with `ROOT_DIR` pointing to the workspace root. Asserts on exit
code and stdout content.

Example test structure for accept:

```yaml
- name: Accept copies new files from upper to project
  steps:
    - type: exec
      script: |
        TEST_DIR="$(mktemp -d)"
        trap 'rm -rf "${TEST_DIR}"' EXIT

        # Create fake project
        PROJECT="${TEST_DIR}/myproject"
        mkdir -p "${PROJECT}"
        echo "original" > "${PROJECT}/existing.txt"

        # Create fake session with overlay data
        SESSION="${TEST_DIR}/session"
        OVERLAY="${SESSION}/overlay/project"
        mkdir -p "${OVERLAY}/upper" "${OVERLAY}/work"
        echo "new file content" > "${OVERLAY}/upper/newfile.txt"

        # Create .projects metadata
        echo "${PROJECT}" > "${SESSION}/.projects"

        # Set XDG_DATA_HOME so resolve_projects finds our fake session
        export XDG_DATA_HOME="${TEST_DIR}/data"
        mkdir -p "${XDG_DATA_HOME}/claude-riotbox"
        # Compute the session key the same way mount-projects.sh does
        session_key="$(echo "${PROJECT}" | sed 's|/|-|g; s|^-||')"
        ln -s "${SESSION}" "${XDG_DATA_HOME}/claude-riotbox/${session_key}"

        export ROOT_DIR="{{.riotbox_dir}}"
        echo "y" | "{{.riotbox_dir}}/scripts/overlay-accept.sh" "${PROJECT}"

        # Verify
        [ -f "${PROJECT}/newfile.txt" ]
        [ "$(cat "${PROJECT}/newfile.txt")" = "new file content" ]
        [ "$(cat "${PROJECT}/existing.txt")" = "original" ]
        echo "accept_new_file=pass"
      assertions:
        - result.code ShouldEqual 0
        - result.systemout ShouldContainSubstring "accept_new_file=pass"
```

---

### Step 15: Update `README.md`

Add a section under the existing session management docs:

```markdown
### Overlay mode (podman-only)

Overlay mode mounts your project read-only and uses fuse-overlayfs to capture
all changes in a separate layer. The host project is never modified directly.

```bash
# Enable for a single session
RIOTBOX_OVERLAY=1 claude-riotbox shell .

# Enable permanently
echo 'RIOTBOX_OVERLAY=1' >> ~/.config/claude-riotbox/config
```

After the session exits, review and apply or discard:

```bash
claude-riotbox overlays          # List pending overlays
claude-riotbox overlay-diff      # See what changed
claude-riotbox overlay-accept    # Apply changes to your project
claude-riotbox overlay-reject    # Discard all changes
```

> Overlay mode requires podman. Docker is not supported due to differences in
> how it handles bind-mounted overlays.
```

---

## Edge cases

| Scenario | Behavior |
|----------|----------|
| Resume with overlay | Upper dir persists; fuse-overlayfs re-mounts it. Claude sees previous changes. |
| Accept then resume | Upper dir cleaned by accept. Next session starts fresh. |
| Reject then resume | Upper dir cleaned by reject. Next session starts fresh. |
| Launch with pending overlay | Blocked. Must accept/reject first. |
| Non-overlay launch with pending overlay | Allowed (independent). |
| Session-remove | Deletes session dir including overlay data. |
| `.git` writes by Claude | Go to upper dir. Host `.git` untouched. |
| Git push by Claude | Reads remote from overlaid config. Push reaches real remote. |
| Accept partial changes | Not supported v1. All-or-nothing per project. |

## Constraints and non-goals

- No Dockerfile changes beyond COPYing the new script (fuse-overlayfs already installed)
- No changes to the checkpoint system (orthogonal)
- No changes to the reown system (orthogonal)
- No interactive prompt on container exit (just a status message)
- No partial accept (v1 is all-or-nothing)
- Docker is not supported (error clearly)
