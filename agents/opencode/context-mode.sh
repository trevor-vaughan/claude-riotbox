#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/context-mode.sh — Context Mode wiring for opencode.
#
# Sourced by agents/opencode/manifest.sh, which exposes the optional Context
# Mode verbs (context_mode_store_dir, context_mode_data_dir, context_mode_wire,
# context_mode_strip, and the build-time context_mode_build_assert).
# container/context-mode-setup.sh drives them and holds no agent names of its
# own.
#
# opencode reaches Context Mode through upstream's TypeScript plugin adapter,
# which runs in-process under opencode's embedded bun and registers the ctx_*
# tools directly — there is no MCP server and no hook stanza on this path, so
# none of the Claude constants (matchers, MCP name) have an analogue here.
#
# See docs/design/2026-07-31-context-mode-opencode-design.md.
# ─────────────────────────────────────────────────────────────────────────────

# First line of every shim RiotBox writes. Load-bearing in both directions:
# `wire` refuses to overwrite a file that lacks it, and `strip` refuses to
# delete one. Upstream shipped the opposite behaviour once and called it "the
# documented cause of the regression" (hooks/pretooluse.mjs:15-18); this
# stripper is not going to be the second instance.
_AGENT_OPENCODE_CM_MARKER='// riotbox-generated: context-mode shim — do not edit.'

# Absolute path of the shim. opencode auto-loads every file under the global
# plugins/ directory at startup — plural, verified against opencode 1.18.10;
# a file in the singular plugin/ is never read.
_agent_opencode_cm_shim_path() {
	printf '%s\n' "${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/plugins/riotbox-context-mode.js"
}

agent_opencode_context_mode_store_dir() {
	printf '%s\n' "${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/context-mode"
}

# The root CONTEXT_MODE_DATA_DIR is pinned to. opencode needs this verb and
# Claude does not, because the two adapters find their config dir differently:
# claude-code's resolveClaudeConfigDir() reads CLAUDE_CONFIG_DIR, which
# entrypoint.sh exports at the session bind mount, so its session DB is already
# pinned. OpenCodeAdapter.getConfigDir() reads XDG_CONFIG_HOME — unset in the
# image — and falls back to ${HOME}/.config/opencode, which is the session
# mount only by coincidence. The plugin's session DB holds verbatim tool
# output; left on the coincidence, an upstream change to that fallback would
# move it onto the container overlay, where it would vanish at exit and escape
# `riotbox session-remove`.
#
# The value is the parent of context_mode_store_dir's, not the same path:
# BaseAdapter and the opencode adapter both build the DB directory as
# `<root>/context-mode/sessions`, so this root names the directory *containing*
# the context-mode directory that CONTEXT_MODE_DIR names. Returning the store
# path here would land the DB at `<store>/context-mode/sessions`, one level
# below the ctx_* stores rather than beside them.
#
# One consequence worth naming: upstream's BaseAdapter.getMemoryDir() follows
# this root as well, so auto-memory moves from `<config>/memory` to
# `<config>/context-mode/memory`. Both are inside the session directory, and
# opencode has never had Context Mode before this, so nothing in a reusable
# session directory is orphaned by it — every piece of context-mode-owned
# state ends up under the one pinned root.
agent_opencode_context_mode_data_dir() {
	printf '%s\n' "${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
}

