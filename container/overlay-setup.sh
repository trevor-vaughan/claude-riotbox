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
                local rel="${path#"${upper}"/}"
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
