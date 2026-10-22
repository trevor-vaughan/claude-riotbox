#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/headroom-exec.sh — headroom interposition for Claude Code.
#
# The wrapper execs this on the first pass when RIOTBOX_HEADROOM=1, with
# RIOTBOX_HEADROOM_ACTIVE=1 and HEADROOM_MEMORY_DB_PATH already exported:
#
#   1. Ensure a headroom proxy with this launch's provider routing answers on
#      127.0.0.1:${HEADROOM_PORT:-8787}, or the next port up when something
#      else holds that one (agents/lib/headroom-proxy.sh: `headroom proxy
#      --memory --no-learn`; _claude_proxy_plan below is the routing).
#   2. Register headroom's MCP retrieve tool with Claude Code.
#   3. exec `claude` with the routing env pointing at the proxy. claude
#      resolves back to the shim, where the guard sends this second pass to
#      the real binary.
#
# ── Why not `headroom wrap claude` ───────────────────────────────────────────
#
# wrap writes into the working directory, which in a session is the caller's
# checkout (headroom 0.39.0): .claude/settings.local.json with the proxy's
# ANTHROPIC_BASE_URL and ENABLE_TOOL_SEARCH, its .headroom_wrap_settings.lock,
# .headroom_wrap_marker.json and .headroom_wrap_owners.json beside it, and a
# SessionStart hook running `headroom wrap selfheal` that only `headroom
# unwrap claude` removes (cli/wrap.py:5253, 5450-5490, 1672). This helper does
# what wrap does for a launch, minus those writes:
#
#   kept    the proxy (labelled agent_type claude, as wrap labels it); the
#           MCP retrieve tool (cli/wrap.py:1923, registered at user scope, in
#           ~/.claude.json — the session dir, never the project), without
#           which the proxy's "[Retrieve more: hash=…]" markers point at
#           nothing; the routing env for the launch (below); ENABLE_TOOL_SEARCH
#           (cli/wrap.py:388): Claude Code turns on-demand tool loading off
#           behind a custom base URL unless it is set, inflating the context;
#           the same two keys as settings env (cli/wrap.py:1781, 1815) for
#           the daemon's background sessions (below), passed as --settings.
#   dropped the settings.local.json writes, which wrap makes for those
#           sessions (issues #951, #2492): writing the session dir's user
#           settings instead would route every session of the project through
#           a port only this container serves; the
#           selfheal hook, which only exists to undo those writes; the
#           X-Headroom-Project header (cli/wrap.py:2975), a savings label from
#           the CWD's name, which in a session is always "workspace"; the
#           runtime-env push (cli/wrap.py:4072), which hot-syncs output-shaper
#           knobs from the caller's environment into a reused proxy: a proxy
#           is reused only when its recorded launch config (the provider
#           routing) matches, and every agent in a container starts from the
#           same environment, so the knobs it would push are the ones the
#           proxy already has; HEADROOM_SAVINGS_PROFILE
#           expansion, which RiotBox never passes in; client refcounting and
#           shutdown: the proxy lives as long as the container, as for
#           opencode.
#
# Routing env, as wrap sets it (cli/wrap.py:5316-5338, 5429-5443, 1133-1180):
#   Vertex  (CLAUDE_CODE_USE_VERTEX)   ANTHROPIC_VERTEX_BASE_URL=<proxy>; the
#           proxy gets VERTEX_TARGET_API_URL for a custom gateway, none for
#           Google's own endpoint (it derives the regional host per request),
#           and HEADROOM_HTTP2=false (cli/wrap.py _start_proxy).
#   Foundry (CLAUDE_CODE_USE_FOUNDRY with ANTHROPIC_FOUNDRY_BASE_URL or
#           ANTHROPIC_FOUNDRY_RESOURCE) ANTHROPIC_FOUNDRY_BASE_URL=
#           <proxy>/anthropic; the proxy gets the real endpoint as
#           --anthropic-api-url. ENABLE_TOOL_SEARCH defaults to false here.
#   else    ANTHROPIC_BASE_URL=<proxy>.
#
# Background sessions (Claude Code 2.1.304): /bg in a session and `claude
# --bg` hand the session to the on-demand `claude daemon`, which often runs it
# in a worker it started before the session existed. That worker does not get
# this launch's environment, only its --settings, so the routing env goes in
# as --settings '{"env":{<routing key>: <proxy>, "ENABLE_TOOL_SEARCH": …}}'
# too. A later --settings replaces an earlier one whole, and only the last
# counts, so a user's own last --settings (inline JSON when, trimmed, it is
# {…}; a file path otherwise, as Claude Code reads it) gets the routing env
# merged into its env instead, the user's keys winning. Settings env outranks
# the process env, so these values also win over a user or project
# settings.json env for this launch, as wrap's settings.local.json does.
#
# Degraded mode (spawn failure, readiness timeout): warn on stderr and exec
# claude unrouted — headroom is an optimization layer, never a reason to lose
# a session. A failed MCP registration only warns, and so does a user's
# --settings the routing cannot be merged into: claude gets it unchanged.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agents/lib/headroom-proxy.sh
source "${_helper_dir}/../lib/headroom-proxy.sh"

