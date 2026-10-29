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
	local session_dir="$1" state_dir="$2" out last
	local -a dirs=("${session_dir}")
	if [[ -d "${state_dir}" ]]; then
		dirs+=("${state_dir}")
	fi
	# du exits non-zero for an unreadable entry but still prints a total that
	# merely undercounts it; this is display only, so a partial count is fine.
	# Its status must not escape: under `set -e -o pipefail` it would abort
	# session-reset right after "Sessions to remove:".
	out="$(du -shc "${dirs[@]}" 2>/dev/null)" || true
	# The last line is the grand total: "<size><TAB>total".
	last="${out##*$'\n'}"
	echo "${last%%$'\t'*}"
}

# session_last_used <session_dir> <state_dir>
#   Print the newest modification time anywhere under the session dir and its
#   state dir (which may not exist) as "YYYY-MM-DD HH:MM:SS", or nothing when
#   neither can be read. A directory's own mtime changes only when an entry
#   directly inside it is added or removed, so it says little about when the
#   session was used. Links are not followed: one planted by a container
#   cannot steer the walk outside the session.
#   Display only: never use this for a delete decision.
session_last_used() {
	local -a dirs=("$1")
	local times newest
	if [[ -d "$2" ]]; then
		dirs+=("$2")
	fi
	# An unreadable subtree makes find exit non-zero but it still prints what
	# it could read; a partial answer is better than none for a display value.
	# The filters never use this function: see session_used_within_days.
	times="$(find "${dirs[@]}" -printf '%T@\n' 2>/dev/null)" || true
	[[ -n "${times}" ]] || return 0
	newest="$(awk '$1 > m { m = $1 } END { printf "%d", m }' <<<"${times}")"
	date -d "@${newest}" '+%Y-%m-%d %H:%M:%S'
}

# session_used_within_days <days> <abs-dir>...
#   <days> must be a non-negative integer and every dir an absolute path (a
#   leading "-" would be read by find as an option and relative paths depend
#   on the cwd), and at least one dir is required; anything else exits 2.
#   Exit 0 when anything under the dirs was modified in the last <days> days,
#   1 when nothing was, 2 when find hit an error and found nothing recent: an
#   unreadable subtree may hold the recent file, so "cannot tell" must never
#   read as "stale". find stops at the first recent file, so an active session
#   costs a few milliseconds.
session_used_within_days() {
	local days="$1" hit rc=0
	shift
	[[ "${days}" =~ ^[0-9]+$ && $# -gt 0 ]] || return 2
	local dir
	for dir in "$@"; do
		[[ "${dir}" == /* ]] || return 2
	done
	hit="$(find "$@" -newermt "${days} days ago" -print -quit 2>/dev/null)" || rc=$?
	if [[ -n "${hit}" ]]; then
		return 0
	fi
	if [[ "${rc}" -eq 0 ]]; then
		return 1
	fi
	return 2
}

# session_bytes <session_dir> <state_dir>
#   Print the disk use of the session dir plus its state dir (which may not
#   exist) in bytes, on the same basis as session_size's du (GNU du: -B1).
#   du exits non-zero for an unreadable entry but still prints a total that
#   merely undercounts it. Its status is ignored so a caller running under
#   `set -e -o pipefail` is not aborted. The only comparison on this value is
#   "larger than", where an undercount can only under-select: the safe side.
session_bytes() {
	local -a dirs=("$1")
	local out total
	if [[ -d "$2" ]]; then
		dirs+=("$2")
	fi
	out="$(du -sc -B1 "${dirs[@]}" 2>/dev/null)" || true
	total="${out##*$'\n'}"
	total="${total%%$'\t'*}"
	[[ "${total}" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "${total}"
}

session_summary() {
	local session_dir="$1" state_dir="$2"
	local last_used size
	last_used="$(session_last_used "${session_dir}" "${state_dir}")"
	last_used="${last_used:-unknown}"
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
