#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/forge-mcp.sh — GitHub and GitLab MCP wiring for opencode.
#
# Sourced by agents/opencode/manifest.sh, which exposes the optional forge verbs
# (github_mcp_wire, github_mcp_strip, gitlab_mcp_wire, gitlab_mcp_strip).
# container/forge-mcp.sh drives them and holds no agent names of its own.
#
# The Claude sibling (agents/claude/forge-mcp.sh) documents why the two forges
# live in one file and why credentials are named rather than copied. Everything
# there applies here. Two things do not, and they are the whole reason this file
# exists separately:
#
#   * The dialect. opencode declares MCP servers under `mcp`, as `type: "local"`
#     with a single `command` ARRAY (argv, not a string plus args) and an
#     `environment` object, or `type: "remote"` with `url` and `headers`. Its
#     variable substitution is {env:VAR}, not ${VAR}.
#   * The file. opencode.jsonc is `//` banner lines followed by a jq-generated
#     plain-JSON body, and both halves are load-bearing (see below).
#
# ── This wiring lasts one session, and that is not a bug to fix here ────────
#
# opencode_setup (agents/opencode/setup.sh) regenerates opencode.jsonc from host
# config on every container start, and deletes opencode.json on its way past. An
# entry written here therefore survives until the next session start and no
# longer, where Claude's persists.
#
# Writing somewhere more durable would mean writing into the host's own opencode
# config, which riotbox syncs but does not own — a session-scoped enable command
# has no business editing the user's real config on the host. The honest fix is
# the documented one: re-run enable_github_mcp after a restart. The README says
# so plainly instead of implying the two agents behave alike.
#
# {env:VAR} on an unset variable substitutes an EMPTY STRING (opencode config
# docs, "Variables") — quieter than Claude's unexpanded-literal behaviour and
# worse for it, since the server would start and authenticate as nobody. As on
# the Claude side, container/forge-mcp.sh refuses to call these verbs when no
# candidate variable is set, so that state is unreachable through the commands.
# ─────────────────────────────────────────────────────────────────────────────

# The keys these verbs write under `mcp`. As on the Claude side, the key alone
# does not make an entry ours — see the ownership rule below.
_AGENT_OPENCODE_FORGE_GITHUB_SERVER='github'
_AGENT_OPENCODE_FORGE_GITLAB_SERVER='gitlab'

_agent_opencode_forge_config() {
	printf '%s\n' "${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/opencode.jsonc"
}