# "$@" is consumed by _fallback from inside functions, so snapshot it.
USER_ARGS=("$@")

_fallback() {
	echo "WARNING: $1 — running claude unwrapped." >&2
	exec claude "${USER_ARGS[@]}"
}

# _trim <string>: print it without leading or trailing whitespace.
_trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# _normalize_api_url <url>: upstream's _normalize_proxy_api_url
# (cli/wrap.py:3649) — trimmed, trailing slashes and one trailing /v1 off.
_normalize_api_url() {
	local u
	u="$(_trim "$1")"
	while [[ "${u}" == */ ]]; do
		u="${u%/}"
	done
	printf '%s' "${u%/v1}"
}

# providers/registry.py:18
default_vertex_url="https://us-central1-aiplatform.googleapis.com"
use_vertex="${CLAUDE_CODE_USE_VERTEX:-}"

foundry_upstream=""
if [[ -n "${CLAUDE_CODE_USE_FOUNDRY:-}" ]]; then
	foundry_upstream="${ANTHROPIC_FOUNDRY_BASE_URL:-}"
	if [[ -z "${foundry_upstream}" ]]; then
		resource="$(_trim "${ANTHROPIC_FOUNDRY_RESOURCE:-}")"
		if [[ -n "${resource}" ]]; then
			foundry_upstream="https://${resource}.services.ai.azure.com/anthropic"
		fi
	fi
fi

# _claude_proxy_plan <port>: the proxy arguments and routing env for a proxy
# on <port> (headroom_proxy_select runs it per candidate port, in a
# subshell, to compare launch configs, then here for the port chosen). The
# Vertex target depends on the port: a target that is the proxy itself is
# dropped (_vertex_target_api_url_from_claude_env, cli/wrap.py:1161).
_claude_proxy_plan() {
	local url="http://127.0.0.1:$1" vertex_target="" explicit vertex_url
	local proxy_norm explicit_norm vertex_norm default_norm
	HEADROOM_PROXY_ARGS=()
	if [[ -n "${foundry_upstream}" ]]; then
		HEADROOM_PROXY_ARGS+=(--anthropic-api-url "${foundry_upstream}")
		export ANTHROPIC_TARGET_API_URL="${foundry_upstream}"
	fi
	if [[ -n "${use_vertex}" ]]; then
		explicit="$(_trim "${VERTEX_TARGET_API_URL:-}")"
		vertex_url="$(_trim "${ANTHROPIC_VERTEX_BASE_URL:-}")"
		proxy_norm="$(_normalize_api_url "${url}")"
		explicit_norm="$(_normalize_api_url "${explicit}")"
		vertex_norm="$(_normalize_api_url "${vertex_url}")"
		default_norm="$(_normalize_api_url "${default_vertex_url}")"
		if [[ -n "${explicit}" ]]; then
			if [[ "${explicit_norm}" != "${proxy_norm}" ]]; then
				vertex_target="${explicit}"
			fi
		elif [[ -n "${vertex_url}" ]] && [[ "${vertex_norm}" != "${default_norm}" ]] &&
			[[ "${vertex_norm}" != "${proxy_norm}" ]]; then
			vertex_target="${vertex_url}"
		fi
		if [[ -n "${vertex_target}" ]]; then
			export VERTEX_TARGET_API_URL="${vertex_target}"
		else
			unset VERTEX_TARGET_API_URL
		fi
		# Vertex resets HTTP/2 streams; the user's own value wins.
		export HEADROOM_HTTP2="${HEADROOM_HTTP2:-false}"
	fi
}

# ── 1. Ensure a proxy with this launch config ────────────────────────────────
# shellcheck disable=SC2310 # its status picks the fallback
headroom_proxy_ensure claude _claude_proxy_plan || _fallback "${HEADROOM_PROXY_FAILURE}"
proxy_url="http://127.0.0.1:${HEADROOM_PROXY_PORT}"

# ── 2. MCP retrieve tool ─────────────────────────────────────────────────────
# `claude mcp add -s user` under the hood (mcp_registry/claude.py:196), so it
# lands in ~/.claude.json. Idempotent: an existing matching entry is kept.
mcp_log="${HOME}/.headroom/logs/mcp-install.log"
if ! headroom mcp install --agent claude --proxy-url "${proxy_url}" >>"${mcp_log}" 2>&1; then
	echo "NOTICE: could not register headroom's MCP retrieve tool (see ${mcp_log}); the model cannot fetch content the proxy compressed this session." >&2
