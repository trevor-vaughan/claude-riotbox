#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/context-mode.sh — Context Mode wiring for Claude Code.
#
# Sourced by agents/claude/manifest.sh, which exposes the optional Context Mode
# verbs. Moved here verbatim from container/context-mode-setup.sh when opencode
# gained its own wiring: everything below is Claude Code's contract with
# upstream — the `hook claude-code <event>` commands, the PreToolUse/PostToolUse
# matchers, and the mcpServers entry — and none of it has an opencode analogue.
#
# The constants below are asserted against the installed bundle at image build
# time, so an upstream rename fails the build rather than a user session.
#
# See docs/dev/decisions/context-mode-opencode.md.
# ─────────────────────────────────────────────────────────────────────────────

# The tool set Context Mode's PreToolUse hook intercepts, pipe-joined exactly
# as its own installer emits it. Upstream's source of truth is
# PRE_TOOL_USE_MATCHERS in src/adapters/claude-code/hooks.ts. The trailing bare
# "mcp__" is deliberate and matches every external MCP tool: the hook body
# filters Context Mode's own tools back out, because a negative lookahead had
# to be removed upstream when Codex's Rust regex engine rejected it.
# agent_claude_context_mode_build_assert below compares this variable for
# equality against the PreToolUse matchers in the installed package's own
# hooks/hooks.json, so a pin bump that changes the tool set in either direction
# — a tool dropped or a tool added — or an edit that renames or empties this
# variable, fails the image build rather than a user session.
CONTEXT_MODE_MATCHER='Bash|WebFetch|Read|Grep|Agent|mcp__plugin_context-mode_context-mode__ctx_execute|mcp__plugin_context-mode_context-mode__ctx_execute_file|mcp__plugin_context-mode_context-mode__ctx_batch_execute|mcp__'

# The tool set Context Mode's PostToolUse hook captures, pipe-joined exactly as
# its own installer emits it. Upstream builds it at runtime from the array `MI`
# in cli.bundle.mjs (`.join("|")`), so the joined string appears nowhere in the
# bundle; the build guard compares it against hooks/hooks.json instead, where
# upstream's installer has already joined it — the same shape the PreToolUse
# guard uses.
#
# PostToolUse is where continuity is written: these are the per-tool events
# SessionStart replays into a fresh session and PreCompact folds into the resume
# snapshot. A silently narrowed set here does not fail anything — it just means
# less survives a compact or a restart — so the build asserts it instead.
CONTEXT_MODE_POST_MATCHER='Bash|Read|Write|Edit|NotebookEdit|Glob|Grep|TodoWrite|TaskCreate|TaskUpdate|EnterPlanMode|ExitPlanMode|Skill|Agent|AskUserQuestion|EnterWorktree|mcp__'

# The name the MCP server is registered under, and it is not cosmetic.
#
# Claude Code exposes an MCP server's tools as `mcp__<server>__<tool>` — the
# same convention that makes CodeGraph's tools `mcp__codegraph__*`. Context
# Mode's routing hardcodes the tool names it tells the agent to call, and for
# the claude-code platform that table reads
# `mcp__plugin_context-mode_context-mode__<tool>`
# (hooks/core/tool-naming.mjs upstream) — the shape Claude Code produces when
# the server arrives via Context Mode's own *plugin*, which namespaces it as
# `plugin_<plugin>_<server>`. There is no env var or flag to steer it.
#
# RiotBox cannot install the plugin: that path fetches it from GitHub at
# session start, which is exactly the network dependency this integration
# exists to avoid. So the server is registered under the name that makes the
# hardcoded names resolve. Register it as plain "context-mode" instead and
# every redirect still fires, but it points the agent at
# `mcp__plugin_context-mode_context-mode__ctx_fetch_and_index`, which does not
# exist in the session — a denial with no reachable alternative, which is worse
# than leaving the feature off.
#
# The same string appears in CONTEXT_MODE_MATCHER above, for the same reason:
# those three entries are how the hook recognises Context Mode's own tools.
CONTEXT_MODE_MCP_NAME='plugin_context-mode_context-mode'