# See the Claude sibling: a typo guard, not an injection guard.
_agent_opencode_forge_valid_var() {
	[[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Read the two halves of opencode.jsonc. Line-level splitting is safe for
# exactly the reason headroom-exec.sh:104-105 gives: the body is jq-generated
# plain JSON, so a line starting with `//` is always a banner line and never a
# string containing one. Neither reader may be pointed at a hand-written JSONC
# file.
#
# Two readers rather than one function returning both halves, because there is
# no separator that survives the trip. Command substitution silently drops NUL
# bytes, and every other candidate separator is a byte that can legitimately
# appear in a config. Reading the file twice costs nothing at this size and
# cannot be got subtly wrong.
#
# An absent file yields empty output from both; the caller supplies `{}` for
# the body. That happens when an enable command runs before opencode_setup ever
# has — a bare `podman run` into the image, say — and the entry written then is
# picked up by the merge at the next session start.
_agent_opencode_forge_banner() {
	[[ -f "$1" ]] || return 0
	grep '^//' "$1" || true
}

_agent_opencode_forge_body() {
	[[ -f "$1" ]] || return 0
	grep -v '^//' "$1" || true
}

# Rewrite the config with a new body, keeping the banner exactly as it was.
#
# json_write_atomic takes the whole document as one string — banner included —
# so the staged-file-then-rename guarantee covers both halves. The file is not
# JSON, but that writer never parses its content; it only needs a filesystem
# path and bytes.
_agent_opencode_forge_write() {
	local config="$1" banner="$2" body="$3"
	local document
	if [[ -n "${banner}" ]]; then
		document="${banner}"$'\n'"${body}"
	else
		document="${body}"
	fi
	json_write_atomic "${config}" "${document}"
}

# Print what is registered under one server key in an already-parsed body, or
# nothing when the key is absent. Non-zero means jq could not look. See the
# Claude sibling.
_agent_opencode_forge_entry() {
	local server="${1:?server name required}"
	local body_json="${2:?body JSON required}"

	jq -c --arg name "${server}" '
		if (.mcp | type) == "object" and (.mcp | has($name))
		then .mcp[$name] else empty end
		' <<<"${body_json}" 2>/dev/null
}

# Did riotbox write this entry? Shape, not key name and not a marker key — the
# Claude sibling gives the full reasoning, including the three answers this
# returns (0 ours, 1 not ours, 2 cannot tell), why the token variable's name is
# free while the block holding it is not, and why $shape must always be a
# literal from this file and never anything a session can influence.
#
# opencode's own reason for the same rule: opencode_setup regenerates
# opencode.jsonc from the user's host config at every session start, so an
# entry the user configured on the host is in this file before these verbs ever
# run.
_agent_opencode_forge_is_ours() {
	local entry="${1:?entry JSON required}"
	local shape="${2:?entry shape required}"
	local status=0

	jq -e 'if type == "object" then ('"${shape}"') else false end' \
		<<<"${entry}" >/dev/null 2>&1 || status=$?

	if ((status > 1)); then
		status=2
	fi
	return "${status}"
}

# Merge one server entry into `mcp`, leaving the banner and every other key
# alone. Parse, build and format before writing; skip the write entirely when
# the document already matches. An entry riotbox did not write is replaced, but
# never quietly. Same contract as the Claude sibling.
_agent_opencode_forge_upsert() {
	local server="${1:?server name required}"
	local entry="${2:?entry JSON required}"
	local shape="${3:?entry shape required}"
	local config
	config="$(_agent_opencode_forge_config)"

	local banner body
	banner="$(_agent_opencode_forge_banner "${config}")"
	body="$(_agent_opencode_forge_body "${config}")"
	if [[ -z "${body//[[:space:]]/}" ]]; then
		body='{}'
	fi

	local current
	if ! current="$(jq -c 'if type == "object" then . else error("root must be an object") end' \
		<<<"${body}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [forge-mcp] WARN: ${config} is not a valid JSON object — ${server} not wired." >&2
		return 1
	fi

	# Lenient in both directions, as on the Claude side: only a provable "not
	# ours" warns.
	local existing ownership=0
	if existing="$(_agent_opencode_forge_entry "${server}" "${current}")" && [[ -n "${existing}" ]]; then
		_agent_opencode_forge_is_ours "${existing}" "${shape}" || ownership=$?
		if [[ "${ownership}" -eq 1 ]]; then
			echo "  [forge-mcp] WARN: the ${server} MCP entry in ${config} was not written by riotbox — replacing it." >&2
			echo "  [forge-mcp] WARN: whatever that entry restricted is not preserved." >&2
		fi
	fi

	local wired
	if ! wired="$(jq -c --arg name "${server}" --argjson entry "${entry}" '
		if (.mcp != null) and ((.mcp | type) != "object") then
			error("mcp is not an object")
		else . end
		| .mcp = ((.mcp // {}) | .[$name] = $entry)
		' <<<"${current}" 2>/dev/null)"; then
		echo "  [forge-mcp] WARN: could not add the ${server} entry to ${config} — not wired." >&2
		return 1
	fi

	[[ "${wired}" != "${current}" ]] || return 0

	if ! _agent_opencode_forge_write "${config}" "${banner}" "${wired}"; then
		echo "  [forge-mcp] WARN: could not write ${config} — ${server} not wired." >&2
		return 1
	fi
}

# Delete one server entry, and only if riotbox wrote it. An entry it did not
# write is left alone, with a warning and a 0 return — the user's config is
# what they asked for. Silent and successful when there is nothing to remove; a
# malformed config warns rather than failing the caller, for the reason the
# Claude sibling spells out — the disable commands are the way out of a bad
# state. Every other give-up path returns non-zero instead, also for the reason
# given there: the entry is still registered, and the caller would otherwise
# report a removal that did not happen.
_agent_opencode_forge_remove() {
	local server="${1:?server name required}"
	local shape="${2:?entry shape required}"
	local config
	config="$(_agent_opencode_forge_config)"

	[[ -f "${config}" ]] || return 0

	local banner body
	banner="$(_agent_opencode_forge_banner "${config}")"
	body="$(_agent_opencode_forge_body "${config}")"
	[[ -n "${body//[[:space:]]/}" ]] || return 0

	local current entry stripped
	if ! current="$(jq -c 'if type == "object" then . else error("root must be an object") end' \
		<<<"${body}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [forge-mcp] WARN: ${config} is not a valid JSON object — the ${server} entry was left in place." >&2
		return 0
	fi

	# Near-unreachable, unlike the Claude sibling: the guard above already
	# rejected everything but an object, so nothing that reaches here can make
	# this program fail short of jq being gone or the process killed. It still
	# returns non-zero, because if it ever does fire the entry is still there.
	# The same goes for the delete below.
	if ! entry="$(_agent_opencode_forge_entry "${server}" "${current}")"; then
		echo "  [forge-mcp] WARN: could not clean ${config} — the ${server} entry is still registered." >&2
		return 1
	fi

	[[ -n "${entry}" ]] || return 0

	# See the Claude sibling for why the second warning is there, and why an
	# entry that cannot be classified fails loudly instead of being treated as
	# someone else's.
	local ownership=0
	_agent_opencode_forge_is_ours "${entry}" "${shape}" || ownership=$?
	case "${ownership}" in
	0) : ;;
	1)
		echo "  [forge-mcp] WARN: the ${server} MCP entry in ${config} was not written by riotbox — left in place." >&2
		echo "  [forge-mcp] WARN: riotbox had no ${server} entry of its own to remove." >&2
		return 0
		;;
	*)
		echo "  [forge-mcp] WARN: could not clean ${config} — the ${server} entry is still registered." >&2
		return 1
		;;
	esac

	if ! stripped="$(jq -c --arg name "${server}" 'del(.mcp[$name])' \
		<<<"${current}" 2>/dev/null)" || [[ -z "${stripped}" ]]; then
		echo "  [forge-mcp] WARN: could not clean ${config} — the ${server} entry is still registered." >&2
		return 1
	fi

	if ! _agent_opencode_forge_write "${config}" "${banner}" "${stripped}"; then
		echo "  [forge-mcp] WARN: could not write ${config} — the ${server} entry is still registered." >&2
		return 1
	fi

	echo "  [forge-mcp] Removed the ${server} MCP server from ${config}." >&2
}

# ── GitHub ───────────────────────────────────────────────────────────────────

# What one of our GitHub entries looks like, as a jq predicate over the entry.
# The whole argv is the tell: a user's own `--read-only` server carries a third
# element and is theirs. The `environment` block counts too, and its key set
# exactly — github-mcp-server reads GITHUB_TOOLSETS and GITHUB_HOST from there,
# so an extra key is a narrowing riotbox must not claim. Only the token
# variable's name is free, inside a bare {env:...} reference.
#
# `enabled` is the one field left out on purpose: a user who flipped ours to
# false still has ours, and disable_github_mcp should still take it away.
_AGENT_OPENCODE_FORGE_GITHUB_SHAPE='.type == "local"
	and .command == ["github-mcp-server", "stdio"]
	and (.environment | type) == "object"
	and (.environment | keys) == ["GITHUB_PERSONAL_ACCESS_TOKEN"]
	and (.environment.GITHUB_PERSONAL_ACCESS_TOKEN | type) == "string"
	and (.environment.GITHUB_PERSONAL_ACCESS_TOKEN | test("^\\{env:[A-Za-z_][A-Za-z0-9_]*\\}$"))'

# Register github-mcp-server as a local server.
#
# `command` is an argv array here, where Claude splits the same thing across
# `command` and `args`. The `environment` block bridges GITHUB_TOKEN to the
# GITHUB_PERSONAL_ACCESS_TOKEN the server actually reads, which is the only
# reason it is present.
agent_opencode_github_mcp_wire() {
	local token_var="${1:?github_mcp_wire requires the name of the token variable}"

	if ! _agent_opencode_forge_valid_var "${token_var}"; then
		echo "  [forge-mcp] WARN: '${token_var}' is not a valid environment variable name — github not wired." >&2
		return 1
	fi

	local entry
	if ! entry="$(jq -nc --arg ref "{env:${token_var}}" '{
		type: "local",
		command: ["github-mcp-server", "stdio"],
		enabled: true,
		environment: {GITHUB_PERSONAL_ACCESS_TOKEN: $ref}
	}')"; then
		echo "  [forge-mcp] WARN: could not build the github entry — not wired." >&2
		return 1
	fi

	_agent_opencode_forge_upsert "${_AGENT_OPENCODE_FORGE_GITHUB_SERVER}" "${entry}" \
		"${_AGENT_OPENCODE_FORGE_GITHUB_SHAPE}"
}

agent_opencode_github_mcp_strip() {
	_agent_opencode_forge_remove "${_AGENT_OPENCODE_FORGE_GITHUB_SERVER}" \
		"${_AGENT_OPENCODE_FORGE_GITHUB_SHAPE}"
}

# ── GitLab ───────────────────────────────────────────────────────────────────

# What one of our GitLab entries looks like: the transport, the /api/v4/mcp
# endpoint on whatever host the session named, and exactly one header holding a
# {env:VAR} reference rather than a token. The Claude sibling explains why the
# host is excluded and the path is not. `enabled` is left out for the reason
# given above the GitHub shape.
_AGENT_OPENCODE_FORGE_GITLAB_SHAPE='.type == "remote"
	and (.url | type) == "string"
	and (.url | endswith("/api/v4/mcp"))
	and (.headers | type) == "object"
	and (.headers | keys) == ["Authorization"]
	and (.headers.Authorization | type) == "string"
	and (.headers.Authorization | test("^Bearer \\{env:[A-Za-z_][A-Za-z0-9_]*\\}$"))'

# Register the GitLab instance's own MCP endpoint as a remote server. The URL
# arrives resolved and is written literally; only the credential is a reference.
# See the Claude sibling for why a personal access token authenticates on this
# header, why OAuth is not an option in a headless container, and why the
# endpoint guard below has to match the shape above — a wire that accepts a URL
# this file's own strip disowns writes a server the user cannot revoke.
agent_opencode_gitlab_mcp_wire() {
	local api_url="${1:?gitlab_mcp_wire requires the MCP endpoint URL}"
	local token_var="${2:?gitlab_mcp_wire requires the name of the token variable}"

	if [[ "${api_url}" != http://* ]] && [[ "${api_url}" != https://* ]]; then
		echo "  [forge-mcp] WARN: '${api_url}' is not an http(s) URL — gitlab not wired." >&2
		return 1
	fi

	if [[ "${api_url}" != */api/v4/mcp ]]; then
		echo "  [forge-mcp] WARN: '${api_url}' is not a GitLab /api/v4/mcp endpoint — gitlab not wired." >&2
		return 1
	fi

	if ! _agent_opencode_forge_valid_var "${token_var}"; then
		echo "  [forge-mcp] WARN: '${token_var}' is not a valid environment variable name — gitlab not wired." >&2
		return 1
	fi

	local entry
	if ! entry="$(jq -nc --arg url "${api_url}" --arg ref "Bearer {env:${token_var}}" '{
		type: "remote",
		url: $url,
		enabled: true,
		headers: {Authorization: $ref}
	}')"; then
		echo "  [forge-mcp] WARN: could not build the gitlab entry — not wired." >&2
		return 1
	fi

	_agent_opencode_forge_upsert "${_AGENT_OPENCODE_FORGE_GITLAB_SERVER}" "${entry}" \
		"${_AGENT_OPENCODE_FORGE_GITLAB_SHAPE}"
}

agent_opencode_gitlab_mcp_strip() {
	_agent_opencode_forge_remove "${_AGENT_OPENCODE_FORGE_GITLAB_SERVER}" \
		"${_AGENT_OPENCODE_FORGE_GITLAB_SHAPE}"
}
