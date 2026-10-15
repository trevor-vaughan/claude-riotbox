#!/usr/bin/env bash
# Shared helpers for agents/claude/sync-settings.sh Venom tests.
# Source this file at the top of each test script.
#
# sync-settings.sh copies host ~/.claude/ resources into a per-session
# directory that the container later bind-mounts as its ~/.claude. Tests
# stage a fake host home, run the script, and inspect the session dir.
set -euo pipefail

# Stage a fresh test environment.
# Sets: TEST_DIR, HOST_CLAUDE, SESSION_DIR, EXTERNAL_DIR
# Exports: HOME
#
# Layout under TEST_DIR:
#   home/.claude/           — fake HOST_CLAUDE_DIR (arg 1 to sync-settings.sh)
#   home/.claude/plugins/   — pre-created so the "plugins not found" notice
#                              (harmless, but noisy) is suppressed
#   session/                — fake SESSION_DIR (arg 2)
#   external/               — outside the host claude dir; symlink target
#                              fixtures live here to exercise dereferencing
setup_sync_test() {
	TEST_DIR="$(mktemp -d)"
	HOST_CLAUDE="${TEST_DIR}/home/.claude"
	SESSION_DIR="${TEST_DIR}/session"
	# shellcheck disable=SC2034  # read by test cases after setup_sync_test
	# returns; bash function-scope leaks into the caller without `local`.
	EXTERNAL_DIR="${TEST_DIR}/external"
	mkdir -p "${HOST_CLAUDE}/plugins" "${SESSION_DIR}" "${EXTERNAL_DIR}"
	export HOME="${TEST_DIR}/home"
	unset CONTEXT_MODE_DIR RIOTBOX_CONTEXT_MODE RIOTBOX_AGENT _CONTEXT_MODE_WIRED CONTEXT_MODE_DATA_DIR CONTEXT_MODE_PLATFORM
}

# Run sync-settings.sh against the staged fixtures. Stdout (bind-mount flags
# meant for the launcher) is captured per call so tests can inspect it; stderr
# (user-facing notices) is left attached.
run_sync() {
	: "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
	"${RIOTBOX_DIR}/agents/claude/sync-settings.sh" \
		"${HOST_CLAUDE}" \
		"${SESSION_DIR}"
}

# Put an `mv` shim first on PATH (export SHIM_DIR onto PATH for the run) that
# simulates a running container racing the sync: just before the rename onto
# ${SESSION_DIR}/<name>, it re-plants that entry as a symlink to <target>
# (or, when <target> is --dir, as an empty directory), then runs the real mv.
# It touches ${TEST_DIR}/shim-fired so a test can prove the race was exercised.
# Sets: SHIM_DIR
install_replant_shim() {
	local name="$1" target="$2" real_mv dest plant
	real_mv="$(command -v mv)"
	dest="$(printf '%q' "${SESSION_DIR}/${name}")"
	if [[ "${target}" == --dir ]]; then
		plant="mkdir -- ${dest}"
	else
		plant="ln -s -- $(printf '%q' "${target}") ${dest}"
	fi
	SHIM_DIR="${TEST_DIR}/shim"
	mkdir -p "${SHIM_DIR}"
	cat > "${SHIM_DIR}/mv" <<SHIM
#!/usr/bin/env bash
if [[ "\${!#}" == ${dest} ]]; then
	rm -rf -- ${dest}
	${plant}
	touch -- $(printf '%q' "${TEST_DIR}/shim-fired")
fi
exec $(printf '%q' "${real_mv}") "\$@"
SHIM
	chmod +x "${SHIM_DIR}/mv"
}
