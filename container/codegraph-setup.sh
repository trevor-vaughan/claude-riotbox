#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# codegraph-setup.sh — CodeGraph wiring for a RiotBox session.
#
# Sourced by entrypoint.sh. Provides:
#   codegraph_setup — wire the MCP server into every detected agent, move the
#                     Claude MCP entry to the file Claude Code actually reads,
#                     and hint at unindexed projects. When the binary is gone,
#                     strip the wiring an earlier image left in this session.
#
# Why this runs per session rather than at build time: ~/.claude and
# ~/.config/opencode are replaced by session bind mounts (see
# scripts/mount-projects.sh), so agent config written into the image is
# invisible at runtime — the same reason plugin-setup.sh copies from a staging
# directory. `codegraph install` is idempotent, so re-running it every session
# is correct, not wasteful.
#
# Indexing is never started automatically. `codegraph init` writes a
# multi-megabyte index into the user's project tree and takes real time on a
# large repo; that stays an explicit, once-per-project choice. Once an index
# exists it stays current on its own — CodeGraph's MCP server runs a catch-up
# sync at startup and watches the tree for the rest of the session.
# ─────────────────────────────────────────────────────────────────────────────

# Workspace root. Overridable so the behavior can be tested without /workspace.
CODEGRAPH_WORKSPACE="${CODEGRAPH_WORKSPACE:-/workspace}"

# Replace a JSON config file with new content, atomically and without
# loosening its mode. Prints nothing; returns non-zero so the caller can name
# what was lost.
#
# Both callers rewrite an agent config file that the user owns, living in a
# bind-mounted host session directory, so both need the same three properties
# and must not grow separate versions of them:
#
#   * A partial write must never replace a good config, hence the staging file
#     and the rename.
#   * The staging file is uniquely named and created inside the target
#     directory: same filesystem keeps the rename atomic, and a unique name
#     keeps two sessions sharing this bind-mounted config directory
#     (mount-projects.sh supports two concurrent sessions per project) from
#     renaming each other's half-written file over the user's config.
#   * A rename adopts the source inode's mode, so the staging file must carry
#     the mode the target should end up with. Whatever mode the file has is
#     preserved and a new one is created 0600 rather than at the process
#     umask: these paths resolve into the host session directory, so a mode
#     this code picks persists on the host, and a config the user chose to
#     restrict must never come back looser than they left it.
codegraph_write_json_atomic() {
	local target_file="${1:?codegraph_write_json_atomic requires a target file}"
	local content="${2?codegraph_write_json_atomic requires content}"

	local tmp_file
	if ! mkdir -p "$(dirname "${target_file}")" ||
		! tmp_file="$(mktemp "${target_file}.XXXXXX")"; then
		return 1
	fi

	local mode
	if ! mode="$(stat -c '%a' "${target_file}" 2>/dev/null)" || [[ -z "${mode}" ]]; then
		mode=600
	fi

	if ! printf '%s\n' "${content}" >"${tmp_file}" ||
		! chmod "${mode}" "${tmp_file}" ||
		! mv "${tmp_file}" "${target_file}"; then
		rm -f "${tmp_file}"
		return 1
	fi
}

