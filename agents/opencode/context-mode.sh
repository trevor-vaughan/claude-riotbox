#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/context-mode.sh — Context Mode wiring for opencode.
#
# Sourced by agents/opencode/manifest.sh, which exposes the optional Context
# Mode verbs (context_mode_wire, context_mode_strip, and the build-time
# context_mode_build_assert).
# container/context-mode-setup.sh drives them and holds no agent names of its
# own.
#
# opencode reaches Context Mode through upstream's plugin adapter
# (opencode/plugin.js in the package), which runs in-process under opencode's
# embedded bun and registers the ctx_* tools directly — there is no MCP server
# and no hook stanza on this path, so none of the Claude constants (matchers,
# MCP name) have an analogue here. The adapter keeps its stores where every
# context-mode 2.x entry does, under ~/.context-mode.
#
# See docs/dev/decisions/context-mode-opencode.md.
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

# Write the plugin shim. All-or-nothing: returns 0 only when the shim landed,
# and leaves nothing behind on any failure path, so a give-up converges to the
# feature being off rather than half-wired.
agent_opencode_context_mode_wire() {
	local shim dir pkg adapter tmp
	shim="$(_agent_opencode_cm_shim_path)"
	dir="$(dirname "${shim}")"

	if ! pkg="$(context_mode_pkg_root)"; then
		echo "  [context-mode] WARN: could not resolve the context-mode package from" >&2
		# shellcheck disable=SC2154  # CONTEXT_MODE_BIN is set by container/context-mode-setup.sh, which drives this file
		echo "  [context-mode] ${CONTEXT_MODE_BIN} — opencode wiring skipped." >&2
		return 1
	fi

	adapter="${pkg}/opencode/plugin.js"
	if [[ ! -f "${adapter}" ]]; then
		echo "  [context-mode] WARN: ${adapter} is missing — the installed" >&2
		echo "  [context-mode] context-mode has no opencode adapter; wiring skipped." >&2
		return 1
	fi

	# Never overwrite something RiotBox did not write. A user plugin that
	# happens to sit at this path is theirs; the session runs with the
	# feature off instead.
	# shellcheck disable=SC2312  # head failing leaves grep no input, so the marker is not found and the shim is left alone — the safe direction
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
		'// The default export alone: opencode 1.x falls back to calling every' \
		'// function export as a plugin, and the adapter also exports server,' \
		'// setup and setupLegacy by name, which would register it three times.' \
		"export { default } from \"${adapter}\"" \
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

	# shellcheck disable=SC2312  # head failing leaves grep no input, so the marker is not found and the shim is left in place rather than deleted unverified
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
# agent_opencode_context_mode_wire depends on, so an upstream move fails the
# image build rather than a user session. Called once per registered agent by
# the Context Mode block in the Containerfile, which also imports the adapter
# under the pinned Node and checks its default export carries id, server and
# setup — a shape check this verb cannot make without an interpreter.
agent_opencode_context_mode_build_assert() {
	local pkg="${1:?package root required}"
	local adapter="${pkg}/opencode/plugin.js"

	if [[ ! -f "${adapter}" ]]; then
		echo "context-mode no longer ships opencode/plugin.js — the opencode shim would re-export a file that does not exist, and every opencode session would fail to load the plugin" >&2
		return 1
	fi

	# The shim re-exports the default alone. The bundle ends in one
	# `export { … }` list, where the default is spelled `<name> as default`;
	# an inline `export default` is accepted too.
	if ! grep -qE '(^|[[:space:],{])[A-Za-z_$][A-Za-z0-9_$]* as default([[:space:],}]|$)|^export default ' "${adapter}"; then
		echo "context-mode's opencode adapter has no default export — the shim re-exports the default, so opencode would load a module with no plugin in it" >&2
		return 1
	fi

	if ! jq -e '.exports["."] == "./opencode/plugin.js"' "${pkg}/package.json" >/dev/null 2>&1; then
		echo "context-mode's package.json no longer maps \".\" to ./opencode/plugin.js — the adapter has moved and the shim path is stale" >&2
		return 1
	fi
}
