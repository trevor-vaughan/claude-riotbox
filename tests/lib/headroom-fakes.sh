#!/usr/bin/env bash
# Fakes for the headroom helper suites (tests/headroom-claude.venom.yml,
# tests/headroom-opencode.venom.yml, tests/headroom.venom.yml). Source after
# setup_wrapper_sandbox; RIOTBOX_DIR must be exported.
# shellcheck disable=SC2016 # the heredocs are scripts written verbatim

# headroom_fakes_init
#   Per case: export FAKE_PIDFILE, where every fake listener records its PID
#   (fake-headroom-listener.py appends to it, including the ones the fake
#   `headroom proxy` execs), RIOTBOX_HEADROOM_RUN_DIR (the helper's record
#   and lock dir), and PORT, a port nothing listens on, as HEADROOM_PORT. Pair with `trap 'kill_fakes; rm -rf "${TEST_DIR}"' EXIT`.
headroom_fakes_init() {
	: "${TEST_DIR:?call setup_wrapper_sandbox first}"
	export FAKE_PIDFILE="${TEST_DIR}/fake-listeners.pids"
	: >"${FAKE_PIDFILE}"
	# The helper's container-local record dir, per case: /tmp is shared by
	# every case and every parallel run here, as it never is between
	# containers.
	export RIOTBOX_HEADROOM_RUN_DIR="${TEST_DIR}/run"
	PORT="$(free_port)"
	export HEADROOM_PORT="${PORT}"
}

# free_port: print a port the kernel just handed out for bind(port 0), so
# parallel runs never pick the same fixed port.
free_port() {
	python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# free_port_pair: print a port P where P and P+1 both bind, for the cases
# that put a foreign listener on P and expect the proxy on P+1.
free_port_pair() {
	local p i
	for i in $(seq 1 50); do
		p="$(free_port)"
		if python3 -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$((p + 1))" 2>/dev/null; then
			echo "${p}"
			return 0
		fi
	done
	echo "free_port_pair: no adjacent free ports after ${i} tries" >&2
	return 1
}

# start_fake_listener <port> <headroom|foreign> [lifetime]
#   Start fake-headroom-listener.py in the background (it records its PID in
#   FAKE_PIDFILE) and wait until it accepts.
start_fake_listener() {
	: "${RIOTBOX_DIR:?RIOTBOX_DIR must be exported}"
	python3 "${RIOTBOX_DIR}/tests/lib/fake-headroom-listener.py" "$1" "$2" "${3:-30}" &
	local _
	for _ in $(seq 1 50); do
		(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
		sleep 0.1
	done
	echo "start_fake_listener: nothing listens on $1" >&2
	return 1
}

# kill_fakes: kill every listener recorded in FAKE_PIDFILE. One that has
# exited already (killed earlier in the case, or past its deadline) is not
# an error. The kill sits in a condition because callers run under
# `set -e` (wrapper-shared.sh), where a failed kill in the EXIT trap would
# turn the case's exit status into 1.
kill_fakes() {
	local pid
	[[ -f "${FAKE_PIDFILE:-}" ]] || return 0
	while read -r pid; do
		if [[ -n "${pid}" ]] && ! kill "${pid}" 2>/dev/null; then
			: # already gone: nothing left to stop
		fi
	done <"${FAKE_PIDFILE}"
	return 0
}

# port_names: read stdin, write it with ":<PORT+1>" and "--port <PORT+1>"
# shown as PORT1 and ":<PORT>" / "--port <PORT>" as PORT, so assertions can
# name the runtime ports.
port_names() {
	local p1=$((PORT + 1))
	sed -E -e "s/(:|--port )${p1}([^0-9]|$)/\\1PORT1\\2/g" -e "s/(:|--port )${PORT}([^0-9]|$)/\\1PORT\\2/g"
}

# argv_line: port_names, then as one line with each input line ended by "|"
# and double quotes shown as single quotes. Venom assertions cannot hold a
# newline or a double quote, so this is how they pin argv order and JSON.
argv_line() {
	# shellcheck disable=SC2312 # port_names is a sed over stdin; tr ends the pipe
	port_names | tr '"\n' "'|"
	echo
}

# settings_shown: read the fake claude's output on stdin and print the file
# its last --settings names as "SETTINGS <where> <mode> <contents>", <where>
# being RUNDIR for a file directly in ${RIOTBOX_HEADROOM_RUN_DIR}, with
# quotes and ports shown as argv_line shows them.
settings_shown() {
	local line prev="" path="" where mode contents
	while IFS= read -r line; do
		case "${line}" in
		arg=--settings=*) path="${line#arg=--settings=}" ;;
		arg=*) if [[ "${prev}" == "arg=--settings" ]]; then path="${line#arg=}"; fi ;;
		*) ;;
		esac
		prev="${line}"
	done
	where="${path}"
	if [[ "${path%/*}" == "${RIOTBOX_HEADROOM_RUN_DIR}" ]]; then
		where=RUNDIR
	fi
	mode="$(stat -c %a -- "${path}")"
	contents="$(tr '"' "'" <"${path}")"
	printf 'SETTINGS %s %s %s\n' "${where}" "${mode}" "${contents}" | port_names
}