# The hook events RiotBox wires: Claude Code's settings.json key → the matcher it
# fires on and the `context-mode hook claude-code <event>` subcommand it
# dispatches. Emitted as JSON, in write order.
#
# Three callers read this one table — agent_claude_context_mode_wire,
# agent_claude_context_mode_strip, and the Containerfile's drift guards — and
# that is the point. An event wired but not stripped leaves a hook pointing at a
# binary that is gone for the life of a session directory, which is the exact
# failure the stripper exists to prevent; an event wired but unguarded is a hook
# whose upstream disappearance surfaces in a user session instead of a build.
context_mode_hook_table() {
	jq -nc \
		--arg pre "${CONTEXT_MODE_MATCHER}" \
		--arg post "${CONTEXT_MODE_POST_MATCHER}" '{
		PreToolUse:       {matcher: $pre,  event: "pretooluse"},
		PostToolUse:      {matcher: $post, event: "posttooluse"},
		UserPromptSubmit: {matcher: "",    event: "userpromptsubmit"},
		PreCompact:       {matcher: "",    event: "precompact"},
		SessionStart:     {matcher: "",    event: "sessionstart"},
		Stop:             {matcher: "",    event: "stop"}
	}'
}

# Write the MCP server entry and the six hook stanzas into the session config.
#
# Hooks are dispatched through `context-mode hook <platform> <event>` — the
# CLI's own hook entry point — rather than by naming a script inside the
# package the way the vendor installer does. Two reasons, and the first is not
# a preference:
#
#   * The installer's form is `<node> <pkg>/hooks/pretooluse.mjs`, i.e. a Node
#     interpreter executing a script. Substituting the riotbox shim for that
#     interpreter does NOT work: the shim runs the CLI bundle, and the CLI
#     treats an unrecognised first argument as "start the MCP server", so the
#     hook emits nothing and every routing decision is silently lost. Verified
#     against a live MCP server — the script-path form returned no decision
#     where the dispatcher form correctly denied a WebFetch.
#   * Upstream's own form pins process.execPath, falling back to a bare `node`
#     from PATH once that path stops existing. A bare `node` in a RiotBox
#     session is the host-mirrored default, which may be Node 20 — the exact
#     version Context Mode refuses to run on. Dispatching through the shim
#     keeps the pinned interpreter in the loop with no fallback to reach.
#
# It also means this script never needs to know where inside the package the
# hook scripts live, so the pinned Node version stays in the Containerfile
# alone.
#
# All six stanzas and the MCP entry are written in one call because a session
# carrying some of them is worse than a session carrying none: PreToolUse alone
# denies WebFetch and redirects the agent to MCP tools that are not registered,
# and SessionStart alone promises the model a memory that the four writers —
# PostToolUse, UserPromptSubmit, PreCompact, Stop — are the only things that
# fill.
#
# Two rules hold that invariant, and both are needed:
#
#   * Everything is parsed, built and formatted before anything is written, so
#     a failure that can be seen at all is seen while the session is still
#     untouched.
#   * Every path that gives up calls agent_claude_context_mode_strip on the
#     way out. That covers the state this call inherits rather than creates: a
#     session directory outlives the run that wired it, so .claude.json can come
#     back truncated (a crash mid-write) or hand-broken with the earlier run's
#     hooks still on disk. Returning quietly there would leave exactly the
#     half-wired state the paragraph above rules out, for the life of the
#     session directory — nothing regenerates these files, and the warning goes
#     to a stderr an autonomous run never reads. Stripping converges the session
#     to "neither", and says nothing on one that never had wiring.
#
# A path that gives up also returns non-zero, and that is the whole of this
# verb's contract with the registry: return 0 only when every artifact landed
# (docs/dev/decisions/context-mode-opencode.md, "Registry contract").
# container/context-mode-setup.sh reads that status to decide whether the
# session may claim the feature ran, so a give-up that returned 0 would hand a
# session running with Context Mode off a teardown report saying it was wired —
# a false claim in the one place the user actually looks.
#
# The write order — hooks first, then the MCP entry, with the strip below
# compensating when the second write fails — is deliberate, not an accident of
# reading order. Registering the server first would make that failure harmless
# by construction, but a registered server with no hooks is not inert here:
# Claude Code spawns it at session start, which is what makes the unsuppressable
# version-check GET to registry.npmjs.org. Converging to neither is the better
# end state, so the order stays as it is.
agent_claude_context_mode_wire() {
	local config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	local settings_file="${config_dir}/settings.json"
	local claude_json="${config_dir}/.claude.json"

	local current='{}'
	if [[ -f "${settings_file}" ]]; then
		if ! current="$(jq -c '.' "${settings_file}" 2>/dev/null)" || [[ -z "${current}" ]]; then
			echo "  [context-mode] WARN: ${settings_file} is not valid JSON — Context Mode not wired; removing any earlier wiring." >&2
			agent_claude_context_mode_strip
			return 1
		fi
	fi

	# Replace only our own entries. An entry is ours when its command names the
	# shim; everything else in these arrays belongs to the user or to another
	# tool and is carried through untouched. Rebuilding the array rather than
	# appending to it is what makes a second call a no-op.
	#
	# A `hooks` key that is present but not an object is an error rather than
	# something to overwrite: this file is hand-edited, and replacing a shape
	# jq did not understand would destroy configuration the user cannot get
	# back. The error surfaces as the warning below and nothing is written.
	#
	# The type gate inside is_ours is what keeps that refusal narrow. `contains`
	# raises on a non-string rather than answering false, and one raise fails
	# the whole program: a single hand-written `"command": ["/bin/sh", …]`
	# anywhere in these arrays would take the wiring down with it and, through
	# the strip below, the cleanup too. A command this filter cannot read is not
	# ours — the same rule codegraph_strip_session_wiring states.
	#
	# Built before anything is written, like every other input here: a table this
	# shell cannot produce is a failure to see while the session is untouched.
	local table
	if ! table="$(context_mode_hook_table)" || [[ -z "${table}" ]]; then
		echo "  [context-mode] WARN: could not build the hook table — Context Mode not wired; removing any earlier wiring." >&2
		agent_claude_context_mode_strip
		return 1
	fi

	local wired
	if ! wired="$(jq -c \
		--arg bin "${CONTEXT_MODE_BIN}" \
		--argjson events "${table}" '
		def is_ours: [.hooks[]? | (.command? // null) as $c
			| select(($c | type) == "string" and ($c | contains($bin)))] | length > 0;
		def replace(key; entry):
			.hooks[key] = ([(.hooks[key] // [])[] | select(is_ours | not)] + [entry]);

		if (.hooks != null) and ((.hooks | type) != "object") then
			error("settings.json .hooks is not an object")
		else . end
		| .hooks = (.hooks // {})
		| reduce ($events | to_entries[]) as $e (.;
			replace($e.key;
				{matcher: $e.value.matcher,
				 hooks: [{type: "command",
				          command: ("\"" + $bin + "\" hook claude-code " + $e.value.event)}]}))
		' <<<"${current}" 2>/dev/null)"; then
		echo "  [context-mode] WARN: could not build hook config for ${settings_file} — Context Mode not wired; removing any earlier wiring." >&2
		agent_claude_context_mode_strip
		return 1
	fi

	# `context-mode` with no arguments starts the stdio MCP server, so the shim
	# needs no subcommand. Merged into whatever else the file holds — account
	# metadata, and any other MCP server including CodeGraph's.
	local mcp_current='{}'
	if [[ -f "${claude_json}" ]]; then
		if ! mcp_current="$(jq -c '.' "${claude_json}" 2>/dev/null)" || [[ -z "${mcp_current}" ]]; then
			echo "  [context-mode] WARN: ${claude_json} is not valid JSON — Context Mode not wired; removing any earlier wiring." >&2
			agent_claude_context_mode_strip
			return 1
		fi
	fi

	local mcp_wired
	if ! mcp_wired="$(jq -c \
		--arg bin "${CONTEXT_MODE_BIN}" \
		--arg name "${CONTEXT_MODE_MCP_NAME}" '
		.mcpServers = ((.mcpServers // {})
			| .[$name] = {type: "stdio", command: $bin, args: []})
		' <<<"${mcp_current}" 2>/dev/null)"; then
		echo "  [context-mode] WARN: could not build the MCP entry for ${claude_json} — Context Mode not wired; removing any earlier wiring." >&2
		agent_claude_context_mode_strip
		return 1
	fi

	# Compact for the comparisons, pretty-printed for the writes: these files
	# are hand-edited, and plugin-setup.sh pretty-prints settings.json wherever
	# it touches it. Reflowing a whole document onto one line to add six stanzas
	# would be a far larger change than the one being made.
	#
	# A document that already matches is left empty here and never written —
	# that is what makes a second call in the same session a no-op, and a
	# formatted JSON document is never empty, so the two cannot be confused.
	# Emptiness is checked as well as jq's exit status because an unchecked
	# command substitution yields "" when jq fails or prints nothing, and the
	# writer would put a lone newline where the user's config was.
	local settings_pretty='' mcp_pretty=''
	if [[ "${wired}" != "${current}" ]]; then
		if ! settings_pretty="$(jq . <<<"${wired}")" || [[ -z "${settings_pretty}" ]]; then
			echo "  [context-mode] WARN: could not format ${settings_file} — Context Mode not wired; removing any earlier wiring." >&2
			agent_claude_context_mode_strip
			return 1
		fi
	fi
	if [[ "${mcp_wired}" != "${mcp_current}" ]]; then
		if ! mcp_pretty="$(jq . <<<"${mcp_wired}")" || [[ -z "${mcp_pretty}" ]]; then
			echo "  [context-mode] WARN: could not format ${claude_json} — Context Mode not wired; removing any earlier wiring." >&2
			agent_claude_context_mode_strip
			return 1
		fi
	fi

	# Both documents are valid from here on, so the hooks go first: a failure on
	# this write leaves nothing this call wrote behind, and the strip clears any
	# wiring an earlier run left rather than pairing it with a server this call
	# never got as far as registering.
	if [[ -n "${settings_pretty}" ]]; then
		if ! json_write_atomic "${settings_file}" "${settings_pretty}"; then
			echo "  [context-mode] WARN: could not write ${settings_file} — Context Mode not wired; removing any earlier wiring." >&2
			agent_claude_context_mode_strip
			return 1
		fi
	fi

	if [[ -n "${mcp_pretty}" ]]; then
		if ! json_write_atomic "${claude_json}" "${mcp_pretty}"; then
			# The one failure the ordering cannot rule out: an I/O error with the
			# hooks already on disk. Take them back out rather than leave the
			# session denying WebFetch and naming a server it has not got.
			# Stripping rather than restoring the captured original: these files
			# are hand-edited, and rewriting one from a compacted capture would
			# reflow far more than this function ever wrote.
			echo "  [context-mode] WARN: could not write ${claude_json} — MCP server not registered." >&2
			echo "  [context-mode] Removing the hooks just written: without the server they deny" >&2
			echo "  [context-mode] WebFetch and redirect to tools this session does not have." >&2
			agent_claude_context_mode_strip
			return 1
		fi
	fi

	# The one line this file puts on stdout, and the only signal a wired session
	# gives. Everything else here is a warning about a session that degraded to
	# Context Mode off, on a stderr an autonomous run never reads — so without
	# this an enabled session and a degraded one look identical. Reached only on
	# success: every path above that gives up returns before it. Same shape as
	# the `  [codegraph] ` hints the sibling setup prints. The store path is
	# what context_mode_setup exports as CONTEXT_MODE_DIR, derived from the same
	# config dir; tests/context-mode.venom.yml pins the two to each other.
	# Read by context_mode_summary_init/print (container/context-mode-summary.sh)
	# and by nothing else. context_mode_setup exports it too, on this verb
	# returning 0; setting it here as well keeps a direct call honest about the
	# same thing, which is the shape every case in tests/context-mode.venom.yml
	# uses. Either way it tracks the write actually landing: every give-up path
	# above returns non-zero before this line, so a degraded session never
	# prints a report claiming the feature ran.
	export _CONTEXT_MODE_WIRED=1
	echo "  [context-mode] hooks wired; store at ${config_dir}/context-mode."
}

# Remove Context Mode's wiring from the session config, whoever wrote it.
#
# Two callers, and the message below has to be true for both: context_mode_setup
# calls it for wiring an earlier session left, and every failure path in
# agent_claude_context_mode_wire calls it for wiring that may be seconds old.
#
# A session directory outlives the image, and settings.json is deliberately
# never synced from the host (plugin-setup.sh), so nothing regenerates it: a
# session wired by an image that shipped Context Mode would keep spawning hooks
# that no longer exist, on every matching tool call, for the life of the
# session directory. That is the same class of problem
# codegraph_strip_session_wiring solves, and the same rule applies — under-
# remove rather than over-remove. Only entries whose command names the shim are
# touched, so a user-written hook that merely mentions context-mode survives.
#
# Every key actually present in .hooks is pruned — NOT every key
# context_mode_hook_table names. The table is what the wire verb consults
# to decide what to WRITE; it has no bearing on what this function may REMOVE.
# Pruning by the table would strand a stanza forever the day a row is removed
# or renamed from it: a session already wired with the old key would carry a
# hook this function no longer recognises as one to look for, for the life of
# a session directory that outlives the image that wrote it — the exact
# failure this function exists to prevent, reached by the fix meant to prevent
# it. is_ours does not need the table either: it matches on the shim's own
# path in the command, which correctly decides ownership for any key,
# including an event RiotBox never wrote and any left by an image whose table
# was larger than this one's.
#
# Silent when there is nothing to remove: the common case is a session that
# never had Context Mode, and it must not be told about a cleanup that did not
# happen.
agent_claude_context_mode_strip() {
	local config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	local settings_file="${config_dir}/settings.json"
	local claude_json="${config_dir}/.claude.json"
	local removed=""

	if [[ -f "${settings_file}" ]]; then
		local current stripped pretty
		if ! current="$(jq -c '.' "${settings_file}" 2>/dev/null)" || [[ -z "${current}" ]]; then
			echo "  [context-mode] WARN: ${settings_file} is not valid JSON — stale hooks left in place." >&2
		elif ! stripped="$(jq -c --arg bin "${CONTEXT_MODE_BIN}" '
			# Type-gated for the reason the wire verb spells out: `contains`
			# raises on a non-string, and that raise would fail the whole
			# program and strand the hooks this function exists to remove.
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

			# Every key .hooks actually has, not every key context_mode_hook_table
			# names — see the function comment above for why the table cannot
			# drive this walk.
			if (.hooks | type) == "object" then
				reduce (.hooks | keys_unsorted[]) as $k (.; prune($k))
				| if (.hooks | length) == 0 then del(.hooks) else . end
			else . end
			' <<<"${current}" 2>/dev/null)"; then
			echo "  [context-mode] WARN: could not clean ${settings_file} — stale hooks left in place." >&2
		elif [[ "${stripped}" != "${current}" ]]; then
			# Empty-checked as well as status-checked, for the reason spelled
			# out in the wire verb: an unchecked substitution would put a
			# lone newline where the user's config was.
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
	# The wording says where the wiring was, not who left it:
	# agent_claude_context_mode_wire calls this on a failure to remove wiring
	# from this same run, and "an earlier session left" would contradict the
	# line it prints just above.
	echo "  [context-mode] Removed the Context Mode ${removed} left in" >&2
	echo "  [context-mode] ${config_dir}." >&2
}

agent_claude_context_mode_store_dir() {
	printf '%s\n' "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode"
}

# Build-time guard. Takes the installed package root and asserts the upstream
# contract this file's constants encode. Moved here from the Containerfile when
# the constants moved: a guard that lives apart from what it guards stops
# guarding it the first time either moves.
agent_claude_context_mode_build_assert() {
	local pkg="${1:?package root required}"
	local hooks="${pkg}/hooks/hooks.json"

	if ! grep -qF "\`mcp__${CONTEXT_MODE_MCP_NAME}__" "${pkg}/hooks/core/tool-naming.mjs"; then
		echo "CONTEXT_MODE_MCP_NAME no longer appears in hooks/core/tool-naming.mjs — sessions would register an MCP server the routing table cannot steer" >&2
		return 1
	fi

	if [[ "$(jq -Sc '.hooks|keys' "${hooks}")" != "$(context_mode_hook_table | jq -Sc keys)" ]]; then
		echo "hooks/hooks.json wires a different event set than context_mode_hook_table — a session would leave an upstream hook unwired, or wire an event that no longer exists" >&2
		return 1
	fi

	if [[ "$(jq -r '[.hooks.PreToolUse[].matcher]|join("|")' "${hooks}")" != "${CONTEXT_MODE_MATCHER}" ]]; then
		echo "the PreToolUse tool set in hooks/hooks.json no longer equals CONTEXT_MODE_MATCHER — sessions would intercept a different set of tools than upstream ships" >&2
		return 1
	fi

	if [[ "$(jq -r '.hooks.PostToolUse[0].matcher' "${hooks}")" != "${CONTEXT_MODE_POST_MATCHER}" ]]; then
		echo "the PostToolUse tool set in hooks/hooks.json no longer equals CONTEXT_MODE_POST_MATCHER — sessions would capture a different set of tools than upstream, and a narrower one means less survives a compact or a restart" >&2
		return 1
	fi
}
