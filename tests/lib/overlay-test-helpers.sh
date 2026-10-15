#!/usr/bin/env bash
# Shared helpers for overlay Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# shellcheck source=tests/lib/engine-stub.sh
source "$(dirname "${BASH_SOURCE[0]}")/engine-stub.sh"

# Create an overlay test environment with a project, its session directory,
# and its state directory, which is where overlay data lives. Like a launch,
# it records the project in the state dir's projects file (record_projects)
# as well as in the session dir's .projects.
# Args:
#   $1 — tmpdir base (default: /tmp). Use /dev/shm for whiteout tests.
# Sets: TEST_DIR, PROJECT, SESSION_KEY, SESSION, STATE, OVERLAY
# Exports: XDG_DATA_HOME, ROOT_DIR, CONTAINER_CMD, STUB_RUNNING, STUB_PS_CALLS
#
# CONTAINER_CMD is the stub engine from tests/lib/engine-stub.sh, because
# overlay-accept and overlay-reject refuse unless the engine confirms that no
# running RiotBox container has the overlay mounted read-write; see
# install_stub_engine for the STUB_* variables that drive it.
setup_overlay_test() {
	local tmpbase="${1:-/tmp}"
	TEST_DIR="$(mktemp -d --tmpdir="${tmpbase}")"

	PROJECT="${TEST_DIR}/myproject"
	mkdir -p "${PROJECT}"

	SESSION_KEY="$(echo "${PROJECT}" | sed 's|/|-|g; s|^-||')"
	export XDG_DATA_HOME="${TEST_DIR}/data"
	SESSION="${XDG_DATA_HOME}/riotbox/${SESSION_KEY}"
	STATE="${XDG_DATA_HOME}/riotbox-state/${SESSION_KEY}"
	OVERLAY="${STATE}/overlay/project"
	mkdir -p "${SESSION}" "${OVERLAY}/upper" "${OVERLAY}/work"
	echo "${PROJECT}" >"${SESSION}/.projects"
	echo "${PROJECT}" >"${STATE}/projects"

	# shellcheck disable=SC2154  # RIOTBOX_DIR is set by the Venom test runner that sources this file
	export ROOT_DIR="${RIOTBOX_DIR}"

	install_stub_engine "${TEST_DIR}"
}

# Create a two-project overlay session the way a launch of "${P1} ${P2}"
# lays it out: one session key for the set, and one overlay dir per project
# named after its basename (overlay/app, overlay/lib). Calls
# setup_overlay_test first, so everything it sets and exports is available.
# Args: $1 — tmpdir base, as for setup_overlay_test.
# Sets: P1, P2 (canonical project dirs), MSESSION, MSTATE, OV1, OV2
setup_multi_overlay_test() {
	setup_overlay_test "${1:-/tmp}"
	mkdir -p "${TEST_DIR}/a/app" "${TEST_DIR}/b/lib"
	P1="$(cd "${TEST_DIR}/a/app" && pwd -P)"
	P2="$(cd "${TEST_DIR}/b/lib" && pwd -P)"
	# The key is a hash of the set: take it from the launch's own resolver.
	local resolved
	# shellcheck disable=SC1091 # sourced in a subshell from the tree under test
	resolved="$(
		source "${ROOT_DIR}/scripts/mount-projects.sh"
		resolve_projects "${P1} ${P2}"
		printf '%s\n%s\n' "${RIOTBOX_SESSION_DIR}" "${RIOTBOX_STATE_DIR}"
	)"
	MSESSION="${resolved%%$'\n'*}"
	MSTATE="${resolved#*$'\n'}"
	OV1="${MSTATE}/overlay/app"
	OV2="${MSTATE}/overlay/lib"
	mkdir -p "${MSESSION}" "${OV1}/upper" "${OV1}/work" "${OV2}/upper" "${OV2}/work"
	printf '%s\n' "${P1}" "${P2}" >"${MSESSION}/.projects"
	printf '%s\n' "${P1}" "${P2}" >"${MSTATE}/projects"
}

# launch_overlay <project>...
#   Launch an overlay-mode session for the projects as `riotbox <project>...`
#   does (libexec/launch.sh with RIOTBOX_PROJECTS joined by spaces), against
#   the stub engine, with HOME and the config dirs inside TEST_DIR. stderr
#   goes to ${TEST_DIR}/launch.err; returns the launch's exit status. Needs
#   setup_overlay_test.
launch_overlay() {
	local rc=0
	mkdir -p "${TEST_DIR}/home" "${TEST_DIR}/etc"
	(
		export HOME="${TEST_DIR}/home"
		unset CONTEXT_MODE_DIR RIOTBOX_CONTEXT_MODE RIOTBOX_AGENT _CONTEXT_MODE_WIRED CONTEXT_MODE_DATA_DIR CONTEXT_MODE_PLATFORM
		export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
			GIT_AUTHOR_NAME=riotbox-test GIT_AUTHOR_EMAIL=riotbox-test@invalid \
			GIT_COMMITTER_NAME=riotbox-test GIT_COMMITTER_EMAIL=riotbox-test@invalid
		# shellcheck disable=SC2031 # ROOT_DIR is exported by setup_overlay_test; the subshell in setup_multi_overlay_test does not change it
		RIOTBOX_OVERLAY=1 RIOTBOX_PROJECTS="$*" XDG_CONFIG_HOME="${TEST_DIR}/home/.config" \
			RIOTBOX_SYSCONF_DIR="${TEST_DIR}/etc" IMAGE_NAME=riotbox \
			bash "${ROOT_DIR}/libexec/launch.sh" bash
	) >/dev/null 2>"${TEST_DIR}/launch.err" || rc=$?
	return "${rc}"
}