# install_claude_headroom_fakes
#   Replace ${TEST_DIR}/realbin/headroom and ${TEST_DIR}/realbin/claude.
#
#   The fake headroom appends one line per call to ${HOME}/headroom-calls.log:
#     HR=<argv>
#     HRENV agent=<HEADROOM_AGENT_TYPE> stack=<HEADROOM_STACK> memdb=<HEADROOM_MEMORY_DB_PATH>
#       http2=<HEADROOM_HTTP2> vtarget=<VERTEX_TARGET_API_URL>
#   `proxy` execs a headroom fake listener on its --port, or exits at once
#   with FAKE_PROXY_DIE set. `mcp` exits ${FAKE_MCP_RC:-0}. `wrap opencode`
#   runs the post-`--` arguments through opencode. Anything else prints
#   FAKE_HEADROOM_UNEXPECTED and fails: `wrap claude` in particular.
#
#   The fake claude prints FAKE_REAL_claude_INVOKED, the routing env it got
#   (CLAUDE_ENV <name>=<value or unset>) and arg=<arg> per argument.
install_claude_headroom_fakes() {
	: "${TEST_DIR:?call setup_wrapper_sandbox first}"
	cat >"${TEST_DIR}/realbin/headroom" <<'FAKE'
#!/usr/bin/env bash
{
	printf 'HR=%s\n' "$*"
	printf 'HRENV agent=%s stack=%s memdb=%s http2=%s vtarget=%s\n' \
		"${HEADROOM_AGENT_TYPE:-unset}" "${HEADROOM_STACK:-unset}" "${HEADROOM_MEMORY_DB_PATH:-unset}" \
		"${HEADROOM_HTTP2:-unset}" "${VERTEX_TARGET_API_URL:-unset}"
} >>"${HOME}/headroom-calls.log"
case "${1:-}" in
proxy)
	[ -z "${FAKE_PROXY_DIE:-}" ] || exit 1
	port=8787 prev=""
	for a in "$@"; do [ "${prev}" = "--port" ] && port="${a}"; prev="${a}"; done
	exec python3 "${RIOTBOX_DIR}/tests/lib/fake-headroom-listener.py" "${port}" headroom 30
	;;
mcp) exit "${FAKE_MCP_RC:-0}" ;;
wrap)
	# Only for opencode, which a case may run beside claude: claude never
	# goes through wrap, and a `wrap claude` here is a failure.
	[ "${2:-}" = opencode ] || { echo "FAKE_HEADROOM_UNEXPECTED $*"; exit 3; }
	shift 2
	while [ "$#" -gt 0 ]; do a="$1"; shift; [ "${a}" = "--" ] && break; done
	exec opencode "$@"
	;;
*)
	echo "FAKE_HEADROOM_UNEXPECTED $*"
	exit 3
	;;
esac
FAKE
	chmod +x "${TEST_DIR}/realbin/headroom"
	cat >"${TEST_DIR}/realbin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE_REAL_claude_INVOKED"
for v in ANTHROPIC_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL ENABLE_TOOL_SEARCH; do
	printf 'CLAUDE_ENV %s=%s\n' "${v}" "${!v-unset}"
