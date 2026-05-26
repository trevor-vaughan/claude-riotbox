#!/usr/bin/env bash
set -euo pipefail
# Set up mounts and launch a container with the given command.
# Required env: CONTAINER_CMD, IMAGE_NAME, ROOT_DIR
# Optional env: RIOTBOX_PROJECTS, RIOTBOX_NETWORK, RIOTBOX_NESTED, RIOTBOX_SOCKET
# Arguments: command and args to run inside the container

# Source config for persistent defaults (e.g. RIOTBOX_NETWORK=none). These
# files use the `: "${VAR:=default}"` pattern, so sourcing the user (XDG) file
# BEFORE the system (/etc) file yields the documented precedence:
#   env  >  $XDG_CONFIG_HOME/riotbox  >  /etc/riotbox  >  built-in default
# (env wins because := only assigns when unset; XDG wins over /etc because a
# value it sets first survives the later /etc source). RIOTBOX_SYSCONF_DIR
# overrides the system dir (default /etc/riotbox) for relocatable installs/tests.
RIOTBOX_CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/riotbox/config"
RIOTBOX_CONFIG_SYSTEM="${RIOTBOX_SYSCONF_DIR:-/etc/riotbox}/config"
# shellcheck disable=SC1090
[[ -f "${RIOTBOX_CONFIG_USER}" ]] && source "${RIOTBOX_CONFIG_USER}"
# shellcheck disable=SC1090,SC1091
[[ -f "${RIOTBOX_CONFIG_SYSTEM}" ]] && source "${RIOTBOX_CONFIG_SYSTEM}"

# Mutual-exclusion guard for the two container-runtime delegation modes.
# Fires before any side-effectful work (mount setup, image lookup, podman
# invocation) so an obviously-broken env never reaches the run command.
if [[ "${RIOTBOX_NESTED:-}" = "1" ]] && [[ "${RIOTBOX_SOCKET:-}" = "1" ]]; then
	cat >&2 <<'EOF'
ERROR: RIOTBOX_NESTED=1 and RIOTBOX_SOCKET=1 are mutually exclusive.

  RIOTBOX_NESTED=1   Run a podman engine inside the container. Isolated,
                     uses vfs storage, every session re-pulls images.
  RIOTBOX_SOCKET=1   Bind-mount the host podman socket. Shared image
                     cache and auth across sessions; container has
                     effective root on the host.

Pick one. See README "Container runtime modes" for trade-offs.
EOF
	exit 1
fi

source "${ROOT_DIR}/scripts/mount-projects.sh"
setup_projects "${RIOTBOX_PROJECTS:-}"
MOUNTS="$("${ROOT_DIR}/scripts/detect-mounts.sh")"

# RIOTBOX_OVERLAY=1 requires podman (Docker has no equivalent)
if [[ "${RIOTBOX_OVERLAY:-}" = "1" ]]; then
	if [[ "$(basename "${CONTAINER_CMD}")" != "podman" ]]; then
		echo "ERROR: Overlay mode requires podman. Docker is not supported." >&2
		exit 1
	fi
fi