fi

# ── 3. Route and launch ──────────────────────────────────────────────────────
if [[ -n "${use_vertex}" ]]; then
	route_key=ANTHROPIC_VERTEX_BASE_URL route_url="${proxy_url}"
elif [[ -n "${foundry_upstream}" ]]; then
	route_key=ANTHROPIC_FOUNDRY_BASE_URL route_url="${proxy_url}/anthropic"
else
	route_key=ANTHROPIC_BASE_URL route_url="${proxy_url}"
fi
export "${route_key}=${route_url}"
# An empty or blank value counts as unset, as Claude Code treats it.
tool_search="$(_trim "${ENABLE_TOOL_SEARCH:-}")"
if [[ -z "${tool_search}" ]]; then
	if [[ -n "${CLAUDE_CODE_USE_FOUNDRY:-}" ]]; then
		export ENABLE_TOOL_SEARCH=false
	else
		export ENABLE_TOOL_SEARCH=true
	fi
fi

# ── 4. The same routing for background sessions, as --settings ───────────────
route_settings="$(jq -cn --arg k "${route_key}" --arg v "${route_url}" --arg t "${ENABLE_TOOL_SEARCH}" \
	'{env: {($k): $v, ENABLE_TOOL_SEARCH: $t}}')"

# Find the value of the user's last --settings, the one Claude Code reads:
# its index in USER_ARGS, and whether it is joined (--settings=<value>).
# Arguments after -- are not options.
settings_at="" settings_joined=""
for ((i = 0; i < ${#USER_ARGS[@]}; i++)); do
	case "${USER_ARGS[i]}" in
	--) break ;;
	--settings)
		settings_at=$((i + 1)) settings_joined=""
		i=$((i + 1))
		;;
	--settings=*) settings_at="${i}" settings_joined=1 ;;
	*) ;;
	esac
done

launch_args=("${USER_ARGS[@]}")
if [[ -z "${settings_at}" ]]; then
	launch_args=(--settings "${route_settings}" "${USER_ARGS[@]}")
elif [[ "${settings_at}" -lt "${#USER_ARGS[@]}" ]]; then
	# (A --settings without a value is left for claude to reject.)
	value="${USER_ARGS[settings_at]}"
	if [[ -n "${settings_joined}" ]]; then
		value="${value#--settings=}"
	fi
	# The user's settings with the routing env merged into their env, their
	# keys winning, as one line of JSON; empty when the file cannot be read or
	# is not one settings object with an object env or none, which Claude
	# Code would reject too. Inline JSON can hold secrets (apiKeyHelper, env),
	# so the notice names only a path.
	# shellcheck disable=SC2016 # $route is a jq variable
	merge='if length == 1 and (.[0] | type) == "object" and ((.[0] | has("env") | not) or (.[0].env | type) == "object")
		then .[0] | .env = $route.env + (.env // {}) else error("not one settings object") end'
	trimmed="$(_trim "${value}")"
	if [[ "${trimmed}" == "{"*"}" ]]; then
		label="(inline JSON)"
		merged="$(jq -cs --argjson route "${route_settings}" "${merge}" 2>/dev/null <<<"${trimmed}")" || merged=""
	else
		label="${value}"
		merged="$(jq -cs --argjson route "${route_settings}" "${merge}" 2>/dev/null <"${value}")" || merged=""
	fi
	# The merged settings go to claude as a file: a settings file's secrets
	# would show in argv to anyone who can list processes, and one argument
	# is capped at 128 KiB, beyond which the exec fails. The run dir is
	# private to this user and lives as long as the container, as do the
	# background sessions that read the file. mktemp creates it 0600.
	merged_file=""
	if [[ -n "${merged}" ]] &&
		merged_file="$(mktemp --suffix=.json "${HEADROOM_PROXY_RUN_DIR}/settings.XXXXXX" 2>/dev/null)" &&
		! printf '%s\n' "${merged}" 2>/dev/null >"${merged_file}"; then
		rm -f -- "${merged_file}"
		merged_file=""
	fi
	if [[ -z "${merged_file}" ]]; then
		echo "NOTICE: could not add headroom's routing to --settings ${label}; background sessions (/bg, --bg) of this launch reach the API directly." >&2
	elif [[ -n "${settings_joined}" ]]; then
		launch_args[settings_at]="--settings=${merged_file}"
	else
		launch_args[settings_at]="${merged_file}"
	fi
fi
exec claude "${launch_args[@]}"
