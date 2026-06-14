#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/headroom-exec.sh — headroom interposition for opencode.
#
# headroom 0.25.0 has no `wrap opencode` subcommand; its wrap docstring says
# to run `headroom proxy` and point opencode at it. This helper is that
# proxy-routed path. The wrapper execs it on the first pass when
# RIOTBOX_HEADROOM=1, with RIOTBOX_HEADROOM_ACTIVE=1 already exported:
#
#   1. Ensure a proxy is listening on 127.0.0.1:${HEADROOM_PORT:-8787} —
#      reuse a live one, else spawn `headroom proxy --memory --learn`.
#   2. Inject provider baseURLs into the merged opencode.jsonc — only after
#      the proxy answers, and never over a user-set baseURL. opencode
#      ignores ANTHROPIC_BASE_URL/OPENAI_BASE_URL env vars (it always passes
#      an explicit baseURL to its SDK factories), so config is the only
#      routing mechanism. The merged file is regenerated from host config on
#      every container start, so this edit is self-cleaning.
#   3. exec opencode "$@" — resolves to the shim; the guard routes the
#      second pass down the normal inject-and-exec path.
#
# Degraded mode (spawn failure, readiness timeout, unparseable config):
# warn on stderr and exec opencode unwrapped with the config untouched —
# headroom is an optimization layer, never a reason to lose a session.
#
# The proxy intentionally outlives this process: the container is the
# lifecycle boundary, and later opencode runs reuse the listening proxy.
# If the proxy crashes mid-session it remains a zombie under the exec'd
# opencode process until container teardown — bounded at one and reaped by
# container init, a deliberate, accepted trade-off.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

port="${HEADROOM_PORT:-8787}"
timeout_s="${RIOTBOX_HEADROOM_PROXY_TIMEOUT:-120}"
# A non-integer timeout (e.g. 2.5) would make the [[ -ge ]] comparison in the
# readiness loop error on every iteration, so the timeout would never fire.
if ! [[ "${timeout_s}" =~ ^[0-9]+$ ]]; then
	echo "NOTICE: RIOTBOX_HEADROOM_PROXY_TIMEOUT='${timeout_s}' is not a non-negative integer — using 120." >&2
	timeout_s=120
fi
# Force base-10: a leading zero (e.g. 08) would otherwise be read as an
# invalid octal literal by [[ -ge ]], reproducing the never-fires bug.
timeout_s=$((10#${timeout_s}))
config="${HOME}/.config/opencode/opencode.jsonc"
# opencode's ai-sdk providers build request paths relative to a base that
# already contains /v1 (default https://api.anthropic.com/v1), so the proxy
# base needs the /v1 suffix — unlike claude, whose SDK appends /v1 itself.
proxy_base="http://127.0.0.1:${port}/v1"

# "$@" is consumed by _fallback from inside functions, so snapshot it.
USER_ARGS=("$@")

_fallback() {
	echo "WARNING: $1 — running opencode unwrapped." >&2
	# A successful exec never fires the EXIT trap, so drop any temp file
	# here (no-op when tmp is unset or already moved into place).
	rm -f "${tmp:-}" 2>/dev/null || true
	exec opencode "${USER_ARGS[@]}"
}

_proxy_listening() {
	# Plain TCP connect — mirrors upstream's readiness check (wrap.py
	# _check_proxy). /dev/tcp is a bash built-in redirection target.
	(exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null || return 1
	return 0
}

# ── 1. Ensure the proxy ──────────────────────────────────────────────────────
if ! _proxy_listening; then
	log_dir="${HOME}/.headroom/logs"
	mkdir -p "${log_dir}"
	# HEADROOM_AGENT_TYPE/STACK label the traffic for `headroom perf` the
	# same way `headroom wrap <tool>` does. setsid starts the proxy in a
	# new session with no controlling terminal (upstream uses
	# start_new_session=True), so TTY-delivered SIGHUP/SIGINT reach only
	# the foreground agent, never the proxy.
	if command -v setsid >/dev/null 2>&1; then
		HEADROOM_AGENT_TYPE=opencode HEADROOM_STACK=wrap_opencode \
			setsid headroom proxy --port "${port}" --memory --learn \
			>>"${log_dir}/proxy.log" 2>&1 &
	else
		HEADROOM_AGENT_TYPE=opencode HEADROOM_STACK=wrap_opencode \
			headroom proxy --port "${port}" --memory --learn \
			>>"${log_dir}/proxy.log" 2>&1 &
	fi
	proxy_pid=$!
	waited=0
	until _proxy_listening; do
		if ! kill -0 "${proxy_pid}" 2>/dev/null; then
			_fallback "headroom proxy exited during startup (see ${log_dir}/proxy.log)"
		fi
		if [[ "${waited}" -ge "${timeout_s}" ]]; then
			kill "${proxy_pid}" 2>/dev/null || true
			_fallback "headroom proxy not ready after ${timeout_s}s (see ${log_dir}/proxy.log)"
		fi
		sleep 1
		waited=$((waited + 1))
	done
fi

# ── 2. Inject provider baseURLs into the merged opencode.jsonc ───────────────
# The file is `//` banner lines + a jq-generated plain-JSON body (see
# agents/opencode/setup.sh). Line-level comment stripping is therefore safe.
banner=""
body="{}"
if [[ -f "${config}" ]]; then
	banner="$(grep '^//' "${config}" || true)"
	body="$(grep -v '^//' "${config}" || true)"
	if [[ -z "${body//[[:space:]]/}" ]]; then
		body="{}"
	fi
fi

if ! merged="$(jq --arg url "${proxy_base}" '
	def route($p): if (.provider[$p].options.baseURL // "") == ""
		then .provider[$p].options.baseURL = $url
		else . end;
	route("anthropic") | route("openai")
' <<<"${body}" 2>/dev/null)"; then
	_fallback "could not parse ${config}; headroom routing not applied"
fi

# A user-set baseURL (corporate gateway, alt endpoint) wins — headroom
# skips that provider rather than silently re-routing it. Our own injected
# URL from a previous run is not "user-set".
for prov in anthropic openai; do
	existing="$(jq -r --arg p "${prov}" '.provider[$p].options.baseURL // ""' <<<"${body}")"
	if [[ -n "${existing}" && "${existing}" != "${proxy_base}" ]]; then
		echo "NOTICE: provider.${prov}.options.baseURL is set in your opencode config — headroom will not route ${prov}." >&2
	fi
done

note='// headroom: anthropic/openai baseURLs route through the local compression proxy (RIOTBOX_HEADROOM=1).'
# Write failures (read-only HOME, disk full) degrade like every other
# failure path instead of dying under set -e mid-write.
write_fail="could not write ${config}; headroom routing not applied"
mkdir -p "$(dirname "${config}")" || _fallback "${write_fail}"
tmp="$(mktemp "${config}.XXXXXX")" || _fallback "${write_fail}"
trap 'rm -f "${tmp}"' EXIT
{
	# `if`, not `[[ ]] &&` — a failing && list as the last group command
	# would trip set -e when the banner is empty.
	if [[ -n "${banner}" ]]; then
		printf '%s\n' "${banner}"
	fi
	grep -qxF "${note}" <<<"${banner}" || printf '%s\n' "${note}"
	printf '%s\n' "${merged}"
} >"${tmp}" || _fallback "${write_fail}"
mv "${tmp}" "${config}" || _fallback "${write_fail}"

# ── 3. Re-exec the agent under the guard ─────────────────────────────────────
exec opencode "${USER_ARGS[@]}"