# Overlay guard: block launch if pending overlay data exists
if [[ "${RIOTBOX_OVERLAY:-}" = "1" ]]; then
	overlay_base="${RIOTBOX_SESSION_DIR}/overlay"
	if [[ -d "${overlay_base}" ]]; then
		for overlay_subdir in "${overlay_base}"/*/; do
			[[ -d "${overlay_subdir}/upper" ]] || continue
			overlay_upper_contents="$(ls -A "${overlay_subdir}/upper" 2>/dev/null)"
			if [[ -n "${overlay_upper_contents}" ]]; then
				echo "ERROR: Pending overlay data exists. Accept or reject before starting a new session." >&2
				echo "  riotbox overlay-diff      Review changes" >&2
				echo "  riotbox overlay-accept     Apply to project" >&2
				echo "  riotbox overlay-reject     Discard changes" >&2
				exit 1
			fi
		done
	fi
fi

# Generate a unique session identifier for this container run.
# Passed into the container so the entrypoint can name the session branch.
_session_ts="$(date +%Y%m%d-%H%M%S)"
_session_rand="$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SESSION_ID="${_session_ts}-${_session_rand}"

# Podman rootless --userns=keep-id preserves the host user's UID/GID inside
# the container. Both uid= and gid= are passed explicitly: podman's default
# substitution fills the inner GID slot from host_uid (not host_gid), so when
# host uid != gid (a user whose primary group differs from their useradd-
# implicit group) the kernel-level gid_map keep-id slot lands on host_uid
# rather than the real host_gid.
#
# --user is layered on top of --userns=keep-id for a second, independent
# reason: podman's /etc/passwd rewrite for keep-id stamps the image's user
# entry as `llm:x:HOST_UID:HOST_UID` regardless of `:gid=`, so the
# process started from the image's USER directive would run with
# egid=HOST_UID, not HOST_GID — even though the kernel gid_map is now
# correct. --user X:Y bypasses /etc/passwd and forces the process's runtime
# uid/gid directly, so id -g returns HOST_GID, nested-podman-setup.sh
# derives /etc/subgid by splitting around the right value, and inner
# podman's newgidmap call references the kernel's keep-id slot. Without
# both knobs set, inner podman fails with `newgidmap: write to gid_map
# failed: Operation not permitted` on the first `podman run`. With
# host uid == host gid both are no-ops; with mismatched uid/gid both are
# load-bearing. The Dockerfile builds llm with the host user's UID *and*
# GID (build.sh threads both as build-args), so an image built for the
# running user has its USER entry already aligned and these flags become
# no-ops; they remain in place as defense for images built without
# HOST_GID (older builds, manual `podman build` invocations, or an image
# shared across hosts with different uid/gid combinations).
#
# Default mode uses the bare 1-uid mapping; nested mode widens to
# size=65536 so the inner container can carve out subordinate uids for
# itself while this outer container still owns its bind-mounted host paths
# (project dirs and the RiotBox session dir keep their on-disk owner:group).
USERNS_FLAG=""
INIT_FLAG=""
USER_FLAG=""
if [[ "$(basename "${CONTAINER_CMD}")" = "podman" ]]; then
	_uid="$(id -u)"
	_gid="$(id -g)"
	if [[ "${RIOTBOX_NESTED:-}" = "1" ]]; then
		USERNS_FLAG="--userns=keep-id:uid=${_uid},gid=${_gid},size=65536"
	else
		USERNS_FLAG="--userns=keep-id:uid=${_uid},gid=${_gid}"
	fi
	USER_FLAG="--user ${_uid}:${_gid}"
	# catatonit (podman's --init) segfaults on EL10; not needed anyway
	INIT_FLAG="--init=false"
fi

# RIOTBOX_NETWORK=none disables outbound network (prevents exfiltration)
NET_FLAG=""
if [[ "${RIOTBOX_NETWORK:-}" = "none" ]]; then
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
if [[ "${RIOTBOX_NESTED:-}" = "1" ]]; then
	NESTED_FLAGS="--device /dev/fuse \
        --device /dev/net/tun \
        --security-opt label=disable \
        --security-opt unmask=ALL \
        --cap-add=SYS_ADMIN"
fi

# RIOTBOX_OVERLAY=1 needs FUSE device access for fuse-overlayfs
OVERLAY_FLAGS=""
if [[ "${RIOTBOX_OVERLAY:-}" = "1" ]]; then
	OVERLAY_FLAGS="--device /dev/fuse"
fi

# RIOTBOX_SOCKET=1 bind-mounts the host's podman socket and sets
# CONTAINER_HOST so in-container podman is a remote client of the host
# engine. Detection and the failure path live in socket-vars.sh — a missing
# or non-responsive socket fails loud here, not silently at runtime.
SOCKET_FLAGS=""
if [[ "${RIOTBOX_SOCKET:-}" = "1" ]]; then
	# shellcheck source=./socket-vars.sh disable=SC1091  # source path resolves only from libexec/; safe to skip follow
	source "$(dirname "${BASH_SOURCE[0]}")/socket-vars.sh"
	SOCKET_FLAGS="$(socket_flags)" || exit 1
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

# shellcheck source=./passthrough-vars.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/passthrough-vars.sh"
# Must run before passthrough_flags: KEY=VALUE entries are exported into
# this shell's env so the podman child process (which receives `-e KEY`
# without a value) can read them by name. Inside a subshell the export
# would die — that's why this call is direct, not $(...).
# Failure (invalid KEY) propagates via `return 1`; `set -euo pipefail`
# at the top of this file aborts the launch. Do NOT add `|| true` or
# wrap this call in a subshell — either would silently swallow KEY
# validation failures and start the container with missing env vars.
passthrough_export
PASSTHROUGH_FLAGS="$(passthrough_flags)"

# Must run before credfile_flags(): if the user accepts, this exports
# GOOGLE_APPLICATION_CREDENTIALS, which credfile-vars.sh then picks up and
# turns into the bind-mount + env-rewrite pair.
# shellcheck source=./vertex-adc-prompt.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/vertex-adc-prompt.sh"
vertex_adc_prompt

# shellcheck source=./credfile-vars.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/credfile-vars.sh"
CREDFILE_FLAGS="$(credfile_flags)"

# shellcheck disable=SC2086,SC2248  # intentional word splitting for multi-flag vars
# shellcheck disable=SC2154  # IMAGE_NAME is required env — set by the caller (riotbox CLI)
${CONTAINER_CMD} run --rm -it --log-driver=none ${USERNS_FLAG} ${USER_FLAG} ${INIT_FLAG} \
	--name "${CONTAINER_NAME}" \
	${NET_FLAG} \
	${NESTED_FLAGS} \
	${OVERLAY_FLAGS} \
	${SOCKET_FLAGS} \
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
