#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/forge-mcp.sh — GitHub and GitLab MCP wiring for Claude Code.
#
# Sourced by agents/claude/manifest.sh, which exposes the optional forge verbs
# (github_mcp_wire, github_mcp_strip, gitlab_mcp_wire, gitlab_mcp_strip).
# container/forge-mcp.sh drives them and holds no agent names of its own.
#
# "Forge" is GitHub or GitLab. The two share this file because they share a
# destination — Claude Code reads every MCP server from one object in one file —
# and nothing else. They do not share an entry shape:
#
#   * GitHub is a local stdio process. The image bakes in github-mcp-server and
#     the entry names it, with the credential handed over in the server's own
#     environment block.
#   * GitLab is not a program at all. It is an endpoint on the user's GitLab
#     instance (<host>/api/v4/mcp, streamable HTTP), so the entry is a URL and
#     the credential rides in an Authorization header.
#
# Neither server is registered at build time or at session start. A session
# gets one only by running enable_github_mcp / enable_gitlab_mcp, which is what
# issue #9 asks for.
#
# ── Credentials are named, never copied ─────────────────────────────────────
#
# The wire verbs take the NAME of an environment variable and write a
# `${NAME}` reference into the config. They never read its value, so no
# credential passes through this file at all.
#
# That is not defensive habit, it is the threat model. CLAUDE_CONFIG_DIR
# resolves into the session directory, which is a bind mount from the host: a
# token written here outlives the container, survives the agent exiting, and
# stays readable by anything on the host that can read the session directory.
# A reference cannot leak what it does not contain.
#
# Claude Code expands ${VAR} and ${VAR:-default} in command, args, env, url and
# headers, in ~/.claude.json entries as well as .mcp.json ones — verified
# against the Claude Code MCP documentation, "Environment variable expansion".
#
# One upstream behaviour shapes the caller rather than this file: an unset
# variable is NOT an error to Claude Code. It loads the server with the literal
# text "${VAR}" and mentions the missing variable only in `claude mcp list`
# output, which an autonomous run never reads. container/forge-mcp.sh therefore
# refuses to call these verbs at all when no candidate variable is set, rather
# than wiring a server that fails at its first tool call.
# ─────────────────────────────────────────────────────────────────────────────

# The keys these verbs write in .mcpServers. Claude Code derives tool names from
# them (mcp__github__*, mcp__gitlab__*), so they are part of what the model
# sees. The key alone does not make an entry ours — see the ownership rule
# below.
_AGENT_CLAUDE_FORGE_GITHUB_SERVER='github'
_AGENT_CLAUDE_FORGE_GITLAB_SERVER='gitlab'

# The file Claude Code reads MCP servers from. Same file Context Mode's MCP
# entry and CodeGraph's relocated entry live in, hence the read-modify-write
# below rather than a wholesale rewrite: three features share this document.
_agent_claude_forge_config() {
	printf '%s\n' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.claude.json"
}