# Write the plugin shim. All-or-nothing: returns 0 only when the shim landed,
# and leaves nothing behind on any failure path, so a give-up converges to the
# feature being off rather than half-wired.
agent_opencode_context_mode_wire() {
	local shim dir pkg adapter tmp
	shim="$(_agent_opencode_cm_shim_path)"
	dir="$(dirname "${shim}")"

	if ! pkg="$(context_mode_pkg_root)"; then
		echo "  [context-mode] WARN: could not resolve the context-mode package from" >&2
		echo "  [context-mode] ${CONTEXT_MODE_BIN} — opencode wiring skipped." >&2
		return 1
	fi

	adapter="${pkg}/build/adapters/opencode/plugin.js"
	if [[ ! -f "${adapter}" ]]; then
		echo "  [context-mode] WARN: ${adapter} is missing — the installed" >&2
		echo "  [context-mode] context-mode has no opencode adapter; wiring skipped." >&2
		return 1
	fi

	# Never overwrite something RiotBox did not write. A user plugin that
	# happens to sit at this path is theirs; the session runs with the
	# feature off instead.
	if [[ -e "${shim}" ]] && ! head -n 1 "${shim}" | grep -qF "${_AGENT_OPENCODE_CM_MARKER}"; then
		echo "  [context-mode] WARN: ${shim} was not written by riotbox —" >&2
		echo "  [context-mode] refusing to overwrite it; wiring skipped." >&2
		return 1
	fi

	if ! mkdir -p "${dir}"; then
		echo "  [context-mode] WARN: could not create ${dir} — wiring skipped." >&2
		return 1
	fi

	# Stage in the target directory, then rename, so opencode never loads a
	# partial file. Not json_write_atomic: that writer takes JSON, and this is
	# JavaScript. mktemp creates the staged file 0600 and mv preserves it, which
	# is what we want anyway — opencode reads it as the same user.
	if ! tmp="$(mktemp "${dir}/.riotbox-context-mode.XXXXXX")"; then
		echo "  [context-mode] WARN: could not stage the shim in ${dir} — wiring skipped." >&2
		return 1
	fi

	if ! printf '%s\n' \
		"${_AGENT_OPENCODE_CM_MARKER}" \
		'// Pinned to the copy vendored in the image. An npm entry in the plugin' \
		'// array would make opencode bun-install context-mode from the registry at' \
		'// startup, which needs network (RIOTBOX_NETWORK=none forbids it) and floats' \
		'// the version off the image pin. Regenerated every session start.' \
		"export { ContextModePlugin } from \"${adapter}\"" \
		>"${tmp}"; then
		rm -f "${tmp}"
		echo "  [context-mode] WARN: could not write the shim — wiring skipped." >&2
		return 1
	fi

	if ! mv -f "${tmp}" "${shim}"; then
		rm -f "${tmp}"
		echo "  [context-mode] WARN: could not install the shim at ${shim} — wiring skipped." >&2
		return 1
	fi

	echo "  [context-mode] opencode plugin shim wired at ${shim}." >&2
}

# Remove the shim this agent's wire verb could have written. Idempotent, always
# returns 0, silent when there was nothing to remove — callers run it on every
# session start for every agent, so noise here would be noise every session.
agent_opencode_context_mode_strip() {
	local shim
	shim="$(_agent_opencode_cm_shim_path)"

	[[ -e "${shim}" ]] || return 0

	if ! head -n 1 "${shim}" | grep -qF "${_AGENT_OPENCODE_CM_MARKER}"; then
		echo "  [context-mode] WARN: ${shim} was not written by riotbox —" >&2
		echo "  [context-mode] leaving it in place." >&2
		return 0
	fi

	if ! rm -f "${shim}"; then
		echo "  [context-mode] WARN: could not remove ${shim} — stale shim left in place." >&2
		return 0
	fi

	echo "  [context-mode] Removed the Context Mode plugin shim left in" >&2
	echo "  [context-mode] $(dirname "${shim}")." >&2
}

# Build-time guard. Takes the installed package root and asserts the contract
# agent_opencode_context_mode_wire depends on, so an upstream rename fails the
# image build rather than a user session. Called once per registered agent by
# the Context Mode block in the Containerfile.
agent_opencode_context_mode_build_assert() {
	local pkg="${1:?package root required}"
	local adapter="${pkg}/build/adapters/opencode/plugin.js"

	if [[ ! -f "${adapter}" ]]; then
		echo "context-mode no longer ships build/adapters/opencode/plugin.js — the opencode shim would re-export a file that does not exist, and every opencode session would fail to load the plugin" >&2
		return 1
	fi

	if ! grep -qE '^export \{[^}]*\bContextModePlugin\b' "${adapter}"; then
		echo "context-mode's opencode adapter no longer exports ContextModePlugin — the shim re-exports that name, so opencode would load a plugin with no hooks" >&2
		return 1
	fi

	if ! jq -e '.exports["./plugin"] == "./build/adapters/opencode/plugin.js"' \
		"${pkg}/package.json" >/dev/null 2>&1; then
		echo "context-mode's package.json no longer maps ./plugin to build/adapters/opencode/plugin.js — the adapter has moved and the shim path is stale" >&2
		return 1
	fi
}