# Move CodeGraph's Claude MCP entry into the config file Claude Code reads.
#
# CodeGraph writes the global entry to ${HOME}/.claude.json (hardcoded to the
# home directory in its Claude installer target) and does not honor
# CLAUDE_CONFIG_DIR, which RiotBox points at ${HOME}/.claude — the
# bind-mounted session directory. Without this step the MCP server is
# configured in a file nothing loads.
#
# Merges rather than replaces: the target holds account metadata and any other
# MCP servers. A missing or entry-free source is a no-op; malformed JSON on
# either side warns and changes nothing.
codegraph_relocate_mcp_entry() {
	local source_file="${HOME}/.claude.json"
	local target_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	local target_file="${target_dir}/.claude.json"

	[[ -f "${source_file}" ]] || return 0

	local entry
	if ! entry="$(jq -c '.mcpServers.codegraph // empty' "${source_file}" 2>/dev/null)"; then
		echo "  [codegraph] WARN: ${source_file} is not valid JSON — MCP entry not relocated." >&2
		return 0
	fi
	[[ -n "${entry}" ]] || return 0

	local existing='{}'
	if [[ -f "${target_file}" ]]; then
		if ! existing="$(jq -c '.' "${target_file}" 2>/dev/null)" || [[ -z "${existing}" ]]; then
			echo "  [codegraph] WARN: ${target_file} is not valid JSON — MCP entry not relocated." >&2
			return 0
		fi
	fi

	local merged
	if ! merged="$(jq -c --argjson entry "${entry}" \
		'.mcpServers = ((.mcpServers // {}) | .codegraph = $entry)' \
		<<<"${existing}" 2>/dev/null)"; then
		echo "  [codegraph] WARN: could not merge the MCP entry into ${target_file}." >&2
		return 0
	fi

	# Every failure here warns: a session that silently lost its MCP wiring
	# looks identical to one that never had any, which is the hardest kind of
	# problem to notice.
	if ! codegraph_write_json_atomic "${target_file}" "${merged}"; then
		echo "  [codegraph] WARN: could not write ${target_file} — MCP entry not relocated." >&2
		return 0
	fi
}

# Remove the wiring `codegraph install` left in the session settings.json.
#
# Called only when the binary has gone missing. A session directory outlives
# the image, and a host settings.json is deliberately never synced into it
# (plugin-setup.sh), so nothing regenerates this file — a session wired by an
# earlier image would keep a UserPromptSubmit hook invoking `codegraph
# prompt-hook` on every prompt. That makes it the only artifact the installer
# writes that can put a missing command on the critical path: the CLAUDE.md
# block and the .claude.json entry are re-copied from the host each launch by
# agents/claude/sync-settings.sh, and neither is executable.
#
# The path is under ${HOME}, not ${CLAUDE_CONFIG_DIR}: codegraph 1.5.0 writes
# settings.json to os.homedir()/.claude and ignores CLAUDE_CONFIG_DIR (checked
# by running the installer with the two pointed at separate trees — the
# CLAUDE_CONFIG_DIR tree stayed empty). entrypoint.sh sets CLAUDE_CONFIG_DIR to
# ${HOME}/.claude, so in a real session these are one file, but ${HOME} is the
# only one the installer can reach and therefore the only one that can hold a
# stale hook.
#
# Silent when there is nothing to remove: the common case on an image without
# CodeGraph is a session that never had it, and that session must not be told
# about a cleanup that did not happen.
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
	if ! codegraph_write_json_atomic "${settings_file}" "$(jq . <<<"${stripped}")"; then
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
		echo "  [codegraph] ${name}: no index — run 'codegraph init' to enable graph-backed exploration."
	done < <(codegraph_project_roots)
}

codegraph_setup() {
	if ! command -v codegraph >/dev/null 2>&1; then
		# A session directory outlives the image, so wiring from an earlier
		# session may still be here, pointing at a command that is gone.
		# Telling the user to run `codegraph uninstall` would be telling them
		# to run a binary this image no longer ships, so clean it up instead.
		echo "  [codegraph] WARN: codegraph is not on PATH — MCP wiring skipped." >&2
		codegraph_strip_session_wiring
		return 0
	fi

	# -t auto configures every agent CodeGraph detects; -l global writes to the
	# session-mounted config dirs; -y keeps it non-interactive. A failure here
	# costs graph-backed exploration, never the session.
	#
	# Only stdout is discarded. The installer's stderr is the only thing that
	# distinguishes an unwritable bind mount from a malformed settings.json
	# from a broken bundle, and the warning below carries no cause of its own.
	if ! codegraph install -t auto -l global -y >/dev/null; then
		echo "  [codegraph] WARN: 'codegraph install' failed — MCP server not wired this session." >&2
		return 0
	fi

	codegraph_relocate_mcp_entry
	codegraph_index_hint
}
