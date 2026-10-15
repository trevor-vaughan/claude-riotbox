#!/usr/bin/env bash
# shellcheck disable=SC2034 # HEADROOM_PROXY_* are read by the helpers that source this file
# ─────────────────────────────────────────────────────────────────────────────
# agents/lib/headroom-proxy.sh — the headroom proxy the agent helpers front.
#
# Sourced by agents/<name>/headroom-exec.sh. Not an agent: the registry only
# registers subdirectories that hold a manifest.sh.
#
# Every agent with headroom support starts `headroom proxy` itself rather
# than letting `headroom wrap <agent>` do it, because wrap writes into the
# working directory, which in a session is the caller's checkout:
# `wrap claude` writes .claude/settings.local.json, its lock and a
# SessionStart hook (headroom 0.39.0 cli/wrap.py:5253, 1672), and
# `wrap opencode --memory` appends to AGENTS.md (cli/wrap.py:7919).
#
# The proxy runs with --memory --no-learn:
#   --memory     cross-session memory. Its DB is HEADROOM_MEMORY_DB_PATH,
#                which the agent wrapper sets to ~/.headroom/memory.db, the
#                session's state-dir mount; unset, headroom keeps it in
#                $PWD/.headroom (proxy/server.py:1332-1336).
#   --no-learn   the traffic learner writes what it learns into the project
#                (CLAUDE.local.md for Claude, learn/writer.py:279-286;
#                AGENTS.md for opencode, learn/plugins/opencode.py:124-130),
#                and no flag or env var points it anywhere else: only
#                `headroom learn --target` sets a writer target
#                (cli/learn.py:240), and the proxy's learner never does
#                (memory/traffic_learner.py:671). --no-learn wins over any
#                --learn (cli/proxy.py:1452).
#
# Sets on source:
#   HEADROOM_PROXY_PORT     ${HEADROOM_PORT:-8787}; after headroom_proxy_select,
#                           the port the proxy actually uses
#   HEADROOM_PROXY_TIMEOUT  readiness timeout in seconds,
#                           ${RIOTBOX_HEADROOM_PROXY_TIMEOUT:-120}, validated
#   HEADROOM_PROXY_FAILURE  why the last select or start failed
#
# Public (call select, then start; the caller exports routing env built
# from HEADROOM_PROXY_PORT in between or after):
#   headroom_proxy_is_headroom <port>
#     Exit 0 when a healthy headroom proxy answers on 127.0.0.1:<port>:
#     GET /livez returns "service":"headroom-proxy" and "status":"healthy"
#     (proxy/server.py:3832-3847). /livez, not /health or /readyz, because
#     those probe the upstream API first (server.py:3849-3864). Anything else
#     listening there — a dev server such as wrangler, which also defaults to
#     8787 — must never get the agent's API traffic and credentials.
#
#   headroom_proxy_select <plan-fn>
#     Take the proxy lock (${HEADROOM_PROXY_RUN_DIR}/proxy.lock), so two agents
#     starting at once in one container do not both start a proxy, then scan
#     up to 100 ports from HEADROOM_PROXY_PORT. <plan-fn> <port> sets
#     HEADROOM_PROXY_ARGS (extra `headroom proxy` arguments) and exports the
#     routing env the agent needs with a proxy on <port>; it is run in a
#     subshell per port to render that launch config, then once in this
#     shell for the port chosen. A port is reused only when it answers as
#     headroom AND ${HEADROOM_PROXY_RUN_DIR}/proxy.<port> records the same launch
#     config and names a live process with the same start time: the proxy
#     fixes its upstream when it starts (proxy/server.py:6495), so a proxy
#     started for another provider would send this agent's requests, and
#     its credentials, to the wrong endpoint. A headroom proxy without such
#     a record was not started here and is passed over too. Otherwise the
#     first port nothing accepts on is taken. Sets HEADROOM_PROXY_PORT and
#     HEADROOM_PROXY_REUSE (1: reuse, empty: start). Returns 1 with
#     HEADROOM_PROXY_FAILURE set, and the lock released, when ~/.headroom
#     cannot be written or no port is usable.
#
#   headroom_proxy_start <agent-type>
#     Unless reusing, start `headroom proxy --port <port> --memory --no-learn
#     [--mode $HEADROOM_MODE] "${HEADROOM_PROXY_ARGS[@]}"` in a new session
#     (setsid: TTY signals reach only the agent), logging to
#     ~/.headroom/logs/proxy.log, wait until it answers as headroom, and
#     write its record. The proxy is labelled HEADROOM_AGENT_TYPE=
#     <agent-type>, HEADROOM_STACK=wrap_<agent-type>, as `headroom wrap`
#     labels it for `headroom perf`. HEADROOM_MODE goes in as --mode because
#     that option has no env var (wrap forwards it the same way,
#     cli/wrap.py _start_proxy); --backend, --region and the rest read their
#     env vars themselves, which is why the record holds them. Waits until a
#     deadline (RIOTBOX_HEADROOM_PROXY_TIMEOUT seconds). Releases the lock
#     either way; the proxy does not inherit it. Returns 1 with
#     HEADROOM_PROXY_FAILURE set when the proxy exits during startup or is
#     not ready in time (then it is killed). The proxy outlives the caller:
#     the container is its lifecycle boundary, and later runs with the same
#     launch config reuse it. If it dies mid-session, the agent gets
#     connection errors until it is relaunched.
#
#   headroom_proxy_ensure <agent-type> <plan-fn>
#     select, then start.
# ─────────────────────────────────────────────────────────────────────────────

