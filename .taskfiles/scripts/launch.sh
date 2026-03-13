#!/usr/bin/env bash
set -euo pipefail
# Set up mounts and launch a container with the given command.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Optional env: RIOTBOX_PROJECTS, RIOTBOX_NETWORK, RIOTBOX_NESTED
# Arguments: command and args to run inside the container

# Source user config for persistent defaults (e.g. RIOTBOX_NETWORK=none).
# Env vars set by the caller take precedence over the config file.
RIOTBOX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-riotbox/config"
# shellcheck disable=SC1090
[ -f "${RIOTBOX_CONFIG}" ] && source "${RIOTBOX_CONFIG}"

source "${ROOT_DIR}/scripts/mount-projects.sh"
setup_projects "${RIOTBOX_PROJECTS:-}"
MOUNTS="$("${ROOT_DIR}/scripts/detect-mounts.sh")"

# RIOTBOX_OVERLAY=1 requires podman (Docker has no equivalent)
if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
    if [ "$(basename "${CONTAINER_CMD}")" != "podman" ]; then
        echo "ERROR: Overlay mode requires podman. Docker is not supported." >&2
        exit 1
    fi
fi

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

# Generate a unique session identifier for this container run.
# Passed into the container so the entrypoint can name the session branch.
SESSION_ID="$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# Podman rootless: --userns=keep-id preserves host UID inside the container
USERNS_FLAG=""
INIT_FLAG=""
if [ "$(basename "${CONTAINER_CMD}")" = "podman" ]; then
    USERNS_FLAG="--userns=keep-id"
    # catatonit (podman's --init) segfaults on EL10; not needed anyway
    INIT_FLAG="--init=false"
fi

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

# RIOTBOX_OVERLAY=1 needs FUSE device access for fuse-overlayfs
OVERLAY_FLAGS=""
if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
    OVERLAY_FLAGS="--device /dev/fuse"
fi

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
