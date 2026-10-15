#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/opencode/context-mode.sh — Context Mode wiring for opencode.
#
# Sourced by agents/opencode/manifest.sh, which exposes the optional Context
# Mode verbs (context_mode_store_dir, context_mode_data_dir,
# context_mode_platform, context_mode_wire, context_mode_strip, and the
# build-time context_mode_build_assert).
# container/context-mode-setup.sh drives them and holds no agent names of its
# own.
#
# opencode reaches Context Mode through upstream's TypeScript plugin adapter,
# which runs in-process under opencode's embedded bun and registers the ctx_*
# tools directly — there is no MCP server and no hook stanza on this path, so
# none of the Claude constants (matchers, MCP name) have an analogue here.
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

# Under the data mount, not the config one. The stores are data: the session
# DB and ctx_* stores hold verbatim tool output and the auto-memory outlives
# any one run, and all of it is meant to persist for the project set until
# `riotbox session-remove`. The config mount cannot hold it — whenever the
# host has a ~/.config/opencode, every launch's sync (sync-settings.sh)
# deletes the state dir's opencode-config copy and renames a fresh one into
# its place. opencode-data, mounted at ~/.local/share/opencode, is only ever
# created, never re-staged. Spelled from HOME rather than XDG_DATA_HOME: the
# mount point is fixed (sync-settings.sh), whatever opencode itself resolves.
agent_opencode_context_mode_store_dir() {
	printf '%s\n' "${HOME}/.local/share/opencode/context-mode"
}

# See agents/claude/context-mode.sh for why this is pinned rather than
# detected. opencode reaches Context Mode as an in-process plugin, so its
# token is the one upstream maps to that path.
agent_opencode_context_mode_platform() {
	printf 'opencode\n'
}

# The root CONTEXT_MODE_DATA_DIR is pinned to. opencode needs this verb and
# Claude does not, because the two adapters find their config dir differently:
# claude-code's resolveClaudeConfigDir() reads CLAUDE_CONFIG_DIR, which
# entrypoint.sh exports at the session bind mount, so its session DB is already
# pinned. OpenCodeAdapter.getSessionDir() falls back to getConfigDir(), which
# reads XDG_CONFIG_HOME — unset in the image — and lands on
# ${HOME}/.config/opencode: the config mount, whose contents the host sync
# replaces on relaunch (see agent_opencode_context_mode_store_dir). The
# plugin's session DB holds verbatim tool output, so it is pinned beside the
# ctx_* stores under the data mount instead.
#
# The value is the parent of context_mode_store_dir's, not the same path:
# BaseAdapter and the opencode adapter both build the DB directory as
# `<root>/context-mode/sessions`, so this root names the directory *containing*
# the context-mode directory that CONTEXT_MODE_DIR names. Returning the store
# path here would land the DB at `<store>/context-mode/sessions`, one level
# below the ctx_* stores rather than beside them.
#
# Upstream's BaseAdapter.getMemoryDir() follows this root as well, so
# auto-memory lands in `<root>/context-mode/memory`: every piece of
# context-mode-owned state ends up under the one store directory, and
# _agent_opencode_cm_migrate_store can carry a session's older stores across
# by moving that one directory.
agent_opencode_context_mode_data_dir() {
	printf '%s\n' "${HOME}/.local/share/opencode"
}

