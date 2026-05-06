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

# Podman rootless: --userns=keep-id preserves host UID inside the container.
# Default mode uses the bare 1-uid mapping; nested mode widens to size=65536
# so the inner container can carve out subordinate uids for itself while
# this outer container still owns its bind-mounted host paths (project dirs
# and the riotbox session dir keep their tvaughan:tvaughan ownership).
USERNS_FLAG=""
INIT_FLAG=""
if [ "$(basename "${CONTAINER_CMD}")" = "podman" ]; then
    if [ "${RIOTBOX_NESTED:-}" = "1" ]; then
        USERNS_FLAG="--userns=keep-id:size=65536"
    else
        USERNS_FLAG="--userns=keep-id"
    fi
    # catatonit (podman's --init) segfaults on EL10; not needed anyway
    INIT_FLAG="--init=false"
fi

# RIOTBOX_NETWORK=none disables outbound network (prevents exfiltration)
NET_FLAG=""
if [ "${RIOTBOX_NETWORK:-}" = "none" ]; then
    NET_FLAG="--network=none"
fi

# RIOTBOX_NESTED=1 enables podman-in-podman. This is intentionally a much
# broader trust model than the default — turning it on requires loosening
# every protection that prevents an inner OCI runtime from initializing.
# All of these are scoped to nested mode; default mode keeps the tighter
# profile (single-uid keep-id, masked /proc/sys, no SYS_ADMIN cap).
#
#   --device /dev/fuse                 fuse-overlayfs (outer) storage driver
#   --device /dev/net/tun              pasta networking (TAP device)
#   --security-opt label=disable       SELinux confinement off (transition
#                                      between outer container_t and inner
#                                      container processes is disallowed
#                                      under default policy)
#   --security-opt unmask=ALL          Removes every default OCI mask AND
#                                      readonly path on /proc and /sys.
#                                      Inner crun's setup writes to
#                                      /proc/sys/net/ipv4/ping_group_range
#                                      and mounts a fresh /proc, neither of
#                                      which works under the default mask.
#                                      Narrower targets (unmask=/proc/sys
#                                      or unmask=…ping_group_range) DO NOT
#                                      WORK — verified empirically.
#   --cap-add=SYS_ADMIN                Inner crun calls sethostname() and
#                                      mount() during container setup; the
#                                      default rootless bounding set
#                                      excludes CAP_SYS_ADMIN. The cap is
#                                      bounded by the outer userns.
#
# Inner storage MUST be vfs (not overlay/fuse-overlayfs); the inner crun
# fails on `mkdir /run/secrets` under nested overlay. The vfs override,
# /etc/sub{u,g}id alignment, and v3 file caps on newuidmap/newgidmap (v2
# caps don't apply when the running process isn't root in its userns) are
# handled at runtime by container/nested-podman-setup.sh.
NESTED_FLAGS=""
if [ "${RIOTBOX_NESTED:-}" = "1" ]; then
    NESTED_FLAGS="--device /dev/fuse \
        --device /dev/net/tun \
        --security-opt label=disable \
        --security-opt unmask=ALL \
        --cap-add=SYS_ADMIN"
fi

# RIOTBOX_OVERLAY=1 needs FUSE device access for fuse-overlayfs
OVERLAY_FLAGS=""
if [ "${RIOTBOX_OVERLAY:-}" = "1" ]; then
    OVERLAY_FLAGS="--device /dev/fuse"
fi

# ── SELinux pre-labeling ─────────────────────────────────────────────────────
# Files created by setup_projects (mkdir, cp) inherit the parent directory's
# SELinux type (e.g. user_home_t). The :z mount flag asks the runtime to
# relabel at start, but with nested mounts the ordering is non-deterministic —
# the container process can hit files before their mount's relabel completes.
# In Enforcing mode this produces AVC denials; in Permissive mode the denials
# are logged without blocking, but still pollute the audit log and mask real
# issues. Pre-label everything we created so the context is already correct.
#
# Guard on chcon (the tool we actually call), not getenforce — a system can
# have SELinux in the kernel without the getenforce binary installed, but if
# chcon is missing there is nothing we can do regardless.
if command -v chcon &>/dev/null; then
    chcon -R -t container_file_t "${RIOTBOX_SESSION_DIR}" 2>/dev/null || true
fi

# shellcheck source=./passthrough-vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/passthrough-vars.sh"
PASSTHROUGH_FLAGS="$(passthrough_flags)"

# Must run before credfile_flags(): if the user accepts, this exports
# GOOGLE_APPLICATION_CREDENTIALS, which credfile-vars.sh then picks up and
# turns into the bind-mount + env-rewrite pair.
# shellcheck source=./vertex-adc-prompt.sh
source "$(dirname "${BASH_SOURCE[0]}")/vertex-adc-prompt.sh"
vertex_adc_prompt

# shellcheck source=./credfile-vars.sh
source "$(dirname "${BASH_SOURCE[0]}")/credfile-vars.sh"
CREDFILE_FLAGS="$(credfile_flags)"

# shellcheck disable=SC2086  # intentional word splitting for multi-flag vars
${CONTAINER_CMD} run --rm -it --log-driver=none ${USERNS_FLAG} ${INIT_FLAG} \
    --name "${CONTAINER_NAME}" \
    ${NET_FLAG} \
    ${NESTED_FLAGS} \
    ${OVERLAY_FLAGS} \
    ${PROJECT_VOLUME_FLAGS} \
    ${MOUNTS} \
    ${PASSTHROUGH_FLAGS} \
    ${CREDFILE_FLAGS} \
    -e SESSION_ID="${SESSION_ID}" \
    ${SESSION_BRANCH:+-e SESSION_BRANCH="${SESSION_BRANCH}"} \
    ${RIOTBOX_PLUGINS:+-e RIOTBOX_PLUGINS="${RIOTBOX_PLUGINS}"} \
    ${RIOTBOX_AGENT:+-e RIOTBOX_AGENT="${RIOTBOX_AGENT}"} \
    ${RIOTBOX_NESTED:+-e RIOTBOX_NESTED="${RIOTBOX_NESTED}"} \
    -w "${WORKDIR}" \
    "${IMAGE_NAME}" \
    "$@"
