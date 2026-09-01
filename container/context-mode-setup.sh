#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# context-mode-setup.sh — Context Mode wiring for a RiotBox session.
#
# Sourced by entrypoint.sh. Provides:
#   context_mode_setup — when RIOTBOX_CONTEXT_MODE=1, point the FTS5 store at
#                        the session directory and drive the running agent's
#                        Context Mode verbs to write whatever form of wiring
#                        that agent needs. Otherwise strip wiring an earlier
#                        session left behind. No agent name of its own: the set
#                        of agents comes from AGENT_REGISTRY and the wiring
#                        itself from agents/*/context-mode.sh.
#
# Also sourced by the image build: the Containerfile's Context Mode layer
# sources this file, generates the shim into CONTEXT_MODE_BIN so the path it
# writes is the path a session reads, and checks context_mode_pkg_root's
# derivation against the package it just installed. Both are build-time API,
# and sourcing this file has to stay free of top-level side effects — defining
# that constant and these functions and nothing else. The per-agent upstream
# contracts the build also asserts live in agents/*/context-mode.sh, declared
# beside the code that depends on them, and reach the build through
# agents/registry.sh. What each agent asserts is stated there and deliberately
# not copied here — a second list in this header would go stale the first time
# one of them moved, which is the failure the constants below already argue
# against. The one thing worth knowing at this distance: on the Claude side the
# MCP server name is now the whole of it. The matcher and hook-event
# comparisons that used to sit beside it went with the hand-authored wiring, so
# nothing asserts the intercepted tool set any more on either agent — see
# docs/dev/context-mode.md, "Which tools are actually intercepted".
#
# Nothing here writes JSON: that moved to agents/claude/context-mode.sh with the
# rest of the Claude wiring. It does READ two JSON documents it does not own —
# Claude Code's installed_plugins.json and settings.json, in
# context_mode_plugin_installed below — so the boundary is about writes, not
# about knowing nothing of the format. json_write_atomic
# (scripts/lib/json-write.sh) stays
# a dependency of the files that call it rather than a source line in any of
# them — entrypoint.sh sources the library ahead of all of them at run time,
# while the build sources them and calls nothing that writes, and the same
# writer is shared with codegraph-setup.sh, so no single caller can own it.
#
# Why nothing here runs the vendor installer: `context-mode upgrade` is the
# only command that configures hooks, and it git-clones
# https://github.com/mksglu/context-mode.git and — when upstream is newer —
# npm-installs, builds, and copies the result over the installed package tree.
# Running that at session start would swap pinned, reviewed code for whatever
# is on main, inside a container holding the user's project, and would break
# RIOTBOX_NETWORK=none. Claude Code instead gets upstream's marketplace plugin,
# cloned at a pinned ref at BUILD time and registered against the session by
# container/plugin-setup.sh; opencode gets a generated shim that re-exports the
# installed adapter. Neither path reaches the network at session start.
#
# Why per session rather than at build time: ~/.claude is replaced by a session
# bind mount (scripts/mount-projects.sh), so agent config written into the
# image is invisible at runtime — the same reason codegraph-setup.sh and
# plugin-setup.sh run here.
# ─────────────────────────────────────────────────────────────────────────────

# The shim the image build installs. It execs the pinned Node 22 against the
# CLI bundle; see the Context Mode block in the Containerfile for why a bare
# `node` is wrong. Overridable so the behavior can be tested without the image.
CONTEXT_MODE_BIN="${CONTEXT_MODE_BIN:-${HOME}/.local/bin/context-mode}"

