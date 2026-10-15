#!/usr/bin/env bash
# session-summary.sh — Print a human-readable summary of a session directory.
# Sourced by reset-session.sh, remove-session.sh and list-sessions.sh, after
# scripts/mount-projects.sh (session_projects, terminal_clean).
# Usage: session_summary <session_dir> <state_dir>
#        session_size <session_dir> <state_dir>

# Disk use of a session: its session dir plus its state dir, which may not
# exist (a session that never mounted any state). Prints du's human-readable
# total.
session_size() {
	local session_dir="$1" state_dir="$2"
	local -a dirs=("${session_dir}")
	if [[ -d "${state_dir}" ]]; then
		dirs+=("${state_dir}")
	fi
	# shellcheck disable=SC2312  # du|tail|cut is informational; non-zero is acceptable
	du -shc "${dirs[@]}" 2>/dev/null | tail -n 1 | cut -f1
}

session_summary() {
	local session_dir="$1" state_dir="$2"
	local last_used size
	# shellcheck disable=SC2312  # stat|cut is informational; non-zero is acceptable
	last_used="$(stat -c '%y' "${session_dir}" 2>/dev/null | cut -d. -f1)"
	size="$(session_size "${session_dir}" "${state_dir}")"

	# .projects is container-written (scripts/lib/session-state.sh): never
	# read through a link, and cleaned before printing.
	local projects cleaned
	# shellcheck disable=SC2310 # a refused .projects falls back to the key
	if projects="$(session_projects "${session_dir}")"; then
		cleaned="$(printf '%s\n' "${projects}" | terminal_clean line)"
		mapfile -t paths <<<"${cleaned}"
		for p in "${paths[@]}"; do echo "  ${p}"; done
		echo "    last used: ${last_used}, ${size}"
	else
		echo "  $(basename "${session_dir}")  (last used: ${last_used}, ${size})"
	fi
}
