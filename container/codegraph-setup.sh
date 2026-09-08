#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# codegraph-setup.sh — CodeGraph cleanup and index hint for a RiotBox session.
#
# Sourced by entrypoint.sh. Provides:
#   codegraph_setup — remove the MCP wiring an earlier image left in this
#                     session directory, then hint at unindexed projects.
#
# RiotBox ships the `codegraph` CLI and registers nothing. It used to run
# `codegraph install` every session; that server conflicted with Context Mode,
# and `codegraph explore` answers the same questions from the shell for none of
# the per-session overhead. Removing the call is only half the job — the
# installer wrote into a session directory that outlives the image, so the other
# half is taking those artifacts back, which is what this file now does.
#
# Depends on json_write_atomic (scripts/lib/json-write.sh), which entrypoint.sh
# sources ahead of this file. Not sourced from here: the same writer is shared
# with context-mode-setup.sh, and the entrypoint composes all of these into one
# shell — see the source block there.
#
# Why this runs per session rather than at build time: ~/.claude and
# ~/.config/opencode are replaced by session bind mounts (see
# scripts/mount-projects.sh), so agent config written into the image is
# invisible at runtime — the same reason plugin-setup.sh copies from a staging
# directory. A session directory can arrive carrying wiring from any older
# image, so the cleanup has to run every time, not once.
#
# Indexing is never started automatically. `codegraph init` writes a
# multi-megabyte index into the user's project tree and takes real time on a
# large repo; that stays an explicit, once-per-project choice. With no MCP
# server running there is nothing to sync an index in the background either: it
# is refreshed when the user runs CodeGraph again.
# ─────────────────────────────────────────────────────────────────────────────

# Workspace root. Overridable so the behavior can be tested without /workspace.
CODEGRAPH_WORKSPACE="${CODEGRAPH_WORKSPACE:-/workspace}"

# Remove the MCP entry an earlier image's `codegraph install` left behind.
#
# RiotBox used to run that installer every session and relocate its entry into
# ${CLAUDE_CONFIG_DIR}/.claude.json, the file Claude Code actually reads — the
# installer writes to ${HOME}/.claude.json and does not honor CLAUDE_CONFIG_DIR.
# It no longer does either: the server conflicts with Context Mode, and
# `codegraph explore` answers the same questions from the shell. What is left is
# taking back what RiotBox wrote.
#
# The host copy normally does that for us — agents/claude/sync-settings.sh
# overwrites this file from the host's ~/.claude.json at every launch. It cannot
# when there is no host file to copy, which is the case for anyone who
# authenticated inside the container, and there the relocated entry would
# persist for the life of the session directory. That used to be nearly
# harmless: an image without the binary registered a server that could not
# start. It is not harmless now. The CLI is still installed, so a leftover entry
# starts a working second server — the exact conflict this change exists to end.
#
# Ownership is decided on the entry's SHAPE, never on the key name;
# agents/claude/forge-mcp.sh sets out the reasoning at length. The same file
# holds whatever the user configured on the host, under this very key, and an
# entry they narrowed themselves is theirs to keep.
codegraph_strip_mcp_entry() {
	local config="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.claude.json"
	[[ -f "${config}" ]] || return 0

	local current
	if ! current="$(jq -c '.' "${config}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [codegraph] WARN: ${config} is not valid JSON — MCP entry not removed." >&2
		return 0
	fi

	# The shape `codegraph install` writes, read off a live session:
	# {"type":"stdio","command":"codegraph","args":["serve","--mcp"]}. A
	# directory in front of the binary is allowed for the same reason
	# is_installer_hook allows one below — the installer resolves the command
	# differently on some targets — and nothing else is. The .command type test
	# guards the endswith: jq raises on a non-string, and an error here would
	# abort the whole filter and strand the entry this exists to remove.
	local stripped
	if ! stripped="$(jq -c '
		def is_ours:
			type == "object"
			and .type == "stdio"
			and (.command | type) == "string"
			and (.command == "codegraph" or (.command | endswith("/codegraph")))
			and .args == ["serve", "--mcp"];

		if (.mcpServers | type) == "object"
			and (.mcpServers.codegraph | is_ours)
		then del(.mcpServers.codegraph) else . end
		' <<<"${current}" 2>/dev/null)"; then
		echo "  [codegraph] WARN: could not clean ${config} — MCP entry left in place." >&2
		return 0
	fi

	# An untouched document is what tells this function to stay silent: a
	# session that never had CodeGraph must not hear about a cleanup, and one
	# whose entry is the user's own must not have its file reflowed to say so.
	[[ "${stripped}" != "${current}" ]] || return 0

	# Compact for the comparison above, pretty-printed for the write. Same split
	# as codegraph_strip_session_wiring and agents/claude/forge-mcp.sh, for the
	# same reason: this document is hand-edited, and collapsing it onto one line
	# to delete a single entry is a far larger change than the one being made.
	#
	# Checked for emptiness as well as exit status — an unchecked command
	# substitution yields "" when jq fails, and the writer would put a lone
	# newline where the account metadata was.
	local pretty
	if ! pretty="$(jq . <<<"${stripped}")" || [[ -z "${pretty}" ]] ||
		! json_write_atomic "${config}" "${pretty}"; then
		echo "  [codegraph] WARN: could not write ${config} — MCP entry left in place." >&2
		return 0
	fi

	echo "  [codegraph] Removed the CodeGraph MCP server entry that an earlier image left" >&2
	echo "  [codegraph] in ${config}. The 'codegraph' CLI is unaffected." >&2
}