# The vendored package root, derived from the shim the image build generates
# at CONTEXT_MODE_BIN. Deriving beats hardcoding: the path embeds
# ARG CONTEXT_MODE_NODE, and a second copy of that version in shell would rot
# silently the first time the ARG moves. The build asserts this derivation
# against the true CM_PKG (see the Context Mode block in the Containerfile),
# so a shim whose shape changes fails the build rather than a session.
#
# Prints the absolute package root on stdout; returns 1 and prints nothing when
# the shim is absent or does not carry a cli.bundle.mjs exec line.
context_mode_pkg_root() {
	local bundle
	[[ -r "${CONTEXT_MODE_BIN}" ]] || return 1
	# sed exits 0 when it matches nothing, so the `|| return 1` below fires only
	# on a genuine read error — the emptiness check after it is what rejects a
	# shim this pattern cannot parse.
	bundle="$(sed -n 's|^exec "[^"]*" "\(.*\)/cli\.bundle\.mjs".*|\1|p' "${CONTEXT_MODE_BIN}")" || return 1
	[[ -n "${bundle}" ]] || return 1
	printf '%s\n' "${bundle}"
}

# Answer whether this session actually has a Context Mode plugin Claude Code
# will load, on the same evidence Claude Code itself uses.
#
# The question is deliberately "does this session have Context Mode", not "did
# RiotBox stage it". container/plugin-setup.sh registers the image-staged tree,
# but that is not the only way the plugin arrives: with nothing staged, the host
# ~/.claude/plugins bind mount supplies its own copy, which plugin_setup copies
# in, context_mode_plugin_unregister deliberately spares — a host install is not
# what RIOTBOX_CONTEXT_MODE governs, and it is the only Context Mode some
# sessions have — and the enabledPlugins sync switches on. Keying on the staged
# registration alone would tell those sessions the feature is off while it runs.
#
# Two ways to be registered and still load nothing, both of which have to answer
# no here or this becomes a second source of the false claim it exists to
# prevent:
#
#   * An entry whose installPath is not on disk. That is the dangling
#     registration container/plugin-setup.sh refuses to create — a stamped path
#     an image rebuild took away — where Claude Code surfaces the plugin and
#     every hook in it then fails to load.
#   * An entry switched off in settings.json. Only an explicit `false` counts: a
#     missing file, a missing key or a document jq cannot read is not evidence
#     of anything, and reading it as one would deny a working session its report.
#
#     A normal session cannot currently reach that state: plugin_setup runs
#     first, and its step 1 deletes .enabledPlugins wholesale while step 7
#     rebuilds it all-true. The check is kept because it is correct whenever it
#     does fire, and becomes load-bearing the day those two steps stop. What
#     pins the override is "a session start re-enables a plugin the user
#     switched off" in tests/context-mode.venom.yml — the mechanism belongs in
#     the case that executes it. The clobber itself re-enables every plugin the
#     user disabled, not this one, and is raised as its own question.
#
# Reads only; both documents belong to Claude Code and to the user. Returns 0
# when the plugin is installed and enabled, 1 otherwise, and prints nothing
# either way — the caller owns what the session is told.
context_mode_plugin_installed() {
	# Spelled the way container/plugin-setup.sh spells these paths rather than
	# through CLAUDE_CONFIG_DIR: what this reads has to be the file that code
	# writes and Claude Code loads.
	local registry="${HOME}/.claude/plugins/installed_plugins.json"
	local settings="${HOME}/.claude/settings.json"
	local paths path

	[[ -f "${registry}" ]] || return 1

	if [[ -f "${settings}" ]] &&
		jq -e '.enabledPlugins["context-mode@context-mode"] == false' \
			"${settings}" >/dev/null 2>&1; then
		return 1
	fi

	# Type-gated the whole way down, the way the filters in
	# context_mode_plugin_unregister are: this file is hand-editable and jq
	# raises rather than answering false when a path indexes something that is
	# not an object. A shape this filter cannot read is not evidence either.
	paths="$(jq -r 'if type == "object"
			and (.plugins | type) == "object"
			and (.plugins["context-mode@context-mode"] | type) == "array"
		then .plugins["context-mode@context-mode"][]
			| select(type == "object")
			| .installPath
			| select(type == "string")
		else empty end
		' "${registry}" 2>/dev/null)" || return 1

	# Any one entry that names a tree on disk is enough: the v2 value is an
	# array, and Claude Code loading either of them is Context Mode running.
	while IFS= read -r path; do
		if [[ -n "${path}" ]] && [[ -d "${path}" ]]; then
			return 0
		fi
	done <<<"${paths}"
	return 1
}

context_mode_setup() {
	local agent="${RIOTBOX_AGENT:-claude}"
	local other store data_root platform

	# Only the literal "1" enables the feature, matching RIOTBOX_HEADROOM.
	# Anything else is off — and `riotbox doctor` fails loudly on an
	# unrecognized value, so RIOTBOX_CONTEXT_MODE=true does not quietly read as
	# enabled here and as disabled everywhere else.
	if [[ "${RIOTBOX_CONTEXT_MODE:-0}" != "1" ]]; then
		context_mode_strip_all
		return 0
	fi

	# An agent contributes Context Mode support by implementing the optional
	# verbs, probed here the way container/agent-wrapper.sh probes headroom_argv.
	# The storage verb is the one every supported agent has: Claude Code no
	# longer has a wire verb — the plugin is the wiring, registered by
	# container/plugin-setup.sh — while opencode still generates a plugin shim
	# of its own. Warn and degrade for an agent with neither shape, the way that
	# wrapper does when an agent has no headroom support: wiring another agent's
	# form would not be a harmless no-op, because the config it writes lives in
	# the user's bind-mounted session directory and nothing regenerates it, so
	# the dead stanzas would outlive the session that wrote them while the
	# toggle, `riotbox doctor`, and the launcher all still reported the feature
	# as on.
	if ! declare -F "agent_${agent}_context_mode_store_dir" >/dev/null; then
		echo "  [context-mode] WARN: agent '${agent}' has no Context Mode support in riotbox." >&2
		echo "  [context-mode] Wiring skipped." >&2
		context_mode_strip_all
		return 0
	fi

	if [[ ! -x "${CONTEXT_MODE_BIN}" ]]; then
		echo "  [context-mode] WARN: context-mode is not on PATH — wiring skipped." >&2
		context_mode_strip_all
		return 0
	fi

	# Pin the FTS5 store inside the session directory. The agent names the path
	# because it follows that agent's config dir; upstream's own default already
	# resolves there — it keys off the platform config dir, which RiotBox points
	# at the session bind mount — but naming it explicitly means a change to
	# that default alone cannot silently move a store holding verbatim tool
	# output onto the container overlay, where it would vanish at exit and
	# escape `riotbox session-remove`. The pin holds only while upstream keeps
	# honouring a variable of this name: unlike the MCP server name, nothing in
	# the image build greps the installed bundle for it, so a version bump that
	# renamed or dropped it would surface in a user session, not at build time.
	#
	# A relative or empty answer is a bug in the agent's verb rather than
	# something to pass on: upstream resolves a relative CONTEXT_MODE_DIR
	# against whatever directory the hook happened to start in, which is the
	# user's project, so the store would land in the repo being worked on.
	store="$(agent_call "${agent}" context_mode_store_dir)"
	if [[ -z "${store}" ]] || [[ "${store}" != /* ]]; then
		echo "  [context-mode] WARN: agent '${agent}' produced no absolute store path" >&2
		echo "  [context-mode] ('${store}') — wiring skipped." >&2
		context_mode_strip_all
		return 0
	fi

	# CONTEXT_MODE_DIR pins the sessions/ and content/ stores behind the ctx_*
	# tools, and nothing else. An agent reaching Context Mode through an
	# in-process plugin has a second store — the plugin's own session DB, which
	# holds the same verbatim tool output — and upstream resolves that one
	# through the adapter's getSessionDir(). That reads CONTEXT_MODE_DATA_DIR, a
	# different variable, and falls back to the agent's own config dir. Where
	# RiotBox already pins that config dir (CLAUDE_CONFIG_DIR, exported by
	# entrypoint.sh) the fallback is pinned with it and there is nothing to add;
	# where upstream derives it from something RiotBox does not set (opencode
	# reads XDG_CONFIG_HOME, unset in the image, so it lands on ~/.config by
	# default), the DB sits in the session directory by coincidence and this
	# second variable is what turns that into a guarantee. So the agent decides:
	# it implements the verb only where the pin is missing, and no session
	# carries an export that explains nothing.
	#
	# The value is the PARENT of the store directory rather than the store
	# itself. Upstream appends "context-mode/sessions" to this root, while
	# CONTEXT_MODE_DIR names that "context-mode" directory outright; handing the
	# store over would bury the DB one directory below the ctx_* stores it
	# belongs beside. Same absolute-path guard as above and for the same reason:
	# upstream resolves a relative value against the process's directory, which
	# is the user's project.
	data_root=""
	if declare -F "agent_${agent}_context_mode_data_dir" >/dev/null; then
		data_root="$(agent_call "${agent}" context_mode_data_dir)"
		if [[ -z "${data_root}" ]] || [[ "${data_root}" != /* ]]; then
			echo "  [context-mode] WARN: agent '${agent}' produced no absolute data root" >&2
			echo "  [context-mode] ('${data_root}') — wiring skipped." >&2
			context_mode_strip_all
			return 0
		fi
	fi

	# Pin the platform token before anything dispatches a hook. Probed like
	# context_mode_data_dir: an agent that does not implement the verb keeps
	# upstream's own detection rather than being handed a wrong answer.
	# An empty answer is a bug in the verb, not something to export — an empty
	# CONTEXT_MODE_PLATFORM reads to upstream as "unset" on some paths and as a
	# platform named "" on others.
	platform=""
	if declare -F "agent_${agent}_context_mode_platform" >/dev/null; then
		platform="$(agent_call "${agent}" context_mode_platform)"
		if [[ -z "${platform}" ]]; then
			echo "  [context-mode] WARN: agent '${agent}' produced no platform token." >&2
			echo "  [context-mode] Wiring skipped." >&2
			context_mode_strip_all
			return 0
		fi
	fi

	# All three values are validated before any is exported, so a session that
	# gives up above leaves no storage variable behind for a later reader to
	# mistake for the feature being on.
	CONTEXT_MODE_DIR="${store}"
	export CONTEXT_MODE_DIR
	if [[ -n "${data_root}" ]]; then
		CONTEXT_MODE_DATA_DIR="${data_root}"
		export CONTEXT_MODE_DATA_DIR
	fi
	if [[ -n "${platform}" ]]; then
		CONTEXT_MODE_PLATFORM="${platform}"
		export CONTEXT_MODE_PLATFORM
	fi

	# At most one agent's wiring exists in a session directory at a time. The
	# directory outlives the run that wired it and can be reused with a
	# different --agent, so anything another agent left behind goes now.
	# shellcheck disable=SC2154  # AGENT_REGISTRY is set by agents/registry.sh (sourced above)
	for other in "${AGENT_REGISTRY[@]}"; do
		[[ "${other}" = "${agent}" ]] && continue
		declare -F "agent_${other}_context_mode_strip" >/dev/null || continue
		agent_call "${other}" context_mode_strip
	done

	# An agent that authors its own wiring writes it here. A wire that gives up
	# has already cleaned up after itself, but it cannot know about wiring an
	# earlier session left in a form it did not reach before failing — so strip
	# once more, and the session converges to the feature being off rather than
	# half on.
	#
	# An agent with no wire verb reaches Context Mode through the plugin
	# container/plugin-setup.sh registers, and there is nothing for this
	# function to write. What it must still do is strip: any hook stanza in this
	# session directory was authored by the release that wrote them by hand, and
	# leaving it beside the registered plugin would dispatch every event twice
	# against one server name two writers claim. Nothing else removes it —
	# settings.json is never synced from the host.
	#
	# What it must not do is assume that plugin arrived. Registration gives up —
	# some paths quietly, some with a warning — and returns 0 in several states,
	# among them an image built before the staging layer existed, a staged tree it
	# cannot read, and a registry document it cannot parse or write; and the
	# plugin can equally arrive from the host without any registration of ours.
	# So ask the session what it has rather than trusting either. That plugin is
	# the whole of this agent's wiring, and the flag below is read by the exit
	# report and the ledger record — the one place the user actually looks — so
	# setting it on a session without one is the false claim the all-or-nothing
	# rule on a wire verb (docs/dev/agent-contract.md) exists to prevent, arrived
	# at by an agent that has no wire verb to bind.
	if declare -F "agent_${agent}_context_mode_wire" >/dev/null; then
		if ! agent_call "${agent}" context_mode_wire; then
			agent_call "${agent}" context_mode_strip
			return 0
		fi
	else
		agent_call "${agent}" context_mode_strip
		if ! context_mode_plugin_installed; then
			echo "  [context-mode] WARN: no Context Mode plugin is installed and enabled in this session." >&2
			echo "  [context-mode] The session runs with the feature off." >&2
			# The storage pins stay exported on the way out rather than being
			# unset with the flag. They say where an FTS5 store goes, not that
			# anything was wired, and unsetting them would move a store holding
			# verbatim tool output onto the container overlay, out of reach of
			# `riotbox session-remove`, for whatever writes to it next.
			return 0
		fi
	fi

	export _CONTEXT_MODE_WIRED=1
}

# Strip Context Mode wiring for every registered agent that can have any.
# Used by every give-up path, so a half-wired session converges to off.
context_mode_strip_all() {
	local agent
	for agent in "${AGENT_REGISTRY[@]}"; do
		declare -F "agent_${agent}_context_mode_strip" >/dev/null || continue
		agent_call "${agent}" context_mode_strip
	done
}
