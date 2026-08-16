#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# container/forge-mcp.sh — the logic behind enable_github_mcp,
# enable_gitlab_mcp, disable_github_mcp and disable_gitlab_mcp.
#
# Sourced by those four commands, which ship on PATH only in the riotbox-gh-glab
# image. Provides:
#   forge_mcp_apply <github|gitlab> <wire|strip>
#     Resolve what the forge needs from the environment, then dispatch the
#     matching verb to every registered agent. One status line per agent.
#     Returns 0 only when every agent that implements the verb succeeded.
#
# Nothing here knows an agent's name. The set of agents comes from
# agents/registry.sh, which discovers them by globbing agents/*/manifest.sh, so
# "wire it into all riotbox LLM agents" (issue #9) is a loop rather than a list,
# and a third agent added later inherits this with no edit to this file.
#
# ── Why credential resolution lives here and not in the verbs ───────────────
#
# This file decides WHICH environment variable holds the token; the verbs write
# a reference to whatever name they are handed. Keeping that decision in one
# place means the two agents can never disagree about which variable won, and
# it leaves the verbs testable with explicit inputs rather than ambient state.
#
# No token VALUE is read here either — only whether a variable is non-empty.
# The value stays in the environment, where the agent picks it up when it spawns
# the server. See agents/claude/forge-mcp.sh for why that matters.
# ─────────────────────────────────────────────────────────────────────────────

# Locate the registry and the atomic JSON writer, in whichever layout we are in.
#
# Two layouts, both real: inside the image everything sits under ~/.riotbox
# (agents/ and lib/ beside this file), while in the source tree this file is
# container/forge-mcp.sh with agents/ and scripts/lib/ one level up. Probing for
# the file rather than branching on an environment variable keeps the source
# tree runnable — which is what lets tests/forge-mcp.venom.yml exercise the real
# commands instead of a copy of them.
_forge_mcp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${_forge_mcp_dir}/agents/registry.sh" ]]; then
	_forge_mcp_registry="${_forge_mcp_dir}/agents/registry.sh"
	_forge_mcp_json_write="${_forge_mcp_dir}/lib/json-write.sh"
else
	_forge_mcp_registry="${_forge_mcp_dir}/../agents/registry.sh"
	_forge_mcp_json_write="${_forge_mcp_dir}/../scripts/lib/json-write.sh"
fi

for _forge_mcp_lib in "${_forge_mcp_json_write}" "${_forge_mcp_registry}"; do
	if [[ ! -f "${_forge_mcp_lib}" ]]; then
		echo "ERROR: ${_forge_mcp_lib} is missing — this riotbox image is incomplete." >&2
		# shellcheck disable=SC2317  # `exit` runs only when this file is
		# *executed* rather than sourced; `return` outside a function fails
		# there and the fallback fires. Same shape as agents/registry.sh.
		return 1 2>/dev/null || exit 1
	fi
	# shellcheck source=/dev/null
	source "${_forge_mcp_lib}"
done
unset _forge_mcp_lib

# Print the name of the first non-empty variable from the arguments, or nothing.
#
# The names, not the values: the caller passes the winning name straight to a
# wire verb, which writes it as a reference. Emptiness counts as unset, because
# an exported-but-empty token is the same broken session as no token at all and
# is far easier to produce by accident (`export GITHUB_TOKEN=$(cat missing)`).
_forge_mcp_first_set_var() {
	local name
	for name in "$@"; do
		if [[ -n "${!name:-}" ]]; then
			printf '%s\n' "${name}"
			return 0
		fi
	done
	return 1
}

