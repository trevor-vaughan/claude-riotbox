#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/context-mode.sh — Context Mode support for Claude Code.
#
# Sourced by agents/claude/manifest.sh, which exposes the optional Context Mode
# verbs. RiotBox no longer authors Claude Code's wiring: upstream's marketplace
# plugin supplies the hooks and the MCP server, staged in the image and
# registered against the session by container/plugin-setup.sh. What is left
# here is the storage pin, the platform pin, the build-time contract check, and
# a stripper for the wiring the previous release wrote by hand.
#
# The constant below is asserted against upstream's routing table at image
# build time, so an upstream rename fails the build rather than a user session.
#
# See docs/dev/decisions/context-mode-native-plugin.md for the plugin adoption
# this file was cut down by, and docs/dev/decisions/context-mode-opencode.md for
# the per-agent split that created it.
# ─────────────────────────────────────────────────────────────────────────────

# The name the MCP server carries, and it is not cosmetic.
#
# Claude Code exposes an MCP server's tools as `mcp__<server>__<tool>` — the
# same convention that makes CodeGraph's tools `mcp__codegraph__*`. Context
# Mode's routing hardcodes the tool names it tells the agent to call, and for
# the claude-code platform that table reads
# `mcp__plugin_context-mode_context-mode__<tool>`
# (hooks/core/tool-naming.mjs upstream) — the shape Claude Code produces for a
# server that arrives via Context Mode's own *plugin*, which namespaces it as
# `plugin_<plugin>_<server>`. There is no env var or flag to steer it.
#
# The registered plugin now provides that server, so the name comes out right
# by construction and nothing here writes it. Two things still read the
# constant. agent_claude_context_mode_build_assert greps a copy of upstream's
# routing table for it, so a pin bump that changed the prefix fails the build
# instead of leaving every redirect pointing at a tool the session does not
# have; and the strip verb below uses it to find the entry the previous release
# registered under the same name in .claude.json, which has to go or the
# session carries two writers for one server.
CONTEXT_MODE_MCP_NAME='plugin_context-mode_context-mode'

