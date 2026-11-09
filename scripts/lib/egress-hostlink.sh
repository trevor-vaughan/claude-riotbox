#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/egress-hostlink.sh — give the agent in an egress session a
# 127.0.0.1 listener for each host-loopback port the allowlist names
# (host.containers.internal:PORT; docs/dev/egress.md "Host loopback"), so
# tools can use localhost:PORT for a host service such as an ssh -L forward.
#
# riotbox-core egress-up mounts the session's share dir read-only at
# /run/riotbox-egress-share only when the launch's allowlist names
# host.containers.internal and rootless podman runs on pasta: a copy of
# riotbox-core and hostlink.ports. riotbox-core hostlink-listen polls the
# ports file, so a live allow or deny applies without a restart, and tunnels
# each connection through the proxy (HTTPS_PROXY). NO_PROXY already keeps
# tools' connections to localhost direct.
#
# container/entrypoint.sh sources this file and calls egress_hostlink_apply
# before any agent starts. In the image it is
# ~/.riotbox/lib/egress-hostlink.sh (the Containerfile copies scripts/lib/).
#
# Public:
#   egress_hostlink_apply [share-dir] [log]
#       Outside an egress session (RIOTBOX_EGRESS_SESSION unset), or
#       without an executable <share-dir>/riotbox-core (default share dir
#       /run/riotbox-egress-share), do nothing. Otherwise start
#       riotbox-core hostlink-listen in the background, detached from the
#       shell's jobs, appending its output to <log> (default
#       ~/.riotbox/hostlink.log). Returns 1, with a warning and nothing
#       started, when HTTPS_PROXY is unset or <log> cannot be written: the
#       session starts either way, and host.containers.internal:PORT still
#       works through the proxy.
# ─────────────────────────────────────────────────────────────────────────────

egress_hostlink_apply() {
	local share="${1:-/run/riotbox-egress-share}" log="${2:-${HOME}/.riotbox/hostlink.log}"
	[[ -n "${RIOTBOX_EGRESS_SESSION:-}" && -x "${share}/riotbox-core" ]] || return 0
	if [[ -z "${HTTPS_PROXY:-}" ]]; then
		echo "WARNING: egress: HTTPS_PROXY is not set; no localhost listeners for host ports (host.containers.internal:PORT needs the proxy too)." >&2
		return 1
	fi
	# `true`, not `:`: a failed redirect on a special builtin exits a POSIX-mode shell.
	if ! { true >>"${log}"; } 2>/dev/null; then
		echo "WARNING: egress: cannot write ${log}; no localhost listeners for host ports (host.containers.internal:PORT still works through the proxy)." >&2
		return 1
	fi
	"${share}/riotbox-core" hostlink-listen --ports "${share}/hostlink.ports" --proxy "${HTTPS_PROXY}" \
		</dev/null >>"${log}" 2>&1 &
	disown
}
