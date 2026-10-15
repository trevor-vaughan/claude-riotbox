#!/usr/bin/env bash
# Shared helpers for tests/session-state.venom.yml.
#
# Each case stages a fake host for scripts/mount-projects.sh plus a "victim"
# directory that stands for any host path a planted symlink could name. A
# helper that follows such a link writes into, moves, or deletes the victim,
# and assert_victim_intact sees it.
set -euo pipefail

# shellcheck source=tests/lib/engine-stub.sh
source "$(dirname "${BASH_SOURCE[0]}")/engine-stub.sh"

# setup_state_test
#   Sets: T (canonical temp root), PROJ (a canonical project dir), KEY (its
#         session key), SESSION (its session dir), STATE (its state dir),
#         VICTIM (holds one file, keep)
#   Exports: HOME (with an empty ~/.claude), XDG_DATA_HOME, XDG_CONFIG_HOME,
#            ROOT_DIR, and the stub engine's CONTAINER_CMD, STUB_RUNNING and
#            STUB_PS_CALLS (tests/lib/engine-stub.sh; nothing runs by default)
#   Unsets every RIOTBOX_* toggle a case does not set itself, so the ambient
#   environment cannot add or remove mounts.
setup_state_test() {
	: "${RIOTBOX_DIR:?RIOTBOX_DIR must be set by the caller}"
	T="$(mktemp -d)"
	T="$(cd "${T}" && pwd -P)"
	export HOME="${T}/home"
	unset CONTEXT_MODE_DIR RIOTBOX_CONTEXT_MODE RIOTBOX_AGENT _CONTEXT_MODE_WIRED CONTEXT_MODE_DATA_DIR CONTEXT_MODE_PLATFORM
	unset RIOTBOX_HEADROOM RIOTBOX_OVERLAY RIOTBOX_GIT_AI RIOTBOX_READONLY RIOTBOX_DRY_RUN RIOTBOX_FORCE_UNOWNED_MOUNTS PI_CODING_AGENT_DIR RIOTBOX_CONTEXT_LEDGER
	export XDG_DATA_HOME="${T}/data"
	export XDG_CONFIG_HOME="${T}/xdg"
	export ROOT_DIR="${RIOTBOX_DIR}"
	install_stub_engine "${T}"
	PROJ="${T}/proj"
	VICTIM="${T}/victim"
	mkdir -p "${HOME}/.claude" "${PROJ}" "${VICTIM}"
	echo precious >"${VICTIM}/keep"
	KEY="$(printf '%s\n' "${PROJ}" | sed 's|/|-|g; s|^-||')"
	# shellcheck disable=SC2034  # read by the test cases after this returns
	SESSION="${XDG_DATA_HOME}/riotbox/${KEY}"
	# shellcheck disable=SC2034  # read by the test cases after this returns
	STATE="${XDG_DATA_HOME}/riotbox-state/${KEY}"
}

# assert_victim_intact
#   Fail unless VICTIM still holds exactly its one seeded file, unchanged.
assert_victim_intact() {
	local content count
	content="$(cat "${VICTIM}/keep" 2>/dev/null || true)"
	if [[ "${content}" != "precious" ]]; then
		echo "FAIL: ${VICTIM}/keep was changed or removed"
		return 1
	fi
	count="$(find "${VICTIM}" -mindepth 1 | wc -l)"
	if [[ "${count}" -ne 1 ]]; then
		echo "FAIL: something was written into ${VICTIM}"
		find "${VICTIM}"
		return 1
	fi
}

# write_failing_mv_shim
#   Write ${T}/shim/mv: it fails, with "mv: simulated failure" on stderr and
#   a line appended to MV_LOG, when any argument equals one of the
#   space-separated paths in FAIL_MV at call time; otherwise it runs the real
#   mv. Put ${T}/shim first in PATH to use it.
#   Sets and exports: MV_LOG
write_failing_mv_shim() {
	export MV_LOG="${T}/mv.log"
	: >"${MV_LOG}"
	mkdir -p "${T}/shim"
	cat >"${T}/shim/mv" <<'SHIM'
#!/bin/sh
for a; do
	for f in ${FAIL_MV:-}; do
		if [ "$a" = "$f" ]; then
			echo "mv: simulated failure" >&2
			echo "$a" >>"${MV_LOG}"
			exit 1
		fi
	done
done
exec /usr/bin/mv "$@"
SHIM
	chmod +x "${T}/shim/mv"
}