# Remove hand-authored Context Mode wiring from the session config, whoever
# wrote it.
#
# This is the migration path, and it is why the verb outlived the wiring it
# used to undo. Releases up to and including the one before this wrote six hook
# stanzas dispatching `<shim> hook claude-code <event>` into settings.json and
# an mcpServers entry into .claude.json. Both files live in the session
# directory, which outlives the image, and settings.json is deliberately never
# synced from the host (plugin-setup.sh), so nothing regenerates them: a
# directory wired by that release and reopened under this one would run the
# registered plugin's hooks and the old stanzas at once — every event
# dispatched twice, against one server name two writers claim. Stripping is
# what converges a reused session on exactly one form of wiring.
#
# The same rule as codegraph_strip_session_wiring applies — under-remove rather
# than over-remove. Only entries whose command names the shim are touched, so a
# user-written hook that merely mentions context-mode survives.
#
# Every key actually present in .hooks is pruned, rather than a fixed list of
# the six this project once wrote. A list would strand a stanza forever the day
# an event left it: a session already wired with that key would carry a hook
# nothing recognises as one to look for, for the life of a session directory —
# the exact failure this function exists to prevent. is_ours needs no list
# either, because it matches on the shim's own path in the command, which
# correctly decides ownership for any key, including one left by an image whose
# event set was larger than this project ever wrote.
#
# Silent when there is nothing to remove: the common case is a session that
# never had Context Mode, and it must not be told about a cleanup that did not
# happen.
agent_claude_context_mode_strip() {
	local config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	local settings_file="${config_dir}/settings.json"
	local claude_json="${config_dir}/.claude.json"
	local removed=""
	# Named once here rather than read inside the jq call below, where the
	# directive would sit in front of an `elif` and shellcheck rejects it there.
	# shellcheck disable=SC2154  # CONTEXT_MODE_BIN is set by container/context-mode-setup.sh, which drives this file
	local bin="${CONTEXT_MODE_BIN}"

	if [[ -f "${settings_file}" ]]; then
		local current stripped pretty
		if ! current="$(jq -c '.' "${settings_file}" 2>/dev/null)" || [[ -z "${current}" ]]; then
			echo "  [context-mode] WARN: ${settings_file} is not valid JSON — stale hooks left in place." >&2
		elif ! stripped="$(jq -c --arg bin "${bin}" '
			# Type-gated because `contains` raises on a non-string instead of
			# answering false, and one raise fails the whole program and
			# strands the hooks this function exists to remove. settings.json
			# is hand-editable, so an argv array — `["/bin/sh", …]` — is a
			# shape a person plausibly writes there. A command this filter
			# cannot read is not ours.
			def is_ours: [.hooks[]? | (.command? // null) as $c
				| select(($c | type) == "string" and ($c | contains($bin)))] | length > 0;
			# Drop our entries from one hook array, and drop the array itself
			# only if that emptied one that had content to begin with. A key
			# that is absent, of another type, or already empty is left exactly
			# as found — pruning it would rewrite the file and announce a
			# cleanup on a session that never had Context Mode.
			def prune(key):
				if (.hooks[key] | type) == "array" and (.hooks[key] | length) > 0 then
					.hooks[key] |= map(select(is_ours | not))
					| if (.hooks[key] | length) == 0 then del(.hooks[key]) else . end
				else . end;

			# Every key .hooks actually has, not a fixed list of the events
			# this project once wrote — see the function comment above for why
			# a list cannot drive this walk.
			if (.hooks | type) == "object" then
				reduce (.hooks | keys_unsorted[]) as $k (.; prune($k))
				| if (.hooks | length) == 0 then del(.hooks) else . end
			else . end
			' <<<"${current}" 2>/dev/null)"; then
			echo "  [context-mode] WARN: could not clean ${settings_file} — stale hooks left in place." >&2
		elif [[ "${stripped}" != "${current}" ]]; then
			# Empty-checked as well as status-checked: an unchecked command
			# substitution yields "" when jq fails or prints nothing, and the
			# writer would put a lone newline where the user's config was.
			if pretty="$(jq . <<<"${stripped}")" && [[ -n "${pretty}" ]] &&
				json_write_atomic "${settings_file}" "${pretty}"; then
				removed="hooks"
			else
				echo "  [context-mode] WARN: could not write ${settings_file} — stale hooks left in place." >&2
			fi
		fi
	fi

	if [[ -f "${claude_json}" ]]; then
		local mcp_current mcp_stripped mcp_pretty
		if ! mcp_current="$(jq -c '.' "${claude_json}" 2>/dev/null)" || [[ -z "${mcp_current}" ]]; then
			echo "  [context-mode] WARN: ${claude_json} is not valid JSON — stale MCP entry left in place." >&2
		elif ! mcp_stripped="$(jq -c --arg name "${CONTEXT_MODE_MCP_NAME}" '
			if (.mcpServers | type) == "object" and (.mcpServers | has($name))
			then del(.mcpServers[$name]) else . end
			' <<<"${mcp_current}" 2>/dev/null)"; then
			echo "  [context-mode] WARN: could not clean ${claude_json} — stale MCP entry left in place." >&2
		elif [[ "${mcp_stripped}" != "${mcp_current}" ]]; then
			if mcp_pretty="$(jq . <<<"${mcp_stripped}")" && [[ -n "${mcp_pretty}" ]] &&
				json_write_atomic "${claude_json}" "${mcp_pretty}"; then
				removed="${removed:+${removed} and }MCP server entry"
			else
				echo "  [context-mode] WARN: could not write ${claude_json} — stale MCP entry left in place." >&2
			fi
		fi
	fi

	# Name what was actually removed. A session can carry one without the
	# other, and reporting a cleanup of something the file never held is the
	# same kind of false claim as reporting one that never happened.
	[[ -n "${removed}" ]] || return 0

	# Both lines carry the prefix rather than indenting under a "WARN:" gutter:
	# this function is also called on its own, where a bare continuation line
	# renders as an orphan.
	#
	# The wording says where the wiring was, not who left it. An agent that
	# still authors its own wiring calls its stripper on a failure path to
	# remove wiring seconds old, and "an earlier session left" would be false
	# there.
	echo "  [context-mode] Removed the Context Mode ${removed} left in" >&2
	echo "  [context-mode] ${config_dir}." >&2
}

agent_claude_context_mode_store_dir() {
	printf '%s\n' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode"
}

# The platform token upstream keys its hook dispatch and adapter detection off.
#
# Pinned rather than detected. Every RiotBox image ships Claude Code and
# opencode, and upstream's detectPlatform() resolves that ambiguity from
# whichever config it finds — the same co-install case its own Copilot bundle
# pins this variable for. When it guesses an in-process plugin platform,
# getPluginRoot() returns ~/.cache/<platform>/packages/context-mode@latest/...,
# a path no RiotBox install populates, and the hook's import throws into a
# stderr hookDispatch has already pointed at /dev/null: a session that routes
# nothing and reports itself healthy.
agent_claude_context_mode_platform() {
	printf 'claude-code\n'
}

# Build-time contract check for the Claude path.
#
# What is left to assert once RiotBox stops authoring hooks: the MCP server
# name the routing table steers toward still appears where the hooks look it
# up. The matcher and hook-table equality checks that used to live here went
# with the tables they compared — upstream's hooks.json is now the only
# definition of both, so there is nothing on our side to drift from it.
#
# A failed grep is a failed assert, which is the property the comparisons it
# replaced did not have: they compared two command substitutions, so a run in
# which both sides failed compared "" against "" and passed.
#
# $1 is the root of a tree carrying upstream's hooks/ — the npm package root or
# the staged plugin clone. The verb takes it as an argument rather than deriving
# one because it is called on more than one of them; the staging layer in the
# Containerfile is where that is spelled out. The diagnostic names the root it
# read, since nothing obliges a caller to say which tree it handed over.
agent_claude_context_mode_build_assert() {
	local root="${1:?upstream tree root required}"

	if ! grep -qF "\`mcp__${CONTEXT_MODE_MCP_NAME}__" "${root}/hooks/core/tool-naming.mjs"; then
		echo "CONTEXT_MODE_MCP_NAME no longer appears in hooks/core/tool-naming.mjs — sessions would register an MCP server the routing table cannot steer (${root})" >&2
		return 1
	fi
}
