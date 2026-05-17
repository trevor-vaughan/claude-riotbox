#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# socket-vars.sh — Build container -v and -e flags for RIOTBOX_SOCKET mode.
#
# Sourced (not executed) by launch.sh. Provides:
#   socket_detect_host_path — print the host's podman socket path to stdout,
#                             return 0 if a candidate exists, else 1 with
#                             empty stdout. Existence-only via [ -S … ];
#                             does NOT verify the socket responds.
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
# Candidate socket paths (in order):
#   1) $XDG_RUNTIME_DIR/podman/podman.sock   (rootless, the common case)
#   2) /run/podman/podman.sock               (rootful)
#
# Why this matters: socket mode bind-mounts the host engine's socket into
# the container so in-container podman is a thin remote client. This
# shares image cache, registry auth, and concurrent pulls across sessions
# — at the cost of granting the container effective root on the host (the
# socket IS the engine). See THREAT_MODEL.md for the tradeoff.
# ─────────────────────────────────────────────────────────────────────────────

socket_detect_host_path() {
    local xdg="${XDG_RUNTIME_DIR:-}"
    local candidate
    if [ -n "${xdg}" ]; then
        candidate="${xdg}/podman/podman.sock"
        if [ -S "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    fi
    candidate="/run/podman/podman.sock"
    if [ -S "${candidate}" ]; then
        printf '%s' "${candidate}"
        return 0
    fi
    return 1
}

socket_check_alive() {
    local path="${1:-}"
    if [ -z "${path}" ]; then
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
    if [ "${RIOTBOX_SOCKET:-}" != "1" ]; then
        return 0
    fi
    local host_sock
    host_sock="$(socket_detect_host_path)" || host_sock=""
    if [ -n "${host_sock}" ] && socket_check_alive "${host_sock}"; then
        printf -- '-v %s:/run/podman/podman.sock -e CONTAINER_HOST=unix:///run/podman/podman.sock' \
            "${host_sock}"
        return 0
    fi
    cat >&2 <<'EOF'
ERROR: RIOTBOX_SOCKET=1 set but no working podman socket found on host.

Socket mode bind-mounts the host's podman socket into the container so
in-container podman calls are served by the host engine (shared image
cache, shared registry auth, concurrent across sessions).

To enable on the host:
    systemctl --user enable --now podman.socket

Then verify:
    podman --url unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock info

Alternatives:
  - RIOTBOX_NESTED=1 — run a podman engine inside the container (isolated,
    but vfs storage and per-session re-pulls).
  - Default mode — no container engine; for non-podman workloads.
EOF
    return 1
}