# One-time move of the stores an earlier RiotBox kept under the config mount
# (<config>/context-mode) to the data mount. A session whose host has no
# ~/.config/opencode was never re-staged, so its stores are still there and
# would be orphaned by the new pins. Called from container setup, which runs
# before Context Mode starts. Acts on the container's own files only. Never
# merges: when both exist either may hold what the user wants, so both stay
# and the session uses the new one. Always returns 0 — a store left behind is
# reported, not fatal.
#
# The two paths are separate bind mounts, so mv cannot rename: it copies, then
# deletes. That is unsafe while an older session of the same project still
# has the session DB open — the copy can catch a half-done write, the old
# session's later writes are lost, and it recreates <config>/context-mode. A
# SQLite *.db-wal or *.db-shm file is the sign the DB may be live, so its
# presence skips the move. The same files outlive a crashed session (SIGKILL,
# OOM, stop timeout: upstream removes them only in an exit handler), and the
# WAL can hold committed rows not yet in the .db, so the warning gives the
# recovery and never suggests deleting it.
_agent_opencode_cm_migrate_store() {
	local old new parent entry target live db
	old="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/context-mode"
	new="$(agent_opencode_context_mode_store_dir)"
	parent="${new%/*}"

	[[ -e "${old}" ]] || [[ -L "${old}" ]] || return 0

	if [[ -L "${old}" ]] || [[ ! -d "${old}" ]]; then
		echo "  [context-mode] WARN: ${old} is not a real directory — left in place, not moved." >&2
		return 0
	fi

	# A link at the new path always warns, even beside an empty old dir: mv
	# would replace it, and the session's stores would land wherever it points.
	if [[ -L "${new}" ]]; then
		target="$(readlink -- "${new}")"
		echo "  [context-mode] WARN: ${new} is a link (target: ${target})," >&2
		echo "  [context-mode] not a directory — ${old} was not moved onto it." >&2
		echo "  [context-mode] Remove the link and relaunch to carry the stores across." >&2
		return 0
	fi

	if [[ -e "${new}" ]]; then
		# An empty leftover holds nothing to keep; warning about it on every
		# launch would be noise. If rmdir fails, something appeared in it since
		# the check (or find could not read it), and the warning below applies.
		if entry="$(find "${old}" -mindepth 1 -print -quit 2>/dev/null)" &&
			[[ -z "${entry}" ]] && rmdir -- "${old}" 2>/dev/null; then
			return 0
		fi
		echo "  [context-mode] WARN: Context Mode stores exist at both ${old}" >&2
		echo "  [context-mode] and ${new}. Leaving both; this session uses the second." >&2
		echo "  [context-mode] Delete or move the first by hand to resolve." >&2
		return 0
	fi

	# An old session that has not opened its DB yet has no WAL, so the move
	# goes ahead; if it then creates the DB at the old path, the next launch
	# gets the both-exist warning. The README's upgrade advice covers this.
	# find's stderr is folded into its output: on failure it is the reason.
	if ! live="$(find "${old}" \( -name '*.db-wal' -o -name '*.db-shm' \) -print -quit 2>&1)"; then
		echo "  [context-mode] WARN: could not check ${old} for an open session DB —" >&2
		echo "  [context-mode] not moved. Check permissions under it. find said:" >&2
		printf '  [context-mode]   %s\n' "${live}" >&2
		return 0
	fi
	if [[ -n "${live}" ]]; then
		db="${live%-*}"
		echo "  [context-mode] WARN: ${live} exists: an opencode session of this project" >&2
		echo "  [context-mode] may have the store open, so ${old} was not moved." >&2
		echo "  [context-mode] If one is running, exit it and relaunch. If none is, the file is" >&2
		echo "  [context-mode] left from a crash and may hold committed data; never delete it." >&2
		echo "  [context-mode] Either fold it into the DB (each such .db), then relaunch:" >&2
		echo "  [context-mode]   sqlite3 '${db}' 'PRAGMA wal_checkpoint(TRUNCATE);'" >&2
		echo "  [context-mode] or move the whole directory, -wal and -shm beside the .db:" >&2
		echo "  [context-mode]   mv -T '${old}' '${new}'" >&2
		return 0
	fi

	if [[ ! -d "${parent}" ]]; then
		echo "  [context-mode] WARN: ${parent} is missing — ${old} was not moved." >&2
		return 0
	fi

	if ! mv -T -- "${old}" "${new}"; then
		echo "  [context-mode] WARN: could not move ${old} to ${new} —" >&2
		echo "  [context-mode] a cross-mount copy may have left part of it at each; check both." >&2
		return 0
	fi

	echo "  [context-mode] Moved opencode's Context Mode stores to ${new}." >&2
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

	adapter="${pkg}/build/adapters/opencode/plugin.js"
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
# agent_opencode_context_mode_wire and agent_opencode_context_mode_platform
# depend on, so an upstream rename fails the image build rather than a user
# session. Called once per registered agent by the Context Mode block in the
# Containerfile.
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

	# The literal platform token agent_opencode_context_mode_platform pins,
	# asserted where upstream maps it to an adapter: the getAdapter() switch in
	# build/adapters/detect.js, which container/context-mode-setup.sh reaches by
	# exporting CONTEXT_MODE_PLATFORM.
	#
	# claude has no equivalent check and needs none. Its routing is guarded
	# directly — the Containerfile's probe runs the real claude-code PreToolUse
	# hook on a real payload and requires a decision back — and its token cannot
	# degrade the way this one can: getAdapter's default branch already returns
	# ClaudeCodeAdapter, so "claude-code" reaches the same adapter whether or not
	# the switch still names it.
	#
	# "opencode" has no such luck, and no probe covers it either: the shim loads
	# build/adapters/opencode/plugin.js by absolute path and never consults
	# getPluginRoot(), so a renamed token here does not kill routing. It drops
	# getAdapter() into that same default branch and hands an opencode session
	# Claude's adapter, moving its Context Mode storage out from under the pins
	# the rest of this file exists to place — silently, which is the failure
	# mode container/context-mode-setup.sh argues against everywhere else.
	# shellcheck disable=SC2312  # grep -A finding nothing leaves the second grep no input, so the mapping reads as gone — the direction that reports rather than passes
	if ! grep -A3 -F 'case "opencode":' "${pkg}/build/adapters/detect.js" \
		| grep -qF 'OpenCodeAdapter'; then
		echo "context-mode's getAdapter() in build/adapters/detect.js no longer maps the platform id \"opencode\" to OpenCodeAdapter — CONTEXT_MODE_PLATFORM=opencode would fall through to the default branch and hand opencode sessions the Claude Code adapter, silently relocating their Context Mode storage" >&2
		return 1
	fi
}
