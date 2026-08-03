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
# contracts the build also asserts — the matchers, the MCP server name, the
# opencode adapter — live beside the wiring that depends on them, in
# agents/*/context-mode.sh, and reach the build through agents/registry.sh.
#
# Nothing here writes JSON: that moved to agents/claude/context-mode.sh with the
# rest of the Claude wiring. json_write_atomic (scripts/lib/json-write.sh) stays
# a dependency of the files that call it rather than a source line in any of
# them — entrypoint.sh sources the library ahead of all of them at run time,
# while the build sources them and calls nothing that writes, and the same
# writer is shared with codegraph-setup.sh, so no single caller can own it.
#
# Why RiotBox writes the wiring instead of running the vendor installer:
# `context-mode upgrade` is the only command that configures hooks, and it
# git-clones https://github.com/mksglu/context-mode.git and — when upstream is
# newer — npm-installs, builds, and copies the result over the installed
# package tree. Running that at session start would swap pinned, reviewed code
# for whatever is on main, inside a container holding the user's project, and
# would break RIOTBOX_NETWORK=none. What it writes is two JSON stanzas;
# RiotBox writes them directly, offline, and the Containerfile guards the
# template against upstream drift at build time.
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

context_mode_setup() {
	local agent="${RIOTBOX_AGENT:-claude}"
	local other store data_root

	# Only the literal "1" enables the feature, matching RIOTBOX_HEADROOM.
	# Anything else is off — and `riotbox doctor` fails loudly on an
	# unrecognized value, so RIOTBOX_CONTEXT_MODE=true does not quietly read as
	# enabled here and as disabled everywhere else.
	if [[ "${RIOTBOX_CONTEXT_MODE:-0}" != "1" ]]; then
		context_mode_strip_all
		return 0
	fi

	# An agent wires Context Mode by implementing the optional verbs, probed
	# here the way container/agent-wrapper.sh probes headroom_argv. Warn and
	# degrade for one that does not, the way that wrapper does when an agent
	# has no headroom support — wiring another agent's form would not be a
	# harmless no-op, because the config it writes lives in the user's
	# bind-mounted session directory and nothing regenerates it, so the dead
	# stanzas would outlive the session that wrote them while the toggle,
	# `riotbox doctor`, and the launcher all still reported the feature as on.
	if ! declare -F "agent_${agent}_context_mode_wire" >/dev/null; then
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
	# honouring a variable of this name: unlike the matcher, the MCP server
	# name, and the `hook <platform> <event>` dispatcher, nothing in the image
	# build greps the installed bundle for it, so a version bump that renamed or
	# dropped it would surface in a user session, not at build time.
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

	# Both values are validated before either is exported, so a session that
	# gives up above leaves no storage variable behind for a later reader to
	# mistake for the feature being on.
	CONTEXT_MODE_DIR="${store}"
	export CONTEXT_MODE_DIR
	if [[ -n "${data_root}" ]]; then
		CONTEXT_MODE_DATA_DIR="${data_root}"
		export CONTEXT_MODE_DATA_DIR
	fi

	# At most one agent's wiring exists in a session directory at a time. The
	# directory outlives the run that wired it and can be reused with a
	# different --agent, so anything another agent left behind goes now.
	for other in "${AGENT_REGISTRY[@]}"; do
		[[ "${other}" = "${agent}" ]] && continue
		declare -F "agent_${other}_context_mode_strip" >/dev/null || continue
		agent_call "${other}" context_mode_strip
	done

	# A wire that gives up has already cleaned up after itself, but it cannot
	# know about wiring an earlier session left in a form it did not reach
	# before failing. Strip once more so the session converges to the feature
	# being off rather than half on.
	if ! agent_call "${agent}" context_mode_wire; then
		agent_call "${agent}" context_mode_strip
		return 0
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