# Build the GitLab MCP endpoint from GITLAB_HOST.
#
# GITLAB_HOST is glab's own variable, and users set it both ways in the wild —
# bare host (`gitlab.example.com`) and full URL (`https://gitlab.example.com`) —
# so both are accepted, along with any number of trailing slashes. A bare host
# gets https, never http: silently downgrading the transport carrying a personal
# access token is not a convenience worth offering. Someone who genuinely needs
# plain http on an internal instance says so by writing the scheme out.
#
# The scheme comes off before the slashes are trimmed, and goes back on after.
# Trimming first would eat the scheme's own "//" — "https://" trims down to
# "https:", which is not a scheme any more, so it gets one prepended and builds
# the endpoint "https://https:/api/v4/mcp".
#
# The scheme match is case-insensitive because URI schemes are (RFC 3986 §3.1),
# and GITLAB_HOST=HTTPS://gitlab.example.com is a value a user can reasonably
# type. Matching it exactly would leave "HTTPS://gitlab.example.com" looking
# like a bare host and prefix a second scheme onto it.
_forge_mcp_gitlab_url() {
	local host="${GITLAB_HOST:-gitlab.com}"
	local scheme="https://"

	case "${host,,}" in
	http://*)
		scheme="http://"
		host="${host:7}"
		;;
	https://*)
		host="${host:8}"
		;;
	esac

	while [[ "${host}" == */ ]]; do
		host="${host%/}"
	done

	# What is left has to name a host. This is not URL validation — it does not
	# police what a hostname may contain — it only rejects the remainders that
	# provably name nothing, each of which would otherwise build an endpoint
	# that still satisfies the wire verbs' http(s) and /api/v4/mcp guards and
	# registers a server that can never connect:
	#
	#   nothing at all      "https://", "http://", "/", "https:///"
	#   whitespace          " ", "gl example.com" — no host holds a space
	#   a path, no host     "//gl.example.com", "https:///gl.example.com"
	#   a second scheme     "ftp://gl.example.com", "git://gl" — the scheme
	#                       match above accepts only http and https, so
	#                       anything else survives as part of the "host"
	#   a bare scheme       "https:", "gl.internal:" — a trailing colon with
	#                       no port after it
	#
	# A port is not a bare scheme: "gl.internal:8080" has something after the
	# colon and passes.
	if [[ -z "${host}" ]] ||
		[[ "${host}" == *[[:space:]]* ]] ||
		[[ "${host}" == /* ]] ||
		[[ "${host}" == *://* ]] ||
		[[ "${host}" == *: ]]; then
		echo "ERROR: GITLAB_HOST='${GITLAB_HOST:-}' does not name a host." >&2
		return 1
	fi

	printf '%s%s/api/v4/mcp\n' "${scheme}" "${host}"
}

# Resolve a forge's inputs and echo the argument list its wire verbs take.
#
# Everything that can fail, fails here — before any agent config is opened. A
# refusal therefore leaves every agent exactly as it was, rather than wiring the
# first agent in the registry and giving up on the second.
_forge_mcp_wire_args() {
	local forge="$1"
	local token_var

	case "${forge}" in
	github)
		# GITHUB_PERSONAL_ACCESS_TOKEN first because that is the name the
		# server itself reads; GITHUB_TOKEN second because issue #9 asks for
		# it and it is the name gh, CI and most tooling already use.
		if ! token_var="$(_forge_mcp_first_set_var GITHUB_PERSONAL_ACCESS_TOKEN GITHUB_TOKEN)"; then
			echo "ERROR: no GitHub token found." >&2
			echo "  Set GITHUB_TOKEN (or GITHUB_PERSONAL_ACCESS_TOKEN) and run this again." >&2
			echo "  The variable has to reach the container — from the host, add it to" >&2
			echo "  RIOTBOX_PASSTHROUGH_EXTRA_VARS before launching riotbox." >&2
			return 1
		fi
		printf '%s\n' "${token_var}"
		;;
	gitlab)
		if ! token_var="$(_forge_mcp_first_set_var GITLAB_TOKEN)"; then
			echo "ERROR: no GitLab token found." >&2
			echo "  Set GITLAB_TOKEN to a personal access token carrying the 'mcp' scope" >&2
			echo "  and run this again. The variable has to reach the container — from the" >&2
			echo "  host, add it to RIOTBOX_PASSTHROUGH_EXTRA_VARS before launching riotbox." >&2
			return 1
		fi
		local url
		url="$(_forge_mcp_gitlab_url)" || return 1
		printf '%s\n%s\n' "${url}" "${token_var}"
		;;
	*)
		echo "ERROR: unknown forge '${forge}'." >&2
		return 1
		;;
	esac
}

# forge_mcp_apply <github|gitlab> <wire|strip>
forge_mcp_apply() {
	local forge="${1:?forge_mcp_apply requires a forge}"
	local action="${2:?forge_mcp_apply requires an action}"

	case "${action}" in
	wire | strip) : ;;
	*)
		echo "ERROR: unknown action '${action}'." >&2
		return 1
		;;
	esac

	# Resolved before the loop so a missing token stops everything, and so the
	# same values reach every agent.
	local -a args=()
	if [[ "${action}" = "wire" ]]; then
		local resolved
		resolved="$(_forge_mcp_wire_args "${forge}")" || return 1
		mapfile -t args <<<"${resolved}"
	fi

	local verb="${forge}_mcp_${action}"
	local agent failures=0 applied=0

	# shellcheck disable=SC2154  # AGENT_REGISTRY comes from the sourced registry
	for agent in "${AGENT_REGISTRY[@]}"; do
		# The forge verbs are an optional part of the agent contract. An agent
		# that has not implemented them is skipped out loud: silence would read
		# as "wired" for an agent that is not.
		if ! declare -F "agent_${agent}_${verb}" >/dev/null; then
			echo "  [forge-mcp] ${agent}: no ${forge} MCP support — skipped." >&2
			continue
		fi

		if agent_call "${agent}" "${verb}" "${args[@]}"; then
			applied=$((applied + 1))
			if [[ "${action}" = "wire" ]]; then
				echo "  [forge-mcp] ${agent}: ${forge} MCP server registered."
			else
				# "cleanup complete", not "server removed": a strip verb
				# returns 0 on four paths where nothing was removed — no
				# config file, no entry present, a config too malformed to
				# edit, and an entry riotbox did not write. Announcing a
				# removal on those contradicts the stderr line that just
				# explained why there was none. Nothing is lost by the
				# weaker wording, because the strip verbs already print
				# "Removed the <server> MCP server from <config>." on the
				# one path where a removal did happen.
				echo "  [forge-mcp] ${agent}: ${forge} MCP cleanup complete."
			fi
		else
			failures=$((failures + 1))
			echo "  [forge-mcp] ${agent}: ${forge} MCP ${action} FAILED." >&2
		fi
	done

	if [[ "${failures}" -gt 0 ]]; then
		echo "ERROR: ${failures} agent(s) failed; ${applied} succeeded." >&2
		return 1
	fi

	if [[ "${applied}" -eq 0 ]]; then
		echo "ERROR: no registered agent supports the ${forge} MCP server." >&2
		return 1
	fi

	# Said once, at the end, and only on the wire path: MCP servers are read
	# when an agent starts, so a session with claude already running has not
	# picked this up. The alternative to saying so is a user concluding the
	# feature is broken.
	if [[ "${action}" = "wire" ]]; then
		echo "  [forge-mcp] Start (or restart) your agent to pick this up."
	fi
}