# Reject anything that is not a shell identifier before it reaches the config.
#
# jq --arg quotes its input, so this is not an injection guard — it is a
# typo guard. `${GITHUB TOKEN}` or an empty name would sail through jq, land
# in the config as a reference Claude Code cannot resolve, and present as a
# server that authenticates as nobody. Failing here names the real problem.
_agent_claude_forge_valid_var() {
	[[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Print what is registered under one server key in an already-parsed config, or
# nothing when the key is absent. Both callers need the entry itself: one to
# decide whether to warn before overwriting it, the other whether to delete it.
#
# Non-zero means jq could not look: a root that is not an object cannot be
# indexed with .mcpServers, which is an error rather than a false test. Each
# caller reports that in its own terms.
_agent_claude_forge_entry() {
	local server="${1:?server name required}"
	local config_json="${2:?config JSON required}"

	jq -c --arg name "${server}" '
		if (.mcpServers | type) == "object" and (.mcpServers | has($name))
		then .mcpServers[$name] else empty end
		' <<<"${config_json}" 2>/dev/null
}

# Did riotbox write this entry? Decided on the entry's SHAPE — $shape is a jq
# predicate evaluated against it, defined beside the wire verb that produces
# the entry it mirrors.
#
# The key name cannot answer the question. agents/claude/sync-settings.sh
# copies the host's ~/.claude.json into the session at every launch, so a
# `github` entry the user configured on the host is sitting in the very file
# these verbs write. Treating the key as ours would silently discard a
# deliberate narrowing (a --read-only server, a restricted toolset) on wire and
# delete it on strip.
#
# Not a marker key, either. This document's schema belongs to Claude Code,
# which is free to reject or drop a field it does not know; ownership would
# then hinge on whether an unrelated release tolerated our field.
#
# The shapes ignore the credential's variable NAME on purpose. A session that
# exported GITHUB_PERSONAL_ACCESS_TOKEN on one run and GITHUB_TOKEN on the next
# wrote riotbox's entry both times, and a strip that could not recognise the
# first would leave a server registered that the user asked to revoke. They do
# not ignore the block that carries it: a restriction the user put beside the
# credential is exactly what must not be mistaken for ours.
#
# Three answers, not two:
#   0  ours
#   1  provably not ours
#   2  cannot tell — jq could not evaluate the predicate
# Folding 2 into 1 would report an entry riotbox DID write as foreign, leaving
# it registered while the caller announces a removal. The strip verb turns 2
# into a loud failure; the wire verb, which is about to overwrite the entry
# either way, only stays quiet.
#
# $shape is spliced into the jq program rather than passed as data, so it must
# always be a literal defined in this file. Never derive one from a config
# file, an environment variable or anything else a session can influence: that
# would turn a config value into executable jq.
_agent_claude_forge_is_ours() {
	local entry="${1:?entry JSON required}"
	local shape="${2:?entry shape required}"
	local status=0

	jq -e 'if type == "object" then ('"${shape}"') else false end' \
		<<<"${entry}" >/dev/null 2>&1 || status=$?

	# jq -e exits 1 for a false or null result and reserves everything else for
	# a program or evaluation error.
	if ((status > 1)); then
		status=2
	fi
	return "${status}"
}

# Merge one server entry into .mcpServers, leaving every other key alone.
#
# Everything is parsed, built and formatted before anything is written, so a
# failure that can be seen at all is seen while the config is still untouched —
# the rule agent_claude_context_mode_wire follows for the same file.
#
# A document that already matches is not rewritten. That is what makes a second
# call a no-op, and it is why re-running an enable script costs nothing.
#
# Compact for the comparison, pretty-printed for the write: this file is
# hand-edited and the sibling features pretty-print wherever they touch it, so
# reflowing the whole document to add one entry would be a far larger change
# than the one being made. Emptiness is checked alongside jq's exit status
# because an unchecked command substitution yields "" when jq prints nothing,
# and the writer would put a lone newline where the user's config was.
#
# An entry riotbox did not write is still replaced — a user who runs
# enable_github_mcp asked for riotbox's server — but never quietly. What that
# entry restricted is gone, and only the warning says so.
_agent_claude_forge_upsert() {
	local server="${1:?server name required}"
	local entry="${2:?entry JSON required}"
	local shape="${3:?entry shape required}"
	local config
	config="$(_agent_claude_forge_config)"

	local current='{}'
	if [[ -f "${config}" ]]; then
		if ! current="$(jq -c '.' "${config}" 2>/dev/null)" || [[ -z "${current}" ]]; then
			echo "  [forge-mcp] WARN: ${config} is not valid JSON — ${server} not wired." >&2
			return 1
		fi
	fi

	# Lenient by design, in both directions: a document this cannot read is one
	# the build below cannot edit either, and that failure is already reported,
	# while an entry that cannot be classified is not accused of being someone
	# else's. Only a provable "not ours" warns.
	local existing ownership=0
	if existing="$(_agent_claude_forge_entry "${server}" "${current}")" && [[ -n "${existing}" ]]; then
		_agent_claude_forge_is_ours "${existing}" "${shape}" || ownership=$?
		if [[ "${ownership}" -eq 1 ]]; then
			echo "  [forge-mcp] WARN: the ${server} MCP entry in ${config} was not written by riotbox — replacing it." >&2
			echo "  [forge-mcp] WARN: whatever that entry restricted is not preserved." >&2
		fi
	fi

	local wired
	if ! wired="$(jq -c --arg name "${server}" --argjson entry "${entry}" '
		if (.mcpServers != null) and ((.mcpServers | type) != "object") then
			error("mcpServers is not an object")
		else . end
		| .mcpServers = ((.mcpServers // {}) | .[$name] = $entry)
		' <<<"${current}" 2>/dev/null)"; then
		echo "  [forge-mcp] WARN: could not add the ${server} entry to ${config} — not wired." >&2
		return 1
	fi

	[[ "${wired}" != "${current}" ]] || return 0

	local pretty
	if ! pretty="$(jq . <<<"${wired}")" || [[ -z "${pretty}" ]]; then
		echo "  [forge-mcp] WARN: could not format ${config} — ${server} not wired." >&2
		return 1
	fi

	if ! json_write_atomic "${config}" "${pretty}"; then
		echo "  [forge-mcp] WARN: could not write ${config} — ${server} not wired." >&2
		return 1
	fi
}

# Delete one server entry, and only if riotbox wrote it.
#
# Silent and successful when there is nothing to remove: strip runs against
# sessions that never had the feature, and against every failure path in the
# wire verbs, so noise here would be noise in the common case.
#
# An entry riotbox did not write is left alone, with a warning and a 0 return.
# That is not a give-up path: the user asked to remove riotbox's server, there
# is none, and their own is exactly where they put it. Deleting it would be the
# failure — disable_github_mcp would be a command that quietly throws away a
# GitHub server the user configured on the host and riotbox merely copied in.
#
# A malformed config warns rather than failing the caller. The disable commands
# are how a user gets out of a bad state; refusing to finish because some other
# tool corrupted the file would strand them with no way forward but hand-editing
# the very file that cannot be parsed.
#
# Every other give-up path returns non-zero — the edit that could not be built
# as much as the write that could not land. In both the entry is provably still
# registered, and container/forge-mcp.sh turns a 0 into "<forge> MCP cleanup
# complete." on stdout and exits 0 — telling someone who asked to revoke an
# agent's forge access that the command did its job when it did not.
_agent_claude_forge_remove() {
	local server="${1:?server name required}"
	local shape="${2:?entry shape required}"
	local config
	config="$(_agent_claude_forge_config)"

	[[ -f "${config}" ]] || return 0

	local current entry stripped pretty
	if ! current="$(jq -c '.' "${config}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [forge-mcp] WARN: ${config} is not valid JSON — the ${server} entry was left in place." >&2
		return 0
	fi

	# The non-zero here is reached by a document that parses but is not an
	# object: indexing an array or a scalar with .mcpServers is a jq error, not
	# a false test. Rare, and still a config this cannot edit — hence non-zero
	# rather than a shrug.
	if ! entry="$(_agent_claude_forge_entry "${server}" "${current}")"; then
		echo "  [forge-mcp] WARN: could not clean ${config} — the ${server} entry is still registered." >&2
		return 1
	fi

	[[ -n "${entry}" ]] || return 0

	# The second warning names what the caller's "removed" line is about.
	local ownership=0
	_agent_claude_forge_is_ours "${entry}" "${shape}" || ownership=$?
	case "${ownership}" in
	0) : ;;
	1)
		echo "  [forge-mcp] WARN: the ${server} MCP entry in ${config} was not written by riotbox — left in place." >&2
		echo "  [forge-mcp] WARN: riotbox had no ${server} entry of its own to remove." >&2
		return 0
		;;
	*)
		# An entry that cannot be classified may well be ours, so this is a
		# give-up path and takes the give-up return.
		echo "  [forge-mcp] WARN: could not clean ${config} — the ${server} entry is still registered." >&2
		return 1
		;;
	esac

	# Near-unreachable now that the read above proved .mcpServers is an object
	# holding the key. Kept because if it ever does fire the entry is still
	# registered, which is the one thing this must not report as a removal.
	if ! stripped="$(jq -c --arg name "${server}" 'del(.mcpServers[$name])' \
		<<<"${current}" 2>/dev/null)" || [[ -z "${stripped}" ]]; then
		echo "  [forge-mcp] WARN: could not clean ${config} — the ${server} entry is still registered." >&2
		return 1
	fi

	if ! pretty="$(jq . <<<"${stripped}")" || [[ -z "${pretty}" ]] ||
		! json_write_atomic "${config}" "${pretty}"; then
		echo "  [forge-mcp] WARN: could not write ${config} — the ${server} entry is still registered." >&2
		return 1
	fi

	echo "  [forge-mcp] Removed the ${server} MCP server from ${config}." >&2
}

# ── GitHub ───────────────────────────────────────────────────────────────────

# What one of our GitHub entries looks like, as a jq predicate over the entry.
# It lives beside the entry it describes so the two are read — and changed —
# together, and it must stay an exact statement of what the wire verb below
# writes: every field it leaves out is a field a user can differ on and still
# lose their entry.
#
# argv and the env block both matter, because github-mcp-server takes its
# restrictions from both. `["stdio", "--read-only"]` is a narrowing, and so is
# a GITHUB_TOOLSETS beside the token — which is why the key SET has to be
# exactly the one key riotbox writes. Only the variable's name is free, and
# only inside a bare `${...}` reference: a literal token under that key is not
# something these verbs can produce.
_AGENT_CLAUDE_FORGE_GITHUB_SHAPE='.type == "stdio"
	and .command == "github-mcp-server"
	and .args == ["stdio"]
	and (.env | type) == "object"
	and (.env | keys) == ["GITHUB_PERSONAL_ACCESS_TOKEN"]
	and (.env.GITHUB_PERSONAL_ACCESS_TOKEN | type) == "string"
	and (.env.GITHUB_PERSONAL_ACCESS_TOKEN | test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$"))'

# Register github-mcp-server as a stdio server.
#
# Takes the name of the variable holding the token. The env block exists for
# exactly one reason: the server reads GITHUB_PERSONAL_ACCESS_TOKEN and issue #9
# asks that GITHUB_TOKEN work, so something has to bridge the two names. A
# stdio child already inherits the agent's environment, so without that alias
# this block would be redundant.
#
# GITHUB_HOST (GitHub Enterprise Server) and GITHUB_TOOLSETS are deliberately
# absent: the server reads both from the environment it inherits, so a session
# that exports them already gets them, and writing an opinion here would be one
# the user did not ask for.
agent_claude_github_mcp_wire() {
	local token_var="${1:?github_mcp_wire requires the name of the token variable}"

	if ! _agent_claude_forge_valid_var "${token_var}"; then
		echo "  [forge-mcp] WARN: '${token_var}' is not a valid environment variable name — github not wired." >&2
		return 1
	fi

	local entry
	if ! entry="$(jq -nc --arg ref "\${${token_var}}" '{
		type: "stdio",
		command: "github-mcp-server",
		args: ["stdio"],
		env: {GITHUB_PERSONAL_ACCESS_TOKEN: $ref}
	}')"; then
		echo "  [forge-mcp] WARN: could not build the github entry — not wired." >&2
		return 1
	fi

	_agent_claude_forge_upsert "${_AGENT_CLAUDE_FORGE_GITHUB_SERVER}" "${entry}" \
		"${_AGENT_CLAUDE_FORGE_GITHUB_SHAPE}"
}

agent_claude_github_mcp_strip() {
	_agent_claude_forge_remove "${_AGENT_CLAUDE_FORGE_GITHUB_SERVER}" \
		"${_AGENT_CLAUDE_FORGE_GITHUB_SHAPE}"
}

# ── GitLab ───────────────────────────────────────────────────────────────────

# What one of our GitLab entries looks like. The URL's HOST is not part of it —
# it comes from GITLAB_HOST, which a session may legitimately change between
# the wire call and the strip — but its PATH is: _forge_mcp_gitlab_url in
# container/forge-mcp.sh appends /api/v4/mcp to whatever host it was given, so
# an entry pointing anywhere else on a GitLab instance is not one of ours.
#
# The header set is exact for the same reason the GitHub env block is: a header
# the user added beside the credential is a difference riotbox cannot honour
# and must not silently discard.
_AGENT_CLAUDE_FORGE_GITLAB_SHAPE='.type == "http"
	and (.url | type) == "string"
	and (.url | endswith("/api/v4/mcp"))
	and (.headers | type) == "object"
	and (.headers | keys) == ["Authorization"]
	and (.headers.Authorization | type) == "string"
	and (.headers.Authorization | test("^Bearer \\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$"))'

# Register the GitLab instance's own MCP endpoint as an HTTP server.
#
# The URL arrives already resolved and is written literally, unlike the token.
# It is not a secret, and a `${GITLAB_HOST}` left unexpanded inside a URL would
# produce a malformed endpoint — a confusing connection error instead of an
# honest "you have not set this".
#
# A GitLab personal access token authenticates on this header: GitLab's REST
# authentication documentation states that personal, project and group access
# tokens work with OAuth-compliant headers, and GitLab carries a dedicated `mcp`
# PAT scope (lib/gitlab/auth.rb, MCP_SCOPE) for exactly this. That matters
# because GitLab documents browser OAuth as the default path, and a headless
# container has no browser.
#
# The endpoint guard below is what keeps this verb and its strip in agreement.
# The shape above disowns an entry that is not on /api/v4/mcp, so accepting one
# here would register a server the disable command then refuses to remove —
# stranding the user with exactly the "riotbox wrote it, riotbox will not take
# it back" state the ownership rule exists to prevent. Nothing riotbox ships
# can reach it (container/forge-mcp.sh builds the path itself), but this verb
# is also the contract a third agent and any direct caller implement against.
agent_claude_gitlab_mcp_wire() {
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

	if ! _agent_claude_forge_valid_var "${token_var}"; then
		echo "  [forge-mcp] WARN: '${token_var}' is not a valid environment variable name — gitlab not wired." >&2
		return 1
	fi

	local entry
	if ! entry="$(jq -nc --arg url "${api_url}" --arg ref "Bearer \${${token_var}}" '{
		type: "http",
		url: $url,
		headers: {Authorization: $ref}
	}')"; then
		echo "  [forge-mcp] WARN: could not build the gitlab entry — not wired." >&2
		return 1
	fi

	_agent_claude_forge_upsert "${_AGENT_CLAUDE_FORGE_GITLAB_SERVER}" "${entry}" \
		"${_AGENT_CLAUDE_FORGE_GITLAB_SHAPE}"
}

agent_claude_gitlab_mcp_strip() {
	_agent_claude_forge_remove "${_AGENT_CLAUDE_FORGE_GITLAB_SERVER}" \
		"${_AGENT_CLAUDE_FORGE_GITLAB_SHAPE}"
}
