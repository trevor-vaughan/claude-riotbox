#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# socket-vars.sh — Build container -v and -e flags for RIOTBOX_SOCKET mode.
#
# Sourced (not executed) by launch.sh. Provides:
#   socket_detect_host_path — print the invoking user's rootless podman
#                             socket path to stdout, return 0 if a
#                             candidate exists, else 1 with empty stdout.
#                             Existence-only via [ -S … ]; does NOT verify
#                             the socket responds.
#   socket_check_alive      — verify a unix socket path serves a working
#                             podman API. Returns 0 if a 5s `podman info`
#                             probe via `--url unix://<path>` exits 0,
#                             else 1. Stderr from the probe is suppressed.
#   socket_flags            — compose the `podman run` flag string for
#                             socket mode. No-op when RIOTBOX_SOCKET is
#                             unset/empty; prints the bind-mount + env-var
#                             flags on success; prints an actionable error
#                             to stderr and returns 1 on failure.
#
# This is a SOURCED library: no top-level `set -euo pipefail` so callers'
# shell options are not modified. Functions use defensive `${VAR:-}`
# expansions and local return paths.
#
# Candidate socket paths, tried in order until one is a live socket:
#   1) $XDG_RUNTIME_DIR/podman/podman.sock         (preferred — user's session)
#   2) /run/user/$(id -u)/podman/podman.sock       (canonical path; useful
#                                                  when XDG_RUNTIME_DIR is
#                                                  unset OR points somewhere
#                                                  the user's podman.socket
#                                                  unit didn't bind to)
#
# Rootful (/run/podman/podman.sock) is INTENTIONALLY NOT considered. With
# `--userns=keep-id`, host uid 0 lives outside the container's user
# namespace, so a root-owned bind-mounted socket appears as the kernel's
# overflowuid (nobody) to the in-container user and is unreachable. The
# helper fails loud so the user enables their own rootless socket rather
# than silently mounting an inaccessible one.
#
# SELinux: the bind mount uses the `:z` shared-label option in socket_flags.
# Without it, the host socket carries a label like `user_runtime_t` and the
# in-container client (running in `container_t`) is denied `connect(2)` —
# the failure surfaces as "permission denied" or, depending on the tool,
# as a misleading "socket owned by an inaccessible uid". `:z` relabels the
# socket file to `container_file_t:s0` (shared), the documented pattern
# for sharing one socket across host + container on a SELinux-enforcing
# host. The relabel survives until the user's podman.socket unit
# regenerates the file, at which point it returns to its default label —
# host podman itself does not depend on the socket's label.
#
# Why socket mode matters: it bind-mounts the host engine's socket into
# the container so in-container podman is a thin remote client. This
# shares image cache, registry auth, and concurrent pulls across sessions
# — at the cost of granting the container effective root on the host (the
# socket IS the engine). See THREAT_MODEL.md for the tradeoff.
# ─────────────────────────────────────────────────────────────────────────────

socket_detect_host_path() {
	local candidate
	if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
		candidate="${XDG_RUNTIME_DIR}/podman/podman.sock"
		if [[ -S "${candidate}" ]]; then
			printf '%s' "${candidate}"
			return 0
		fi
	fi
	candidate="/run/user/$(id -u)/podman/podman.sock"
	if [[ -S "${candidate}" ]]; then
		printf '%s' "${candidate}"
		return 0
	fi
	return 1
}

socket_check_alive() {
	local path="${1:-}"
	if [[ -z "${path}" ]]; then
		return 1
	fi
	local cmd="${CONTAINER_CMD:-podman}"
	# 5s timeout: a working podman socket responds to `info` in well under
	# a second; anything slower indicates a stuck or wrong-protocol socket.
	if timeout 5 "${cmd}" --url "unix://${path}" info >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

socket_flags() {
	if [[ "${RIOTBOX_SOCKET:-}" != "1" ]]; then
		return 0
	fi
	local host_sock
	host_sock="$(socket_detect_host_path)" || host_sock=""
	if [[ -n "${host_sock}" ]] && socket_check_alive "${host_sock}"; then
		# `:z` triggers SELinux relabel to container_file_t:s0 (shared) —
		# without it the in-container `container_t` process is denied
		# connect(2) on the host socket's `user_runtime_t` label even when
		# Unix permissions match. Safe no-op on hosts without SELinux.
		printf -- '-v %s:/run/podman/podman.sock:z -e CONTAINER_HOST=unix:///run/podman/podman.sock' \
			"${host_sock}"
		return 0
	fi
	cat >&2 <<'EOF'
ERROR: RIOTBOX_SOCKET=1 set but no working user podman socket on host.

Socket mode bind-mounts your USER (rootless) podman socket into the
container so in-container podman calls are served by your host engine
(shared image cache, shared registry auth, concurrent across sessions).

The rootful socket at /run/podman/podman.sock is intentionally NOT used:
with --userns=keep-id, a root-owned bind mount is unreachable from the
in-container user (appears as nobody:nobody / permission denied).

To enable your user socket on the host:
    systemctl --user enable --now podman.socket
    loginctl enable-linger "$USER"   # survive logout

Then verify:
    podman --url unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock info

Alternatives:
  - RIOTBOX_NESTED=1 — run a podman engine inside the container (isolated,
    but vfs storage and per-session re-pulls).
  - Default mode — no container engine; for non-podman workloads.
EOF
	return 1
}