# Remove the wiring `codegraph install` left in the session settings.json.
#
# Called on every session. A session directory outlives the image, and a host
# settings.json is deliberately never synced into it (plugin-setup.sh), so
# nothing regenerates this file — a session wired by an earlier image would keep
# a UserPromptSubmit hook invoking `codegraph prompt-hook` on every prompt, and
# would keep the `mcp__codegraph__*` permission standing for a server nothing
# registers any more. Of the four things the installer wrote, this file is the
# one that persists unconditionally. The .claude.json entry survives only where
# there is no host copy to overwrite it (see codegraph_strip_mcp_entry, which
# handles that one). The CLAUDE.md block is re-copied from the host each launch,
# and removed outright when the host has no CLAUDE.md, so it cannot outlive the
# image either way. The opencode AGENTS.md block is the one gap: agents/opencode/
# sync-settings.sh refreshes that config only when the host has a
# ~/.config/opencode, and agents/opencode/setup.sh writes AGENTS.md only when
# none is present, so without that host directory an earlier image's block stays.
# It is left as accepted residue and documented in THREAT_MODEL.md — inert prose
# naming tools nothing registers, where this file holds an executable hook.
#
# The path is under ${HOME}, not ${CLAUDE_CONFIG_DIR}: codegraph 1.5.0 writes
# settings.json to os.homedir()/.claude and ignores CLAUDE_CONFIG_DIR (checked
# by running the installer with the two pointed at separate trees — the
# CLAUDE_CONFIG_DIR tree stayed empty). entrypoint.sh sets CLAUDE_CONFIG_DIR to
# ${HOME}/.claude, so in a real session these are one file, but ${HOME} is the
# only one the installer can reach and therefore the only one that can hold a
# stale hook.
#
# Silent when there is nothing to remove: now that no image wires CodeGraph, the
# overwhelmingly common case is a session that never had it, and that session
# must not be told about a cleanup that did not happen.
codegraph_strip_session_wiring() {
	local settings_file="${HOME}/.claude/settings.json"
	[[ -f "${settings_file}" ]] || return 0

	local current
	if ! current="$(jq -c '.' "${settings_file}" 2>/dev/null)" || [[ -z "${current}" ]]; then
		echo "  [codegraph] WARN: ${settings_file} is not valid JSON — stale wiring not removed." >&2
		return 0
	fi

	# Remove exactly two things: the "mcp__codegraph__*" permission and the
	# installer's own UserPromptSubmit command.
	#
	# This edits a file the user owns and hand-edits, so the filter is written
	# to under-remove rather than over-remove. Leaving a stale hook in place
	# costs the warning above; deleting a hook the user wrote costs config they
	# cannot get back. Two rules follow from that, and every gate below is one
	# of them:
	#
	#   * Only a container this filter itself emptied is deleted. An "allow"
	#     list or a UserPromptSubmit array that was already empty is left as
	#     found — pruning it would rewrite the file and announce a CodeGraph
	#     cleanup on a session that never had CodeGraph.
	#   * Only the exact shapes the installer writes are matched, and only
	#     where the type is the one it writes. jq's map() accepts an object
	#     and returns an array, so a length-only gate would quietly convert a
	#     shape it did not understand; and `contains` raises on a non-string,
	#     which would fail the whole run and strand the hook this exists to
	#     remove.
	#
	# An untouched document is what tells the caller to stay silent.
	local stripped
	if ! stripped="$(jq -c '
		# Rewrite .[k] with f, dropping the key only if f emptied content that
		# was there to begin with. A key that is absent, of another type, or
		# already empty is left exactly as found.
		def prune(k; t; f):
			if (.[k] | type) == t and (.[k] | length) > 0 then
				.[k] |= f | if (.[k] | length) == 0 then del(.[k]) else . end
			else . end;

		# The installer writes the command as exactly "codegraph prompt-hook".
		# Allow a directory in front of the binary, and nothing else: a
		# user-authored codegraph-notify.sh, or a wrapper that calls the real
		# hook, is not ours to delete.
		def is_installer_hook:
			(.command? // null) as $c
			| ($c | type) == "string"
			and ($c == "codegraph prompt-hook"
				or ($c | endswith("/codegraph prompt-hook")));

		# One UserPromptSubmit entry: drop the installer command from its inner
		# hooks array, and drop the entry itself only if that emptied it.
		def strip_entry:
			if (.hooks | type) == "array" and (.hooks | length) > 0 then
				.hooks |= map(select(is_installer_hook | not))
				| select((.hooks | length) > 0)
			else . end;

		prune("permissions"; "object";
			prune("allow"; "array"; map(select(. != "mcp__codegraph__*"))))
		| prune("hooks"; "object";
			prune("UserPromptSubmit"; "array"; map(strip_entry)))
		' <<<"${current}" 2>/dev/null)"; then
		echo "  [codegraph] WARN: could not clean ${settings_file} — stale wiring left in place." >&2
		return 0
	fi

	[[ "${stripped}" != "${current}" ]] || return 0

	# Compact for the comparison above, pretty-printed for the write: this file
	# is hand-edited, and container/plugin-setup.sh pretty-prints it everywhere
	# it touches it. Reflowing a whole document onto one line to delete two
	# entries would be a far larger change than the one being made.
	#
	# Checked for emptiness, not just for jq's exit status: an unchecked
	# command substitution yields "" when jq fails or prints nothing, and the
	# writer would happily put a lone newline where the user's config was.
	local pretty
	if ! pretty="$(jq . <<<"${stripped}")" || [[ -z "${pretty}" ]] ||
		! json_write_atomic "${settings_file}" "${pretty}"; then
		echo "  [codegraph] WARN: could not write ${settings_file} — stale wiring left in place." >&2
		return 0
	fi

	# Name what was actually there. The installer writes both, but a session
	# can carry one without the other, and reporting a prompt hook that the
	# file never held is the same kind of false claim as reporting a cleanup
	# that never happened.
	local what
	what="$(jq -rn --argjson before "${current}" --argjson after "${stripped}" '
		[ if ($before.hooks.UserPromptSubmit // []) != ($after.hooks.UserPromptSubmit // [])
			then "prompt hook" else empty end,
		  if ($before.permissions.allow // []) != ($after.permissions.allow // [])
			then "permission entry" else empty end ]
		| join(" and ")')"

	# Both lines carry the prefix rather than indenting under the caller's
	# "WARN:" gutter: this function is also called directly, and a bare
	# continuation line renders as an orphan there.
	echo "  [codegraph] Removed the stale CodeGraph ${what} that an earlier image left" >&2
	echo "  [codegraph] in ${settings_file}." >&2
}

# Print the project roots in this workspace, one per line.
#
# The launcher writes one host project path per line into the session directory
# (setup_projects in scripts/mount-projects.sh, which builds the mount flags),
# and that directory is bind-mounted at ${CLAUDE_CONFIG_DIR}. The file is the
# authoritative project count: a single project is mounted at the workspace root
# whether or not it is a git repo, so inferring the shape from .git alone reads
# a non-repo single mount as a multi-project workspace and advises one index per
# top-level subdirectory.
# Those indexes are not filtered from overlay review (the derived-cache
# predicate is anchored to the first path component), so following that advice
# locks the next overlay launch.
codegraph_project_roots() {
	[[ -d "${CODEGRAPH_WORKSPACE}" ]] || return 0

	local projects_file="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.projects"
	local count=0
	if [[ -f "${projects_file}" ]]; then
		# Non-blank lines, counted in-shell rather than with `wc -l`, which
		# counts newlines: a file holding nothing but a blank line reads as
		# one project and would shape an empty set as a single mount.
		# `|| [[ -n ... ]]` so a final line with no trailing newline still
		# counts — dropping it would read a one-path file as no metadata and
		# fall back to the .git test this function exists to replace.
		local line
		while IFS= read -r line || [[ -n "${line}" ]]; do
			if [[ -n "${line//[[:space:]]/}" ]]; then
				count=$((count + 1))
			fi
		done <"${projects_file}"
	fi

	if [[ "${count}" -eq 1 ]]; then
		printf '%s\n' "${CODEGRAPH_WORKSPACE}"
		return 0
	fi

	# No launcher metadata (a direct `podman run`, or a unit test): fall back to
	# the repository test. -e, not -d: a worktree or submodule checkout records
	# its git directory in a .git *file*.
	if [[ "${count}" -eq 0 ]] && [[ -e "${CODEGRAPH_WORKSPACE}/.git" ]]; then
		printf '%s\n' "${CODEGRAPH_WORKSPACE}"
		return 0
	fi

	local dir
	for dir in "${CODEGRAPH_WORKSPACE}"/*/; do
		[[ -d "${dir}" ]] || continue
		printf '%s\n' "${dir%/}"
	done
}

# Print one hint line per project that has no index. Silent when every project
# is indexed — an existing index needs no user action.
codegraph_index_hint() {
	local root name
	# shellcheck disable=SC2312  # no roots means no output; the loop just won't run
	while IFS= read -r root; do
		[[ -f "${root}/.codegraph/codegraph.db" ]] && continue
		name="$(basename "${root}")"
		echo "  [codegraph] ${name}: no index — run 'codegraph init', then query it with 'codegraph explore'."
	done < <(codegraph_project_roots)
}

# Clean up after CodeGraph's installer, then point at the CLI.
#
# Both strips run unconditionally, and neither is gated on the binary. A session
# directory outlives the image, and what they remove was written by an installer
# this image never runs — so whether codegraph is on PATH right now says nothing
# about whether stale wiring is present. Only the hint needs the binary, because
# only the hint names a command for the user to run.
codegraph_setup() {
	codegraph_strip_session_wiring
	codegraph_strip_mcp_entry

	command -v codegraph >/dev/null 2>&1 || return 0
	codegraph_index_hint
}
