#!/usr/bin/env bash
# shellcheck disable=SC2154  # CM_PIN, CM_NODE_PIN and CM_HOOKS_EXPECTED arrive through podman run -e; see below
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/context-mode-probe.sh — the in-image half of `riotbox doctor`'s
# Context Mode check.
#
# Neither sourced nor run on the host. preflight_check_context_mode
# (scripts/preflight.sh) passes this file's text to `podman run … bash -c`, so
# it runs inside the image as the session user, where nothing else in this repo
# is sourced. It reads three variables that preflight passes with -e, all from
# the install tree doctor runs from:
#   CM_PIN             ARG CONTEXT_MODE_VERSION in the Containerfile
#   CM_NODE_PIN        ARG CONTEXT_MODE_NODE in the Containerfile
#   CM_HOOKS_EXPECTED  container/context-mode-hooks-expected.json, as jq -Sc
#
# Each check repeats one that the Containerfile's Context Mode layer makes at
# build time, against the image as it is now. The checks are the CLI and its
# pinned Node, the OpenCode adapter's default export, the Pi extension, the
# staged Claude plugin's hook table, and the routing probe. The last check is
# the one the build cannot make: ~/.context-mode, mounted by preflight the way
# a session mounts it, is writable. Change a probe there and change it here,
# or doctor approves a different image from the one the build approved.
#
# The staged tree is resolved as context_mode_staged_path
# (container/plugin-setup.sh) resolves it, and its version is read as
# context_mode_staged_version reads it, so doctor judges the tree a session
# registers. Never assert less than session start does.
#
# Each failure prints one line on stderr naming what is wrong and exits 1;
# preflight puts that line in its hint. Exits 0 after the last check.
# ─────────────────────────────────────────────────────────────────────────────

cm_fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

# ── The CLI and its pinned Node ─────────────────────────────────────────────
cm_bin="$(command -v context-mode)" || cm_fail "no context-mode on PATH"
cm_version="$("${cm_bin}" --version 2>/dev/null)" || cm_fail "context-mode --version failed"
[[ "${cm_version}" == "${CM_PIN}" ]] ||
	cm_fail "context-mode --version is '${cm_version}', this riotbox pins ${CM_PIN}"

