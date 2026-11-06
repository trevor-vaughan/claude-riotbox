#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# context-mode-setup.sh — Context Mode wiring for a RiotBox session.
#
# Sourced by entrypoint.sh. Provides:
#   context_mode_setup — when RIOTBOX_CONTEXT_MODE=1, drive the running agent's
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
# against.
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
# Why nothing here runs the vendor installer: `context-mode setup` writes each
# agent's config for a global npm install, and `context-mode upgrade` runs
# `npm i -g context-mode` from the registry. Running either at session start
# would swap pinned, reviewed code for whatever is published, inside a container
# holding the user's project, and would break RIOTBOX_NETWORK=none. Instead the
# image installs the package once from a committed lockfile; Claude Code gets
# that package registered as its plugin by container/plugin-setup.sh, opencode
# a generated shim that re-exports its adapter, and Pi an entry naming its root.
# None of the three reaches the network at session start.
#
# Where the stores go is not decided here. context-mode 2.x keeps every store
# under ~/.context-mode. It reads neither CONTEXT_MODE_DIR nor
# CONTEXT_MODE_PLATFORM, and CONTEXT_MODE_DATA_DIR now names its whole data root
# rather than the parent directory the 1.x pin pointed it at, so exporting the
# values the 1.x integration exported would move the store, not pin it. This
# file exports none of them.
#
# CONTEXT_MODE_REQUIRE_SECURITY is deliberately not set either. With it at 1,
# context-mode denies every Claude tool call whenever a Claude deny-rules file
# exists but cannot be parsed (src/core/policy/decide.ts:57-61 upstream). RiotBox
# runs Claude with --dangerously-skip-permissions and writes no deny rules, so
# nothing it relies on is protected, and one malformed user settings file would
# brick the session. tests/context-mode.venom.yml asserts it stays unexported.
#
# Why per session rather than at build time: ~/.claude is replaced by a session
# bind mount (scripts/mount-projects.sh), so agent config written into the
# image is invisible at runtime — the same reason codegraph-setup.sh and
# plugin-setup.sh run here.
# ─────────────────────────────────────────────────────────────────────────────

# The shim the image build installs. It execs the pinned Node 24 against the
# package's cli.mjs; see the Context Mode block in the Containerfile for why a
# bare `node` is wrong. Overridable so the behavior can be tested without the image.
CONTEXT_MODE_BIN="${CONTEXT_MODE_BIN:-${HOME}/.local/bin/context-mode}"

# The vendored package root, derived from the shim the image build generates
# at CONTEXT_MODE_BIN. Deriving beats hardcoding: the path embeds
# ARG CONTEXT_MODE_VERSION, and a second copy of that version in shell would rot
# silently the first time the ARG moves. The build asserts this derivation
# against the true CM_PKG (see the Context Mode block in the Containerfile),
# so a shim whose shape changes fails the build rather than a session.
#
# Prints the absolute package root on stdout; returns 1 and prints nothing when
# the shim is absent or does not carry a cli.mjs exec line.
context_mode_pkg_root() {
	local bundle
	[[ -r "${CONTEXT_MODE_BIN}" ]] || return 1
	# sed exits 0 when it matches nothing, so the `|| return 1` below fires only
	# on a genuine read error — the emptiness check after it is what rejects a
	# shim this pattern cannot parse.
	bundle="$(sed -n 's|^exec "[^"]*" "\(.*\)/cli\.mjs".*|\1|p' "${CONTEXT_MODE_BIN}")" || return 1
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
	local other store found=()

	# 2.1.4 reads CONTEXT_MODE_DATA_DIR as its whole data root, so a value that
	# reached the container — a passthrough entry, an extra -e — would move
	# every store off the ~/.context-mode session mount without a word. The
	# mount is the only placement RiotBox relies on. Cleared before the
	# feature check: a plugin copied in from the host runs either way.
	unset CONTEXT_MODE_DATA_DIR

	# Only the literal "1" enables the feature, matching RIOTBOX_HEADROOM.
	# Anything else is off — and `riotbox doctor` fails loudly on an
	# unrecognized value, so RIOTBOX_CONTEXT_MODE=true does not quietly read as
	# enabled here and as disabled everywhere else.
	if [[ "${RIOTBOX_CONTEXT_MODE:-0}" != "1" ]]; then
		context_mode_strip_all
		return 0
	fi

	# Where the 1.x integration pinned each agent's store. 2.x neither reads
	# nor imports them, and they are left for the user to delete: say where
	# they are, in one line. A directory with nothing in it is not a store.
	for store in "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode" \
		"${HOME}/.pi/agent/context-mode" \
		"${HOME}/.local/share/opencode/context-mode"; do
		[[ -d "${store}" && ! -L "${store}" ]] || continue
		# shellcheck disable=SC2312  # a find that cannot list it prints nothing, and the store goes unnamed — advisory only
		[[ -n "$(find "${store}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || continue
		found+=("${store}")
	done
	if [[ ${#found[@]} -gt 0 ]]; then
		echo "  [context-mode] NOTE: context-mode 1.x stores are no longer read; left in place: ${found[*]}" >&2
	fi

	# An agent contributes Context Mode support by implementing the optional
	# verbs, probed here the way container/agent-wrapper.sh probes headroom_argv.
	# The contract verb is the one every supported agent has: an agent whose
	# support rests on an upstream contract declares that contract in
	# context_mode_build_assert, and an agent that never reaches Context Mode
	# has none. It is deliberately not the wire verb: Claude Code has none — the
	# plugin is the wiring, registered by container/plugin-setup.sh — so a probe
	# on `wire` would read the best-supported agent as unsupported. Warn and
	# degrade for an agent without it, the way that wrapper does when an agent
	# has no headroom support: wiring another agent's form would not be a
	# harmless no-op, because the config it writes lives in the user's
	# bind-mounted session directory and nothing regenerates it, so the dead
	# stanzas would outlive the session that wrote them while the toggle,
	# `riotbox doctor`, and the launcher all still reported the feature as on.
	if ! declare -F "agent_${agent}_context_mode_build_assert" >/dev/null; then
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