done
printf 'arg=%s\n' "$@"
FAKE
	chmod +x "${TEST_DIR}/realbin/claude"
}

# install_opencode_headroom_fakes
#   Replace ${TEST_DIR}/realbin/headroom for the opencode suite: every call
#   appends FAKE_HEADROOM_ARGV=<argv> to ${HOME}/headroom-calls.log; `proxy`
#   first models where headroom keeps memory (HEADROOM_MEMORY_DB_PATH, else
#   $PWD/.headroom/memory.db, proxy/server.py:1332-1336; per-project DBs in
#   memories/ beside it, proxy/memory_handler.py:409-413), then execs a
#   headroom fake listener on its --port; `wrap opencode` runs the post-`--`
#   arguments through opencode, as upstream's launch does.
install_opencode_headroom_fakes() {
	: "${TEST_DIR:?call setup_wrapper_sandbox first}"
	cat >"${TEST_DIR}/realbin/headroom" <<'FAKE'
#!/usr/bin/env bash
printf 'FAKE_HEADROOM_ARGV=%s\n' "$*" >>"${HOME}/headroom-calls.log"
if [ "${1:-}" = "proxy" ]; then
	db="${HEADROOM_MEMORY_DB_PATH:-${PWD}/.headroom/memory.db}"
	mkdir -p "${db%/*}/memories/projects/workspace-0123456789abcdef"
	touch "${db}" "${db%/*}/memories/projects/workspace-0123456789abcdef/memory.db"
	port=8787 prev=""
	for a in "$@"; do [ "${prev}" = "--port" ] && port="${a}"; prev="${a}"; done
	exec python3 "${RIOTBOX_DIR}/tests/lib/fake-headroom-listener.py" "${port}" headroom 30
fi
if [ "${1:-}" = "wrap" ] && [ "${2:-}" = "opencode" ]; then
	shift 2
	while [ "$#" -gt 0 ]; do a="$1"; shift; [ "${a}" = "--" ] && break; done
	exec opencode "$@"
fi
FAKE
	chmod +x "${TEST_DIR}/realbin/headroom"
}

# claude_case_setup
#   The common start of a headroom-claude case: a wrapper sandbox for claude
#   with the ambient session env and the routing env unset, the fakes above,
#   a runtime PORT, RIOTBOX_HEADROOM=1, and an EXIT trap that kills every
#   fake listener before removing the sandbox.
claude_case_setup() {
	setup_wrapper_sandbox claude
	unset CONTEXT_MODE_DIR RIOTBOX_CONTEXT_MODE RIOTBOX_AGENT _CONTEXT_MODE_WIRED CONTEXT_MODE_DATA_DIR CONTEXT_MODE_PLATFORM
	unset ANTHROPIC_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL ANTHROPIC_FOUNDRY_RESOURCE \
		ENABLE_TOOL_SEARCH CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY HEADROOM_MODE HEADROOM_HTTP2 \
		VERTEX_TARGET_API_URL HEADROOM_MEMORY_DB_PATH RIOTBOX_HEADROOM_ACTIVE CLAUDE_CONFIG_DIR
	install_generic_wrapper_for claude
	install_claude_headroom_fakes
	headroom_fakes_init
	trap 'kill_fakes; rm -rf "${TEST_DIR}"' EXIT
	export RIOTBOX_HEADROOM=1
}

# in_other_container <command> [arg...]
#   Run <command> the way a second container of the same project sees the
#   world: its own network and PID namespaces (unshare as an unprivileged
#   user, loopback brought up), the same HOME and so the same ~/.headroom
#   state-dir mount. Every process in it dies when <command> returns, as a
#   container's do. Its fakes record their PIDs in ${FAKE_PIDFILE}.b, never
#   in FAKE_PIDFILE: those PIDs are the namespace's, and kill_fakes would
#   signal unrelated processes with the same numbers.
in_other_container() {
	: "${RIOTBOX_DIR:?RIOTBOX_DIR must be exported}"
	FAKE_PIDFILE="${FAKE_PIDFILE}.b" unshare -rn --pid --fork --mount-proc \
		bash -c 'python3 "${RIOTBOX_DIR}/tests/lib/netns-lo-up.py" && exec "$@"' _ "$@"
}