# The shim is `exec "<node>" "<package>/cli.mjs" "$@"`; the package pattern is
# context_mode_pkg_root's, which the OpenCode and Pi wiring build their paths
# from.
cm_node="$(sed -n 's|^exec "\([^"]*\)" "[^"]*/cli\.mjs".*|\1|p' "${cm_bin}")"
cm_pkg="$(sed -n 's|^exec "[^"]*" "\(.*\)/cli\.mjs".*|\1|p' "${cm_bin}")"
[[ -n "${cm_node}" && -n "${cm_pkg}" ]] ||
	cm_fail "cannot read the pinned Node and package root out of ${cm_bin}"
cm_node_version="$("${cm_node}" --version 2>/dev/null)" ||
	cm_fail "the Node the shim runs (${cm_node}) does not start"
[[ "${cm_node_version}" == "v${CM_NODE_PIN}" ]] ||
	cm_fail "the shim runs Node ${cm_node_version}, this riotbox pins v${CM_NODE_PIN}"

# HOME is a scratch directory for everything that runs context-mode code, so
# the probe leaves no store behind, in the image or in the mounted one.
cm_scratch="$(mktemp -d)" || cm_fail "cannot create a scratch directory"
trap 'rm -rf "${cm_scratch}"' EXIT

# ── OpenCode and Pi ─────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # JavaScript, not shell
HOME="${cm_scratch}" "${cm_node}" --input-type=module -e 'const d = (await import(process.argv[1])).default; if (!(d && typeof d.id === "string" && typeof d.server === "function" && typeof d.setup === "function")) process.exit(1);' "${cm_pkg}/opencode/plugin.js" >/dev/null 2>&1 ||
	cm_fail "the OpenCode adapter (${cm_pkg}/opencode/plugin.js) does not import on the pinned Node with a default export carrying id, server and setup"
[[ -f "${cm_pkg}/pi/index.js" ]] ||
	cm_fail "${cm_pkg} has no pi/index.js — Pi would load no Context Mode extension"

# ── The staged Claude plugin ────────────────────────────────────────────────
cm_plugin_dir="${RIOTBOX_CM_PLUGIN_DIR:-${HOME}/.riotbox/context-mode-plugin}"
# shellcheck disable=SC2312  # a failing find prints nothing, which the next line reports
cm_tree="$(find "${cm_plugin_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -n 1)"
[[ -n "${cm_tree}" ]] || cm_fail "no staged Claude plugin tree under ${cm_plugin_dir}"
cm_tree_version="$(jq -r '.version | select(type == "string")' "${cm_tree}/package.json" 2>/dev/null)"
[[ -n "${cm_tree_version}" ]] ||
	cm_fail "the staged tree ${cm_tree} declares no version in package.json — a session would not register it"
[[ "${cm_tree_version}" == "${CM_PIN}" ]] ||
	cm_fail "the staged tree ${cm_tree} is context-mode ${cm_tree_version}, this riotbox pins ${CM_PIN}"
[[ -r "${cm_tree}/.claude-plugin/plugin.json" ]] ||
	cm_fail "the staged tree ${cm_tree} has no .claude-plugin/plugin.json — nothing can register it"

cm_hooks="${cm_tree}/hooks/claude-code.json"
cm_table="$(jq -Sc '.hooks | map_values([.[].matcher])' "${cm_hooks}" 2>/dev/null)" ||
	cm_fail "cannot read the staged hook table ${cm_hooks}"
[[ "${cm_table}" == "${CM_HOOKS_EXPECTED}" ]] ||
	cm_fail "the staged hook table is not the one container/context-mode-hooks-expected.json pins: ${cm_table}"

# The routing probe, as the build runs it: the real PreToolUse command with
# PATH scrubbed of any Node, so a command still invoking a bare node answers
# nothing. The plain ls control keeps a hook that answers every tool from
# passing.
cm_pre="$(jq -r 'first(.hooks.PreToolUse[].hooks[].command) // empty' "${cm_hooks}" 2>/dev/null)"
[[ -n "${cm_pre}" ]] || cm_fail "the staged hook table has no PreToolUse command"
cm_route() {
	# shellcheck disable=SC2312  # a hook that fails answers nothing, which is what the callers test
	printf '{"session_id":"riotbox-doctor-probe","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' \
		"${cm_scratch}" "$1" "$2" |
		env PATH=/usr/bin:/bin HOME="${cm_scratch}" \
			CLAUDE_PLUGIN_ROOT="${cm_tree}" CLAUDE_PROJECT_DIR="${cm_scratch}" \
			sh -c "${cm_pre}" 2>/dev/null |
		jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null
}
cm_control="$(cm_route Bash '{"command":"ls"}')"
[[ -z "${cm_control}" ]] ||
	cm_fail "the staged PreToolUse hook decided '${cm_control}' for a plain ls — it answers every tool, so its WebFetch answer would prove nothing"
cm_decision="$(cm_route WebFetch '{"url":"https://example.invalid/riotbox-doctor-probe","prompt":"p"}')"
[[ -n "${cm_decision}" ]] ||
	cm_fail "the staged plugin (hook.mjs --agent claude-code) returned no PreToolUse decision for WebFetch — a session would route nothing"

# ── The store ───────────────────────────────────────────────────────────────
cm_store_probe="${HOME}/.context-mode/.riotbox-doctor-probe"
touch "${cm_store_probe}" 2>/dev/null ||
	cm_fail "${HOME}/.context-mode is not writable — every Context Mode store write in a session would fail"
rm -f "${cm_store_probe}"
exit 0
