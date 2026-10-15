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
#           behind a custom base URL unless it is set, inflating the context.
#   dropped the settings.local.json writes, which exist for daemon-spawned
#           conversation workers that read settings fresh (issue #951) — a
#           claude run in a session inherits this env, and writing the
#           session dir's user settings instead would route every session of
#           the project through a port only this container serves; the
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
# Degraded mode (spawn failure, readiness timeout): warn on stderr and exec
# claude unrouted — headroom is an optimization layer, never a reason to lose
# a session. A failed MCP registration only warns.
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
	export ANTHROPIC_VERTEX_BASE_URL="${proxy_url}"
elif [[ -n "${foundry_upstream}" ]]; then
	export ANTHROPIC_FOUNDRY_BASE_URL="${proxy_url}/anthropic"
else
	export ANTHROPIC_BASE_URL="${proxy_url}"
fi
# An empty or blank value counts as unset, as Claude Code treats it.
tool_search="$(_trim "${ENABLE_TOOL_SEARCH:-}")"
if [[ -z "${tool_search}" ]]; then
	if [[ -n "${CLAUDE_CODE_USE_FOUNDRY:-}" ]]; then
		export ENABLE_TOOL_SEARCH=false
	else
		export ENABLE_TOOL_SEARCH=true
	fi
fi
exec claude "${USER_ARGS[@]}"
