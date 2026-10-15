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
# Session keys come from the launch's own derivation in
# scripts/mount-projects.sh, never a re-derivation here.
# shellcheck source=scripts/mount-projects.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/mount-projects.sh"

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
	KEY="$(session_key "${PROJ}")"
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

# use_project <path>
#   Make <path> (created; canonical) the case's project: re-sets PROJ, KEY,
#   SESSION and STATE as setup_state_test does, plus the key an older
#   release gave it (legacy_session_key) and its two dirs under that key.
#   Sets: PROJ, KEY, SESSION, STATE, OLD_KEY, OLD_SESSION, OLD_STATE
use_project() {
	mkdir -p "$1"
	PROJ="$(cd "$1" && pwd -P)"
	KEY="$(session_key "${PROJ}")"
	OLD_KEY="$(legacy_session_key "${PROJ}")"
	# shellcheck disable=SC2034  # read by the test cases after this returns
	SESSION="${XDG_DATA_HOME}/riotbox/${KEY}"
	# shellcheck disable=SC2034  # read by the test cases after this returns
	STATE="${XDG_DATA_HOME}/riotbox-state/${KEY}"
	OLD_SESSION="${XDG_DATA_HOME}/riotbox/${OLD_KEY}"
	OLD_STATE="${XDG_DATA_HOME}/riotbox-state/${OLD_KEY}"
}

# make_old_session [record]
#   Lay out a session of PROJ under OLD_KEY as a release with a state dir
#   left it: .projects and a Claude copy in the session dir; git-ai, Pi
#   history, a pending overlay change and a full .migrated in the state dir.
#   With "record", also the host-only record (record_projects) naming PROJ.
make_old_session() {
	local -a names
	mkdir -p "${OLD_SESSION}/projects" "${OLD_STATE}/git-ai" "${OLD_STATE}/pi-agent/sessions" \
		"${OLD_STATE}/overlay/project/upper" "${OLD_STATE}/overlay/project/work"
	printf '%s\n' "${PROJ}" >"${OLD_SESSION}/.projects"
	echo '{"copy":true}' >"${OLD_SESSION}/settings.json"
	echo transcript >"${OLD_SESSION}/projects/t.jsonl"
	echo '{}' >"${OLD_STATE}/git-ai/config.json"
	echo history >"${OLD_STATE}/pi-agent/sessions/s.jsonl"
	echo change >"${OLD_STATE}/overlay/project/upper/f.txt"
	# shellcheck disable=SC2312 # printing a sourced array cannot fail
	mapfile -t names < <(printf '%s\n' "${SESSION_STATE_MIGRATIONS[@]%%:*}")
	printf '%s\n' "${names[@]}" >"${OLD_STATE}/.migrated"
	if [[ "${1:-}" == record ]]; then
		printf '%s\n' "${PROJ}" >"${OLD_STATE}/projects"
	fi
}

# assert_moved_to_new_key
#   Fail unless everything make_old_session laid out is now under KEY, with
#   its content intact, and nothing is left under OLD_KEY.
assert_moved_to_new_key() {
	if [[ -e "${OLD_SESSION}" || -L "${OLD_SESSION}" || -e "${OLD_STATE}" || -L "${OLD_STATE}" ]]; then
		echo "FAIL: something is left under the old key ${OLD_KEY}"
		return 1
	fi
	local pair file got
	for pair in "${SESSION}/settings.json|{\"copy\":true}" "${SESSION}/projects/t.jsonl|transcript" \
		"${STATE}/git-ai/config.json|{}" "${STATE}/pi-agent/sessions/s.jsonl|history" \
		"${STATE}/overlay/project/upper/f.txt|change"; do
		file="${pair%%|*}"
		got="$(cat -- "${file}" 2>/dev/null)" || got=""
		[[ "${got}" == "${pair#*|}" ]] || { echo "FAIL: ${file} did not move intact"; return 1; }
	done
	grep -qx overlay "${STATE}/.migrated" || { echo "FAIL: .migrated did not move"; return 1; }
}
