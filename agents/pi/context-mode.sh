#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/context-mode.sh — Context Mode wiring for Pi.
#
# Sourced by agents/pi/manifest.sh, which exposes the optional Context Mode
# verbs (context_mode_wire, context_mode_strip, and the build-time
# context_mode_build_assert). container/context-mode-setup.sh drives them and
# holds no agent names of its own.
#
# Pi reaches Context Mode as a Pi package: the installed context-mode package
# root declares `pi.extensions` (pi/index.js) in its package.json, and Pi loads
# it when the root is listed in settings.json `packages`. That list is
# RiotBox-owned — agents/pi/setup.sh rewrites it on every container start,
# before context_mode_setup runs — so wiring is one entry appended to it and
# stripping is that entry removed.
#
# The extension runs in-process, in Pi's own Node, and keeps its stores under
# ~/.context-mode like every context-mode 2.x entry — which is why PI_NODE
# carries context-mode's Node floor (see the Pi block in the Containerfile).
# ─────────────────────────────────────────────────────────────────────────────

_agent_pi_cm_settings_path() {
	printf '%s\n' "${HOME}/.pi/agent/settings.json"
}

# Append the vendored context-mode package root to settings.json `packages`.
# All-or-nothing: returns 0 only when the entry landed, and strips on a failed
# write so a give-up converges to the feature being off.
agent_pi_context_mode_wire() {
	local settings pkg current doc
	settings="$(_agent_pi_cm_settings_path)"

	if ! pkg="$(context_mode_pkg_root)"; then
		echo "  [context-mode] WARN: could not resolve the context-mode package from" >&2
		# shellcheck disable=SC2154  # CONTEXT_MODE_BIN is set by container/context-mode-setup.sh, which drives this file
		echo "  [context-mode] ${CONTEXT_MODE_BIN} — pi wiring skipped." >&2
		return 1
	fi

	if ! jq -e '.pi.extensions | type == "array" and length > 0' "${pkg}/package.json" >/dev/null 2>&1; then
		echo "  [context-mode] WARN: ${pkg}/package.json declares no pi.extensions —" >&2
		echo "  [context-mode] the installed context-mode has no Pi package; wiring skipped." >&2
		return 1
	fi

	current='{}'
	if [[ -f "${settings}" ]] &&
		{ ! current="$(jq -c 'if type == "object" then . else error("root must be an object") end' "${settings}" 2>/dev/null)" || [[ -z "${current}" ]]; }; then
		echo "  [context-mode] WARN: ${settings} is not a valid JSON object — wiring skipped." >&2
		return 1
	fi

	if ! doc="$(jq --arg pkg "${pkg}" \
		'.packages = (((.packages // []) | map(select(. != $pkg))) + [$pkg])' <<<"${current}" 2>/dev/null)" ||
		[[ -z "${doc}" ]]; then
		echo "  [context-mode] WARN: could not compose ${settings} — wiring skipped." >&2
		return 1
	fi

	if ! json_write_atomic "${settings}" "${doc}"; then
		echo "  [context-mode] WARN: could not write ${settings} — wiring skipped." >&2
		agent_pi_context_mode_strip
		return 1
	fi

	echo "  [context-mode] pi package wired in ${settings}." >&2
}

# Remove the context-mode entry from settings.json `packages`. Idempotent,
# always returns 0, silent when there was nothing to remove. Two shapes are
# RiotBox's:
#   * any path under RIOTBOX_CM_PLUGIN_DIR/ — where the image stages the 2.x
#     package as v<version>, and what context_mode_pkg_root resolves. Matching
#     the directory rather than this image's exact path keeps an entry an
#     older image wrote, naming its own version, strippable after a bump;
#   * a path whose last segment is exactly `context-mode` — the 1.x package
#     root under nvm's node_modules, still in session directories that
#     outlive the image that wired them.
# A user entry that merely contains the name (my-context-mode-tools,
# context-mode-fork/x) matches neither and is never removed. `packages` is
# RiotBox-owned (setup.sh replaces it on every start) and the image's own
# extensions live elsewhere. The default matches container/plugin-setup.sh's.
agent_pi_context_mode_strip() {
	local settings doc staged ours
	settings="$(_agent_pi_cm_settings_path)"
	[[ -f "${settings}" ]] || return 0
	staged="${RIOTBOX_CM_PLUGIN_DIR:-${HOME}/.riotbox/context-mode-plugin}/"
	# shellcheck disable=SC2016  # $dir is a jq variable, not a shell one
	ours='type == "string" and (startswith($dir) or test("(^|/)context-mode/?$"))'

	# An unreadable or non-object file is left alone; there is nothing this
	# verb could safely edit in it.
	jq -e --arg dir "${staged}" "(.packages // []) | type == \"array\" and any(.[]; ${ours})" \
		"${settings}" >/dev/null 2>&1 || return 0

	if ! doc="$(jq --arg dir "${staged}" ".packages |= map(select((${ours}) | not))" "${settings}")" ||
		! json_write_atomic "${settings}" "${doc}"; then
		echo "  [context-mode] WARN: could not remove the context-mode package from ${settings}." >&2
		return 0
	fi

	echo "  [context-mode] Removed the Context Mode package from ${settings}." >&2
}

# Build-time guard. Takes the installed package root and asserts the upstream
# contract the verbs above depend on, so an upstream move fails the image
# build rather than a session. Called once per registered agent by the
# Context Mode block in the Containerfile.
agent_pi_context_mode_build_assert() {
	local pkg="${1:?package root required}"

	# Strict on purpose: if upstream adds a second Pi extension, a human should
	# review it rather than have it loaded silently.
	if ! jq -e '.pi.extensions == ["./pi/index.js"]' "${pkg}/package.json" >/dev/null 2>&1; then
		echo "context-mode's package.json no longer declares pi.extensions as [\"./pi/index.js\"] — the package root agent_pi_context_mode_wire lists would load a different extension, or none" >&2
		return 1
	fi

	if [[ ! -f "${pkg}/pi/index.js" ]]; then
		echo "context-mode no longer ships pi/index.js — Pi would load a package with no Context Mode extension" >&2
		return 1
	fi

	# Pi calls the extension module's default export. The bundle ends in one
	# `export { … }` list, where it is spelled `<name> as default`; an inline
	# `export default` is accepted too.
	if ! grep -qE '(^|[[:space:],{])[A-Za-z_$][A-Za-z0-9_$]* as default([[:space:],}]|$)|^export default ' "${pkg}/pi/index.js"; then
		echo "context-mode's pi/index.js has no default export — Pi would load the package and register no extension" >&2
		return 1
	fi
}
