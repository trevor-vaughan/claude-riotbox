#!/usr/bin/env bash
set -euo pipefail
# Retry the moves of legacy session state that failed for one session — see
# migrate_failed_state in scripts/lib/session-state.sh.
# Required env: ROOT_DIR
# Arguments: [project...] (default: the current directory), resolved as a
# launch resolves them, so a multi-project session needs every project.

source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_projects "$*"
migrate_session_key
if [[ ! -f "${RIOTBOX_SESSION_DIR}/.projects" ]]; then
	echo "No session dir found for ${PROJECT_SUMMARY}."
	# One member of a multi-project set names no session of its own.
	if [[ "${#PROJECT_DIRS[@]}" -eq 1 ]]; then
		hint="$(member_set_hint session-migrate "${PROJECT_DIRS[0]}" 2>&1)"
		if [[ -n "${hint}" ]]; then
			printf '%s\n' "${hint}" >&2
			exit 1
		fi
	fi
	exit 0
fi
migrate_failed_state "${RIOTBOX_SESSION_DIR}" "${RIOTBOX_STATE_DIR}"
