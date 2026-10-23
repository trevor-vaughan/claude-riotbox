#!/usr/bin/env bash
set -euo pipefail
# Reset session cache (forces fresh skill/config copy).
# Required env: ROOT_DIR
# Arguments: [all] [force]

source "${ROOT_DIR}/scripts/mount-projects.sh"
source "${ROOT_DIR}/libexec/session-summary.sh"
resolve_data_roots
session_root="${RIOTBOX_DATA_DIR}"
state_root="${RIOTBOX_STATE_ROOT}"

confirm() {
	[[ "${force}" = true ]] && return 0
	read -rp "$1 [y/N] " a
	[[ "$a" =~ ^[Yy]$ ]]
}

all=false
force=false
for flag in "$@"; do
	case "${flag}" in
	all) all=true ;;
	force) force=true ;;
	*)
		echo "Unknown flag: ${flag}. Usage: riotbox session-reset [all] [force]" >&2
		exit 1
		;;
	esac
done

# is_session asks riotbox-core; without a usable binary every dir would read
# as "not a session". Fail once, saying why, before anything is decided.
# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
riotbox_core_require || exit 1

if [[ "${all}" = true ]]; then
	dirs=()
	if [[ -d "${session_root}" ]]; then
		for d in "${session_root}"/*/; do
			# Only sessions; see libexec/remove-session.sh.
			# shellcheck disable=SC2310 # a predicate designed for conditions
			is_session "${d%/}" "${state_root}/$(basename "${d}")" || continue
			dirs+=("${d%/}")
		done
	fi
	if [[ ${#dirs[@]} -eq 0 ]]; then
		echo "No session dirs found."
		exit 0
	fi
	echo "Sessions to remove:"
	for d in "${dirs[@]}"; do session_summary "${d}" "${state_root}/$(basename "${d}")"; done
	echo ""
	# shellcheck disable=SC2310  # confirm uses || for flow control — set -e suppression is intentional
	confirm "Remove ${#dirs[@]} session(s)?" || {
		echo "Aborted."
		exit 0
	}
	for d in "${dirs[@]}"; do
		key="$(basename "${d}")"
		# shellcheck disable=SC2310 # a predicate designed for conditions
		if ! valid_session_key "${key}"; then
			echo "ERROR: refusing to remove state for invalid session key '${key}'." >&2
			exit 1
		fi
	done
	for d in "${dirs[@]}"; do rm -rf -- "${d:?}" "${state_root:?}/$(basename "${d}")"; done
	echo "Removed ${#dirs[@]} session(s). Next run will create fresh copies."
else
	resolve_projects ""
	migrate_session_key
	# Defence in depth: resolve_projects already refuses /, but this guards rm -rf.
	if [[ "${RIOTBOX_SESSION_DIR%/}" = "${session_root%/}" ]]; then
		echo "ERROR: refusing to remove the RiotBox data dir '${RIOTBOX_SESSION_DIR}'." >&2
		exit 1
	fi
	# shellcheck disable=SC2310 # a predicate designed for conditions
	if ! is_session "${RIOTBOX_SESSION_DIR}" "${RIOTBOX_STATE_DIR}"; then
		# shellcheck disable=SC2312  # pwd never fails in a sane invocation
		echo "No session dir found for $(pwd)."
		exit 0
	fi
	echo "Session to remove:"
	session_summary "${RIOTBOX_SESSION_DIR}" "${RIOTBOX_STATE_DIR}"
	echo ""
	# shellcheck disable=SC2310  # confirm uses || for flow control — set -e suppression is intentional
	confirm "Remove this session?" || {
		echo "Aborted."
		exit 0
	}
	# Defence in depth: a bad key would aim rm at the state root.
	key="$(basename "${RIOTBOX_SESSION_DIR}")"
	# shellcheck disable=SC2310 # a predicate designed for conditions
	if ! valid_session_key "${key}"; then
		echo "ERROR: refusing to remove state for invalid session key '${key}'." >&2
		exit 1
	fi
	rm -rf -- "${RIOTBOX_SESSION_DIR}" "${RIOTBOX_STATE_DIR}"
	echo "Removed. Next run will create a fresh copy."
fi