HEADROOM_PROXY_PORT="${HEADROOM_PORT:-8787}"
# Records and the start lock are container-local: ~/.headroom is the
# state-dir mount, shared by every concurrent container of the project,
# each in its own network and PID namespace, so a record there would name a
# proxy (port, PID) another container cannot see. /tmp in the container is
# its own writable layer (the launch mounts nothing there and does not run
# --read-only), and a proxy lives exactly as long as its container.
HEADROOM_PROXY_RUN_DIR="${RIOTBOX_HEADROOM_RUN_DIR:-/tmp/riotbox-headroom-${UID}}"
HEADROOM_PROXY_TIMEOUT="${RIOTBOX_HEADROOM_PROXY_TIMEOUT:-120}"
HEADROOM_PROXY_FAILURE=""
HEADROOM_PROXY_REUSE=""
HEADROOM_PROXY_ARGS=()
_HEADROOM_PROXY_LOCK_FD=""
# Env that decides where the proxy sends traffic or how; a proxy keeps the
# values it started with, so they are part of its launch config.
# Each is read by headroom 0.39.0 at proxy start: the provider targets
# (proxy/server.py:6495-6513, providers/registry.py:131-132), the outbound
# proxy (HEADROOM_HTTP_PROXY, server.py:6551, and the standard *_PROXY
# variables httpx honours, upstream_pinning.py:48), the listen host
# (HEADROOM_HOST, server.py:6492) and the client token the proxy requires
# (HEADROOM_PROXY_TOKEN, cli/proxy.py:1428).
_HEADROOM_PROXY_ROUTING_ENV=(ANTHROPIC_TARGET_API_URL OPENAI_TARGET_API_URL VERTEX_TARGET_API_URL
	BEDROCK_TARGET_API_URL GEMINI_TARGET_API_URL CLOUDCODE_TARGET_API_URL
	HEADROOM_HTTP2 HEADROOM_MODE HEADROOM_BACKEND HEADROOM_REGION HEADROOM_ANYLLM_PROVIDER
	HEADROOM_HTTP_PROXY HEADROOM_PROXY_TOKEN HEADROOM_HOST
	HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy)
