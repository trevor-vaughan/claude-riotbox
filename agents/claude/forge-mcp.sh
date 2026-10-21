#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/forge-mcp.sh — take back the GitHub and GitLab MCP entries that
# earlier images wired into Claude Code's config.
#
# Sourced by agents/claude/manifest.sh. agent_claude_container_setup calls
# claude_strip_forge_mcp_entries at every session start.
#
# Images up to 0.6.1 shipped enable_github_mcp and enable_gitlab_mcp, which
# registered a server in ${CLAUDE_CONFIG_DIR}/.claude.json. Issue #19 removed
# them: the servers' tool schemas cost more context than they returned, and the
# gh and glab CLIs, which models already know, cover the same ground.
#
# That file is in the session directory, a host bind mount, so an entry
# outlives the image that wrote it. agents/claude/sync-settings.sh overwrites it
# from the host's ~/.claude.json at launch, but cannot when there is no host
# copy. A leftover GitHub entry names a binary this image no longer has; a
# leftover GitLab entry is a URL on the user's own instance, so it keeps working
# and keeps spending the context its removal was meant to save. opencode needs
# its own counterpart, opencode_strip_forge_mcp_entries, in
# agents/opencode/forge-mcp.sh.
#
# Ownership is decided on the entry's SHAPE, never on the key name. The host
# copy can carry a `github` or `gitlab` server the user configured themselves,
# and a narrowing they added (--read-only, GITHUB_TOOLSETS, an extra header, a
# literal token) is theirs to keep. Each predicate below is an exact statement
# of what the removed wire verb wrote; only the token variable's NAME was free,
# and only inside a bare ${...} reference.
# ─────────────────────────────────────────────────────────────────────────────

# Silent when there is nothing to remove — the common case is a session that
# never ran an enable command. Always returns 0: a cleanup that cannot finish
# warns and leaves the file as it was, and never blocks a session from starting.
claude_strip_forge_mcp_entries() {
	local config="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.claude.json"
	[[ -f "${config}" ]] || return 0

	# Emptiness is checked beside jq's exit status: `jq -c .` on a zero-byte
	# file succeeds and prints nothing.
	local current
	if ! current="$(jq -c '.' "${config}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [forge-mcp] WARN: ${config} is not valid JSON — stale GitHub/GitLab MCP entries not removed." >&2
		return 0
	fi

	# A root that is not an object cannot be indexed with .mcpServers; jq
	# raises, and that lands in the WARN below rather than a false "nothing".
	local stripped
	if ! stripped="$(jq -c '
		def github_ours:
			type == "object"
			and .type == "stdio"
			and .command == "github-mcp-server"
			and .args == ["stdio"]
			and (.env | type) == "object"
			and (.env | keys) == ["GITHUB_PERSONAL_ACCESS_TOKEN"]
			and (.env.GITHUB_PERSONAL_ACCESS_TOKEN | type) == "string"
			and (.env.GITHUB_PERSONAL_ACCESS_TOKEN | test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}\\z"));
		def gitlab_ours:
			type == "object"
			and .type == "http"
			and (.url | type) == "string"
			and (.url | endswith("/api/v4/mcp"))
			and (.headers | type) == "object"
			and (.headers | keys) == ["Authorization"]
			and (.headers.Authorization | type) == "string"
			and (.headers.Authorization | test("^Bearer \\$\\{[A-Za-z_][A-Za-z0-9_]*\\}\\z"));

		if (.mcpServers | type) == "object" then
			(if (.mcpServers.github | github_ours) then del(.mcpServers.github) else . end)
			| (if (.mcpServers.gitlab | gitlab_ours) then del(.mcpServers.gitlab) else . end)
		else . end
		' <<<"${current}" 2>/dev/null)" || [[ -z "${stripped}" ]]; then
		echo "  [forge-mcp] WARN: could not clean ${config} — stale GitHub/GitLab MCP entries left in place." >&2
		return 0
	fi

	# An untouched document means stay silent and do not reflow a hand-edited
	# file just to say nothing happened.
	[[ "${stripped}" != "${current}" ]] || return 0

	local pretty
	if ! pretty="$(jq . <<<"${stripped}")" || [[ -z "${pretty}" ]] ||
		! json_write_atomic "${config}" "${pretty}"; then
		echo "  [forge-mcp] WARN: could not write ${config} — stale GitHub/GitLab MCP entries left in place." >&2
		return 0
	fi

	echo "  [forge-mcp] Removed the GitHub/GitLab MCP server entries an earlier image left" >&2
	echo "  [forge-mcp] in ${config}. The gh and glab CLIs are unaffected." >&2
}
