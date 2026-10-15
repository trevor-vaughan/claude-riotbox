#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/context-mode.sh — Context Mode wiring for Pi.
#
# Sourced by agents/pi/manifest.sh, which exposes the optional Context Mode
# verbs (context_mode_store_dir, context_mode_data_dir, context_mode_platform,
# context_mode_wire, context_mode_strip, and the build-time
# context_mode_build_assert). container/context-mode-setup.sh drives them and
# holds no agent names of its own.
#
# Pi reaches Context Mode as a Pi package: the installed context-mode package
# root declares `pi.extensions` (build/adapters/pi/extension.js) in its
# package.json, and Pi loads it when the root is listed in settings.json
# `packages`. That list is RiotBox-owned — agents/pi/setup.sh rewrites it on
# every container start, before context_mode_setup runs — so wiring is one
# entry appended to it and stripping is that entry removed.
# ─────────────────────────────────────────────────────────────────────────────

_agent_pi_cm_settings_path() {
	printf '%s\n' "${HOME}/.pi/agent/settings.json"
}

agent_pi_context_mode_store_dir() {
	printf '%s\n' "${HOME}/.pi/agent/context-mode"
}

# See agents/claude/context-mode.sh for why this is pinned rather than
# detected. It matters more for Pi than for most: upstream's detection picks
# "pi" whenever ~/.pi exists, and in RiotBox it exists in every session,
# because host_sync mounts ~/.pi/agent for every registered agent.
agent_pi_context_mode_platform() {
	printf 'pi\n'
}

# The root CONTEXT_MODE_DATA_DIR is pinned to. Without it, PiAdapter puts its
# session DB under ~/.pi/context-mode/sessions — outside the ~/.pi/agent
# session bind mount, on the container overlay, where verbatim tool output
# would vanish at exit and escape `riotbox session-remove`. The value is the
# parent of context_mode_store_dir's path, because BaseAdapter builds the DB
# directory as <root>/context-mode/sessions.
agent_pi_context_mode_data_dir() {
	printf '%s\n' "${HOME}/.pi/agent"
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
# always returns 0, silent when there was nothing to remove. The entry is
# recognised by its last path segment being exactly `context-mode`, so a user
# entry that merely contains the name (my-context-mode-tools, context-mode-fork/x)
# is never removed. `packages` is RiotBox-owned (setup.sh replaces it on every
# start) and the image's own extensions are not named context-mode.
agent_pi_context_mode_strip() {
	local settings doc
	settings="$(_agent_pi_cm_settings_path)"
	[[ -f "${settings}" ]] || return 0

	# An unreadable or non-object file is left alone; there is nothing this
	# verb could safely edit in it.
	jq -e '(.packages // []) | type == "array" and any(.[]; type == "string" and test("(^|/)context-mode/?$"))' \
		"${settings}" >/dev/null 2>&1 || return 0

	if ! doc="$(jq '.packages |= map(select((type == "string" and test("(^|/)context-mode/?$")) | not))' "${settings}")" ||
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
	if ! jq -e '.pi.extensions == ["./build/adapters/pi/extension.js"]' "${pkg}/package.json" >/dev/null 2>&1; then
		echo "context-mode's package.json no longer declares pi.extensions as [\"./build/adapters/pi/extension.js\"] — the package root agent_pi_context_mode_wire lists would load a different extension, or none" >&2
		return 1
	fi

	if [[ ! -f "${pkg}/build/adapters/pi/extension.js" ]]; then
		echo "context-mode no longer ships build/adapters/pi/extension.js — Pi would load a package with no Context Mode extension" >&2
		return 1
	fi

	# CONTEXT_MODE_DATA_DIR only relocates the session DB because PiAdapter
	# inherits BaseAdapter.getSessionDir(). An override of its own (method,
	# async method, or property assignment) could ignore the variable and put
	# verbatim tool output back on the container overlay. A missing file must
	# fail: grep would exit 2 and read as "no override".
	local adapter_index="${pkg}/build/adapters/pi/index.js"
	if [[ ! -f "${adapter_index}" ]]; then
		echo "context-mode no longer ships build/adapters/pi/index.js — the getSessionDir() override check cannot run, so CONTEXT_MODE_DATA_DIR may no longer pin Pi's session DB inside the ~/.pi/agent session mount" >&2
		return 1
	fi
	# shellcheck disable=SC2312  # grep -v finding no lines leaves grep -q no input, so no override is found only when the file is all comments — the file exists (checked above)
	if grep -vE '^[[:space:]]*//' "${adapter_index}" | grep -qE 'getSessionDir[[:space:]]*(\(|=)'; then
		echo "context-mode's PiAdapter now overrides getSessionDir() — CONTEXT_MODE_DATA_DIR may no longer pin its session DB inside the ~/.pi/agent session mount" >&2
		return 1
	fi

	# The pi case of getAdapter() must dynamically import ./pi/index.js and name
	# PiAdapter on a non-comment line within its block. -A12 leaves room for the
	# comments upstream puts above the import.
	local detect="${pkg}/build/adapters/detect.js"
	# shellcheck disable=SC2312  # a missing detect.js or case leaves the later greps no input, so the mapping reads as gone — the direction that reports rather than passes
	if ! grep -qE "import\\(['\"]\\./pi/index\\.js['\"]\\)" "${detect}" ||
		! grep -A12 -E "case ['\"]pi['\"]:" "${detect}" | grep -vE '^[[:space:]]*//' | grep -qF 'PiAdapter'; then
		echo "context-mode's getAdapter() in build/adapters/detect.js no longer maps the platform id \"pi\" to PiAdapter — CONTEXT_MODE_PLATFORM=pi would hand Pi sessions another platform's adapter and storage" >&2
		return 1
	fi
}