# A non-integer timeout (e.g. 2.5) would make the [[ -ge ]] comparison in the
# readiness loop error on every iteration, so the timeout would never fire.
if ! [[ "${HEADROOM_PROXY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
	echo "NOTICE: RIOTBOX_HEADROOM_PROXY_TIMEOUT='${HEADROOM_PROXY_TIMEOUT}' is not a non-negative integer — using 120." >&2
	HEADROOM_PROXY_TIMEOUT=120
fi
# Force base-10: a leading zero (e.g. 08) would otherwise be read as an
# invalid octal literal by [[ -ge ]], reproducing the never-fires bug.
HEADROOM_PROXY_TIMEOUT=$((10#${HEADROOM_PROXY_TIMEOUT}))

# _headroom_port_accepts <port>: something accepts TCP there. /dev/tcp is a
# bash built-in redirection target.
_headroom_port_accepts() {
	(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 1
	return 0
}

headroom_proxy_is_headroom() {
	local body
	# shellcheck disable=SC2016 # $1 is expanded by the inner bash
	body="$(timeout 5 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
printf "GET /livez HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3
cat <&3' _ "$1" 2>/dev/null)" || return 1
	[[ "${body}" == *'"service":"headroom-proxy"'* ]] && [[ "${body}" == *'"status":"healthy"'* ]]
}

_headroom_proxy_unlock() {
	if [[ -n "${_HEADROOM_PROXY_LOCK_FD}" ]]; then
		exec {_HEADROOM_PROXY_LOCK_FD}>&-
		_HEADROOM_PROXY_LOCK_FD=""
	fi
}

# _headroom_proxy_config: print the launch config the current
# HEADROOM_PROXY_ARGS and routing env stand for, one canonical line per item.
_headroom_proxy_config() {
	local v
	printf 'args='
	printf '%q ' "${HEADROOM_PROXY_ARGS[@]}"
	printf '\n'
	for v in "${_HEADROOM_PROXY_ROUTING_ENV[@]}"; do
		if [[ -n "${!v+set}" ]]; then
			printf '%s=%q\n' "${v}" "${!v}"
		else
			printf '%s unset\n' "${v}"
		fi
	done
}

# _headroom_proxy_start_time <pid>: the process's start time in clock ticks
# (/proc/<pid>/stat field 22), which a recycled PID does not share.
_headroom_proxy_start_time() {
	local stat
	stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
	stat="${stat##*) }"
	# Field 22 overall is field 20 after "<pid> (<comm>) ". The fields are
	# numbers and single-letter states: split on purpose, nothing to glob.
	# shellcheck disable=SC2086
	set -- ${stat}
	[[ -n "${20:-}" ]] || return 1
	printf '%s\n' "${20}"
}

# _headroom_proxy_recorded <port> <config>: the record for <port> is a real
# file naming a live process with its recorded start time, and <config>.
_headroom_proxy_recorded() {
	local record="${HEADROOM_PROXY_RUN_DIR}/proxy.$1" header body pid start now
	[[ -f "${record}" && ! -L "${record}" ]] || return 1
	header="$(head -n 1 -- "${record}")" || return 1
	body="$(tail -n +2 -- "${record}")" || return 1
	[[ "${header}" =~ ^pid=([0-9]+)\ start=([0-9]+)$ ]] || return 1
	pid="${BASH_REMATCH[1]}" start="${BASH_REMATCH[2]}"
	now="$(_headroom_proxy_start_time "${pid}")" || return 1
	[[ "${now}" == "${start}" && "${body}" == "$2" ]]
}

headroom_proxy_select() {
	local plan="$1" dir="${HOME}/.headroom" run="${HEADROOM_PROXY_RUN_DIR}" port first="${HEADROOM_PROXY_PORT}" last config skipped=""
	HEADROOM_PROXY_REUSE=""
	if ! mkdir -p "${dir}/logs" 2>/dev/null; then
		HEADROOM_PROXY_FAILURE="could not create ${dir}/logs"
		return 1
	fi
	# The run dir is created 0700 here, or must already be a real directory
	# this user owns, not a link: a record in it decides where the agent's
	# credentials go.
	if ! mkdir -m 700 -- "${run}" 2>/dev/null &&
		! { [[ -d "${run}" && ! -L "${run}" && -O "${run}" ]] && chmod 700 -- "${run}"; }; then
		HEADROOM_PROXY_FAILURE="${run} is not a private directory of this user (or could not be created)"
		return 1
	fi
	# The braces keep 2>/dev/null to the open: on a bare exec it would
	# silence the helper's stderr for good.
	if ! { exec {_HEADROOM_PROXY_LOCK_FD}>"${run}/proxy.lock"; } 2>/dev/null; then
		_HEADROOM_PROXY_LOCK_FD=""
		HEADROOM_PROXY_FAILURE="could not open ${run}/proxy.lock"
		return 1
	fi
	if ! flock -w "${HEADROOM_PROXY_TIMEOUT}" "${_HEADROOM_PROXY_LOCK_FD}"; then
		_headroom_proxy_unlock
		HEADROOM_PROXY_FAILURE="another headroom proxy start held ${run}/proxy.lock for ${HEADROOM_PROXY_TIMEOUT}s"
		return 1
	fi
	last=$((first + 99))
	[[ "${last}" -le 65535 ]] || last=65535
	for ((port = first; port <= last; port++)); do
		# shellcheck disable=SC2310 # a predicate: its 0/1 return is the control signal
		if headroom_proxy_is_headroom "${port}"; then
			# shellcheck disable=SC2311 # the subshell is the point: the plan must not change this shell yet
			config="$("${plan}" "${port}" && _headroom_proxy_config)" || {
				_headroom_proxy_unlock
				HEADROOM_PROXY_FAILURE="could not plan the proxy's launch config"
				return 1
			}
			# shellcheck disable=SC2310 # a predicate: its 0/1 return is the control signal
			if _headroom_proxy_recorded "${port}" "${config}"; then
				HEADROOM_PROXY_PORT="${port}"
				HEADROOM_PROXY_REUSE=1
				"${plan}" "${port}"
				return 0
			fi
			echo "NOTICE: the headroom proxy on port ${port} was not started by RiotBox with this agent's provider settings — not using it." >&2
			skipped=1
			continue
		fi
		# shellcheck disable=SC2310 # a predicate: its 0/1 return is the control signal
		if ! _headroom_port_accepts "${port}"; then
			HEADROOM_PROXY_PORT="${port}"
			[[ "${port}" -eq "${first}" || -n "${skipped}" ]] ||
				echo "NOTICE: port ${first} is taken by something that is not a healthy headroom proxy (or is busy) — starting the headroom proxy on ${port}." >&2
			"${plan}" "${port}"
			return 0
		fi
	done
	_headroom_proxy_unlock
	HEADROOM_PROXY_FAILURE="no port in ${first}-${last} is free or runs headroom"
	return 1
}

headroom_proxy_start() {
	local agent="$1" log_dir="${HOME}/.headroom/logs" pid deadline start
	local record="${HEADROOM_PROXY_RUN_DIR}/proxy.${HEADROOM_PROXY_PORT}"
	if [[ -n "${HEADROOM_PROXY_REUSE}" ]]; then
		_headroom_proxy_unlock
		return 0
	fi
	# Nothing listens on this port, so any record for it is stale.
	rm -f -- "${record}"
	local -a cmd=(headroom proxy --port "${HEADROOM_PROXY_PORT}" --memory --no-learn)
	if [[ -n "${HEADROOM_MODE:-}" ]]; then
		cmd+=(--mode "${HEADROOM_MODE}")
	fi
	cmd+=("${HEADROOM_PROXY_ARGS[@]}")
	if command -v setsid >/dev/null 2>&1; then
		cmd=(setsid "${cmd[@]}")
	fi
	# The lock fd is closed for the proxy: inherited, it would hold the lock
	# for as long as the proxy lives.
	HEADROOM_AGENT_TYPE="${agent}" HEADROOM_STACK="wrap_${agent}" \
		"${cmd[@]}" >>"${log_dir}/proxy.log" 2>&1 {_HEADROOM_PROXY_LOCK_FD}>&- &
	pid=$!
	# A deadline in seconds, not a count of loop turns: each probe can take
	# up to its own 5s timeout.
	deadline=$((SECONDS + HEADROOM_PROXY_TIMEOUT))
	# shellcheck disable=SC2310 # a predicate: its 0/1 return is the control signal
	until headroom_proxy_is_headroom "${HEADROOM_PROXY_PORT}"; do
		if ! kill -0 "${pid}" 2>/dev/null; then
			_headroom_proxy_unlock
			HEADROOM_PROXY_FAILURE="headroom proxy exited during startup (see ${log_dir}/proxy.log)"
			return 1
		fi
		if [[ "${SECONDS}" -ge "${deadline}" ]]; then
			kill "${pid}" 2>/dev/null || true
			_headroom_proxy_unlock
			HEADROOM_PROXY_FAILURE="headroom proxy not ready after ${HEADROOM_PROXY_TIMEOUT}s (see ${log_dir}/proxy.log)"
			return 1
		fi
		sleep 1
	done
	# The record is written under the start lock, staged and renamed so a
	# reader never sees half of it. Without one this proxy is simply never
	# reused, so a failed write costs reuse, not the session.
	# shellcheck disable=SC2310,SC2311 # their status is the point of the test
	if ! { start="$(_headroom_proxy_start_time "${pid}")" &&
		{ printf 'pid=%s start=%s\n' "${pid}" "${start}" && _headroom_proxy_config; } >"${record}.tmp.$$" 2>/dev/null &&
		mv -f -- "${record}.tmp.$$" "${record}" 2>/dev/null; }; then
		rm -f -- "${record}.tmp.$$"
		echo "NOTICE: could not record the headroom proxy on port ${HEADROOM_PROXY_PORT}; later launches will start their own." >&2
	fi
	_headroom_proxy_unlock
}

headroom_proxy_ensure() {
	# shellcheck disable=SC2310 # its status is returned
	headroom_proxy_select "$2" || return 1
	headroom_proxy_start "$1"
}
