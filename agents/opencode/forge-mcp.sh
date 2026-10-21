#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/forge-mcp.sh — take back the GitHub and GitLab MCP entries
# that earlier images wired into opencode's config.
#
# Sourced by agents/opencode/manifest.sh. agent_opencode_container_setup calls
# opencode_strip_forge_mcp_entries at every session start, after opencode_setup.
#
# This is the counterpart of claude_strip_forge_mcp_entries in
# agents/claude/forge-mcp.sh. That file gives the reason the entries are
# removed (issue #19) and the rule for deciding which are ours: the entry's
# SHAPE, never its key name. Both apply here unchanged.
#
# Why opencode needs it too: opencode_setup does not start from scratch. It
# MERGES the persisted ~/.config/opencode/opencode.jsonc into the file it
# writes, and the persisted side wins. agents/opencode/sync-settings.sh resets
# that directory only when the host has its own ~/.config/opencode. A stale
# mcp.github / mcp.gitlab entry written by enable_*_mcp therefore survives
# restarts, and is merged back in every time.
#
# Only the dialect differs. opencode declares servers under `mcp`; a local one
# has a single `command` argv array and an `environment` object, a remote one
# has `url` and `headers`; variable substitution is {env:VAR}. `enabled` is
# left out of both predicates on purpose: a user who flipped our entry to false
# still has our entry.
#
# opencode.jsonc is `//` banner lines followed by a jq-generated plain-JSON
# body (see opencode_setup, and agents/opencode/headroom-exec.sh, which relies
# on the same split). Line-level splitting is safe for that reason only: the
# body never contains a line starting with `//`. Do not point this at a
# hand-written JSONC file.
# ─────────────────────────────────────────────────────────────────────────────

# Silent when there is nothing to remove. Always returns 0: a cleanup that
# cannot finish warns and leaves the file as it was, and never blocks a session
# from starting.
opencode_strip_forge_mcp_entries() {
	local config="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/opencode.jsonc"
	[[ -f "${config}" ]] || return 0

	# grep exits 1 when no line matches, which is a legitimate empty half, and 2
	# on a read error, which must not pass for one.
	local banner body status=0
	banner="$(grep '^//' "${config}")" || status=$?
	if ((status <= 1)); then
		status=0
		body="$(grep -v '^//' "${config}")" || status=$?
	fi
	if ((status > 1)); then
		echo "  [forge-mcp] WARN: could not read ${config} — stale GitHub/GitLab MCP entries not removed." >&2
		return 0
	fi
	[[ -n "${body//[[:space:]]/}" ]] || return 0

	local current
	if ! current="$(jq -c 'if type == "object" then . else error("root must be an object") end' \
		<<<"${body}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [forge-mcp] WARN: ${config} is not a valid JSON object — stale GitHub/GitLab MCP entries not removed." >&2
		return 0
	fi

	local stripped
	if ! stripped="$(jq -c '
		def github_ours:
			type == "object"
			and .type == "local"
			and .command == ["github-mcp-server", "stdio"]
			and (.environment | type) == "object"
			and (.environment | keys) == ["GITHUB_PERSONAL_ACCESS_TOKEN"]
			and (.environment.GITHUB_PERSONAL_ACCESS_TOKEN | type) == "string"
			and (.environment.GITHUB_PERSONAL_ACCESS_TOKEN | test("^\\{env:[A-Za-z_][A-Za-z0-9_]*\\}\\z"));
		def gitlab_ours:
			type == "object"
			and .type == "remote"
			and (.url | type) == "string"
			and (.url | endswith("/api/v4/mcp"))
			and (.headers | type) == "object"
			and (.headers | keys) == ["Authorization"]
			and (.headers.Authorization | type) == "string"
			and (.headers.Authorization | test("^Bearer \\{env:[A-Za-z_][A-Za-z0-9_]*\\}\\z"));

		if (.mcp | type) == "object" then
			(if (.mcp.github | github_ours) then del(.mcp.github) else . end)
			| (if (.mcp.gitlab | gitlab_ours) then del(.mcp.gitlab) else . end)
		else . end
		' <<<"${current}" 2>/dev/null)" || [[ -z "${stripped}" ]]; then
		echo "  [forge-mcp] WARN: could not clean ${config} — stale GitHub/GitLab MCP entries left in place." >&2
		return 0
	fi

	# An untouched document means stay silent and do not rewrite the file.
	[[ "${stripped}" != "${current}" ]] || return 0

	# json_write_atomic takes the whole document as one string, banner
	# included, so the staged-file-then-rename guarantee covers both halves.
	# It never parses its content, so the `//` lines are no obstacle.
	local pretty document
	if ! pretty="$(jq . <<<"${stripped}")" || [[ -z "${pretty}" ]]; then
		echo "  [forge-mcp] WARN: could not clean ${config} — stale GitHub/GitLab MCP entries left in place." >&2
		return 0
	fi
	document="${pretty}"
	[[ -z "${banner}" ]] || document="${banner}"$'\n'"${pretty}"
	if ! json_write_atomic "${config}" "${document}"; then
		echo "  [forge-mcp] WARN: could not write ${config} — stale GitHub/GitLab MCP entries left in place." >&2
		return 0
	fi

	echo "  [forge-mcp] Removed the GitHub/GitLab MCP server entries an earlier image left" >&2
	echo "  [forge-mcp] in ${config}. The gh and glab CLIs are unaffected." >&2
}
