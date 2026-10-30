#!/usr/bin/env bash
set -euo pipefail
# Reset session cache (forces fresh skill/config copy).
# Required env: ROOT_DIR
# Arguments: [all] [force] [--older-than Nd] [--larger-than SIZE]
#            [--project-missing] [--pending-overlays]
# The options narrow `all` and are refused without it.

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

# path_is_surely_missing <absolute-path>
#   True only when the path does not exist AND the nearest existing ancestor is
#   a searchable directory. Under an ancestor we cannot search, "does not
#   exist" is only what the kernel lets us see.
path_is_surely_missing() {
	local path="$1" ancestor
	[[ "${path}" = /* ]] || return 1
	[[ ! -e "${path}" && ! -L "${path}" ]] || return 1
	ancestor="${path}"
	while [[ ! -e "${ancestor}" ]]; do
		ancestor="${ancestor%/*}"
		[[ -n "${ancestor}" ]] || ancestor=/
	done
	[[ -d "${ancestor}" && -x "${ancestor}" ]]
}

# all_projects_missing <session-dir> <state-dir>
#   True when the session records at least one project and every one is
#   surely missing. The list is the launch's record in the state dir (host
#   written); .projects, which the container can rewrite, is read only for a
#   legacy session that has no record. An unreadable or empty list, or a
#   project we cannot be sure about, is "cannot tell", not "missing". A
#   project on an unmounted filesystem counts as missing; the summary shown
#   before the prompt lists the paths.
all_projects_missing() {
	local raw path
	# shellcheck disable=SC2310 # no record is the legacy case, not an error
	if ! raw="$(recorded_projects "$2")"; then
		# Only a state dir that is genuinely absent, or searchable and without
		# an entry named "projects", is a legacy session. An unreadable or
		# empty record, or an unsearchable state dir, is "cannot tell":
		# falling back to the container-written .projects there would let it
		# decide. "Absent" must be sure: an unsearchable parent hides it.
		if [[ -e "$2" || -L "$2" ]]; then
			[[ -d "$2" && -x "$2" && ! -e "$2/projects" && ! -L "$2/projects" ]] || return 1
		else
			# shellcheck disable=SC2310 # a predicate designed for conditions
			path_is_surely_missing "$2" || return 1
		fi
		# shellcheck disable=SC2310 # a refused or empty list is "cannot tell"
		raw="$(session_projects "$1")" || return 1
	fi
	[[ -n "${raw}" ]] || return 1
	while IFS= read -r path; do
		# shellcheck disable=SC2310 # a predicate designed for conditions
		path_is_surely_missing "${path}" || return 1
	done <<<"${raw}"
	return 0
}

# matches_filters <session-dir> <state-dir>
#   True when the session satisfies every filter that was given; with none
#   given, every session matches. A tree find could not fully read is never
#   called stale (session_used_within_days exits 2).
matches_filters() {
	local session_dir="$1" state_dir="$2" rc=0 bytes
	local -a dirs=("${session_dir}")
	if [[ -d "${state_dir}" ]]; then
		dirs+=("${state_dir}")
	fi
	if [[ -n "${older_than}" ]]; then
		# shellcheck disable=SC2310 # exit status is captured on purpose; set -e suppression is intended
		session_used_within_days "${older_than}" "${dirs[@]}" || rc=$?
		[[ "${rc}" -eq 1 ]] || return 1
	fi
	if [[ -n "${larger_than}" ]]; then
		# shellcheck disable=SC2310 # exit status is captured on purpose; set -e suppression is intended
		bytes="$(session_bytes "${session_dir}" "${state_dir}")" || return 1
		[[ "${bytes}" -gt "${larger_than}" ]] || return 1
	fi
	if [[ "${project_missing}" = true ]]; then
		# shellcheck disable=SC2310 # a predicate designed for conditions
		all_projects_missing "${session_dir}" "${state_dir}" || return 1
	fi
	return 0
}

# report_skipped <count> <reason> [<line>...]
#   Print one "Skipped N session(s) <reason>:" notice with its lines, if any.
#   Lines are keys or engine messages; both can carry terminal controls, so
#   each is cleaned like session_summary's paths.
report_skipped() {
	local count="$1" reason="$2" line cleaned cleaned_line
	shift 2
	[[ "${count}" -gt 0 ]] || return 0
	echo "Skipped ${count} session(s) ${reason}:"
	for line in "$@"; do
		cleaned="$(terminal_clean line <<<"${line}")"
		while IFS= read -r cleaned_line; do
			echo "  ${cleaned_line}"
		done <<<"${cleaned}"
	done
}

# report_removal_outcome
#   Print what the removal loop skipped late and which removed entries were
#   links. Called on every exit of the loop, errors included, so a late skip
#   found before an error is not lost.
report_removal_outcome() {
	report_skipped "${#late_busy[@]}" "that became busy after the list was shown" "${late_busy[@]}"
	report_skipped "${#late_unanswered[@]}" "because the container engine did not answer after the list was shown" "${late_message}"
	report_skipped "${#late_overlay[@]}" "that gained pending overlay changes after the list was shown" "${late_overlay[@]}"
	local note
	for note in "${link_notes[@]}"; do
		echo "Note: ${note}"
	done
}

# check_busy <session-dir> <state-dir>
#   Ask the engine whether a live container can write the session. Returns 0
#   idle, 1 busy, 3 cannot tell (the engine's reason is left in busy_message),
#   2 for any other verdict (an error is printed). Used when the list is
#   built and again just before each removal: the prompt can wait.
check_busy() {
	local rc=0
	busy_message="$("${RIOTBOX_CORE}" session-busy --engine "${CONTAINER_CMD:-podman}" \
		--lib-dir "${ROOT_DIR}/scripts/lib" -- "$1" "$2" 2>&1 >/dev/null)" || rc=$?
	case "${rc}" in
	0 | 1 | 3) return "${rc}" ;;
	*)
		echo "ERROR: riotbox-core session-busy failed (exit ${rc}) for ${1##*/}: ${busy_message}" >&2
		return 2
		;;
	esac
}

# remove_session <session-dir> <state-dir>
#   Remove a session so that a failure at any point leaves something the next
#   reset can still find: reset only walks the data root and is_session needs
#   either .projects in the session dir or the launch record <state-dir>/projects.
#   So the contents go first (every entry but the markers, dot names
#   included), and the markers and the two directories only once that
#   succeeded. A link is only unlinked, never followed, and its target's
#   markers are not touched. On failure returns 1 with the path that still
#   holds data in remains.
remove_session() {
	local d="$1" s="$2" s_real=false d_real=false
	remains=""
	[[ -d "${s}" && ! -L "${s}" ]] && s_real=true
	[[ -d "${d}" && ! -L "${d}" ]] && d_real=true
	if [[ "${s_real}" = true ]]; then
		find "${s}" -mindepth 1 -maxdepth 1 ! -name projects -exec rm -rf -- {} + || {
			remains="${s}"
			return 1
		}
	fi
	if [[ "${d_real}" = true ]]; then
		find "${d}" -mindepth 1 -maxdepth 1 ! -name .projects -exec rm -rf -- {} + || {
			remains="${d}"
			return 1
		}
	fi
	# Markers last. The launch record goes before .projects: until .projects
	# is gone the session dir still makes it a session.
	if [[ "${s_real}" = true ]]; then
		rm -rf -- "${s}/projects" || {
			remains="${s}"
			return 1
		}
	elif [[ -L "${s}" ]]; then
		rm -f -- "${s}" || {
			remains="${s}"
			return 1
		}
	fi
	if [[ "${d_real}" = true ]]; then
		if ! { rm -rf -- "${d}/.projects" && rmdir -- "${d}"; }; then
			remains="${d}"
			return 1
		fi
	else
		rm -f -- "${d}" || {
			remains="${d}"
			return 1
		}
	fi
	if [[ "${s_real}" = true ]]; then
		rmdir -- "${s}" || {
			remains="${s}"
			return 1
		}
	fi
}

all=false
force=false
older_than=""
larger_than=""
project_missing=false
pending_overlays=false
filter_flags=()
usage_line="Usage: riotbox session-reset [all] [force] [--older-than Nd] [--larger-than SIZE] [--project-missing] [--pending-overlays]"
while [[ $# -gt 0 ]]; do
	case "$1" in
	all) all=true ;;
	force) force=true ;;
	--older-than)
		if [[ -n "${older_than}" ]]; then
			echo "ERROR: --older-than given twice." >&2
			exit 1
		fi
		# At most 999999 days keeps days*86400 far inside bash's 64-bit arithmetic.
		if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]{0,5}d$ ]]; then
			echo "ERROR: --older-than needs a number of days from 1 to 999999, like 30d." >&2
			exit 1
		fi
		older_than="${2%d}"
		filter_flags+=("$1")
		shift
		;;
	--larger-than)
		if [[ -n "${larger_than}" ]]; then
			echo "ERROR: --larger-than given twice." >&2
			exit 1
		fi
		# numfmt alone accepts surrounding whitespace and negatives, and passes a
		# bare fraction (1.5) through unchanged. Require a leading digit and no
		# whitespace, then an integer result under 10^18 bytes (safe for bash
		# arithmetic). A fraction with a suffix (1.5K) is accepted and rounded up
		# by numfmt; a bare fraction fails the integer check. LC_ALL=C pins the
		# decimal separator and digit classes.
		if [[ $# -lt 2 || ! "$2" =~ ^[0-9][^[:space:]]*$ ]] ||
			! larger_than="$(LC_ALL=C numfmt --from=iec -- "$2" 2>/dev/null)" ||
			[[ ! "${larger_than}" =~ ^[0-9]{1,18}$ ]]; then
			echo "ERROR: --larger-than needs a size, like 500M or 1G." >&2
			exit 1
		fi
		filter_flags+=("$1")
		shift
		;;
	--project-missing)
		project_missing=true
		filter_flags+=("$1")
		;;
	--pending-overlays)
		pending_overlays=true
		filter_flags+=("$1")
		;;
	*)
		echo "Unknown flag: $1. ${usage_line}" >&2
		exit 1
		;;
	esac
	shift
done
if [[ "${all}" != true && ${#filter_flags[@]} -gt 0 ]]; then
	echo "ERROR: ${filter_flags[0]} requires all. ${usage_line}" >&2
	exit 1
fi

# is_session asks riotbox-core; without a usable binary every dir would read
# as "not a session". Fail once, saying why, before anything is decided.
# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
riotbox_core_require || exit 1

if [[ "${all}" = true ]]; then
	dirs=()
	states=()
	skipped_invalid=()
	skipped_overlay=()
	skipped_busy=()
	skipped_unanswered=()
	engine_message=""
	if [[ -d "${session_root}" ]]; then
		# dotglob: a multi-project session key starts with the first
		# project's basename, so ".dotfiles" gives a key that starts with a dot.
		shopt -s dotglob
		for d in "${session_root}"/*/; do
			# Not basename: it strips trailing newlines, so a dir named "<A>\n"
			# would be paired with session A's state.
			d="${d%/}"
			key="${d##*/}"
			state_dir="${state_root}/${key}"
			# Only sessions; see libexec/remove-session.sh.
			# shellcheck disable=SC2310 # a predicate designed for conditions
			is_session "${d}" "${state_dir}" || continue
			# A link is not skipped: rm unlinks it and never follows it.
			# shellcheck disable=SC2310 # a predicate designed for conditions
			if ! valid_session_key "${key}" || { [[ -e "${state_dir}" || -L "${state_dir}" ]] && [[ ! -d "${state_dir}" ]]; }; then
				skipped_invalid+=("$(quote_words "${key}")")
				continue
			fi
			# The filters come first: they are cheap, and the engine below is
			# asked only about sessions that would otherwise be removed.
			# shellcheck disable=SC2310 # a predicate designed for conditions
			matches_filters "${d}" "${state_dir}" || continue
			# shellcheck disable=SC2310 # a predicate designed for conditions
			if [[ "${pending_overlays}" != true ]] && overlay_state_pending "${state_dir}"; then
				skipped_overlay+=("$(quote_words "${key}")")
				continue
			fi
			# A live container is never overridden: deleting a running
			# session's databases mid-write loses data.
			busy_rc=0
			# shellcheck disable=SC2310 # exit status is captured on purpose; set -e suppression is intended
			check_busy "${d}" "${state_dir}" || busy_rc=$?
			case "${busy_rc}" in
			0) ;;
			1)
				skipped_busy+=("$(quote_words "${key}")")
				continue
				;;
			3)
				skipped_unanswered+=("$(quote_words "${key}")")
				engine_message="${engine_message:-${busy_message}}"
				continue
				;;
			*) exit 1 ;;
			esac
			dirs+=("${d}")
			states+=("${state_dir}")
		done
	fi
	report_skipped "${#skipped_invalid[@]}" "with an invalid name or a state path that is not a directory" "${skipped_invalid[@]}"
	report_skipped "${#skipped_overlay[@]}" "with pending overlay changes (use --pending-overlays to include them)" "${skipped_overlay[@]}"
	report_skipped "${#skipped_busy[@]}" "with a running container" "${skipped_busy[@]}"
	report_skipped "${#skipped_unanswered[@]}" "because the container engine did not answer" "${engine_message}"
	if [[ ${#dirs[@]} -eq 0 ]]; then
		echo "No sessions match."
		exit 0
	fi
	echo "Sessions to remove:"
	for i in "${!dirs[@]}"; do session_summary "${dirs[i]}" "${states[i]}"; done
	echo ""
	# shellcheck disable=SC2310  # confirm uses || for flow control — set -e suppression is intentional
	confirm "Remove ${#dirs[@]} session(s)?" || {
		echo "Aborted."
		exit 0
	}
	# The prompt can wait minutes: what was safe when the list was built is
	# checked again, session by session, just before its rm -rf. A session
	# that is now busy, or whose state cannot be vouched for, stays.
	removed=0
	late_busy=()
	late_unanswered=()
	late_overlay=()
	late_message=""
	link_notes=()
	for i in "${!dirs[@]}"; do
		d="${dirs[i]}"
		state_dir="${states[i]}"
		key="${d##*/}"
		# Defence in depth: a bad key would aim rm at the state root.
		# shellcheck disable=SC2310 # a predicate designed for conditions
		if ! valid_session_key "${key}"; then
			echo "ERROR: refusing to remove state for invalid session key '${key}'." >&2
			exit 1
		fi
		busy_rc=0
		# shellcheck disable=SC2310 # exit status is captured on purpose; set -e suppression is intended
		check_busy "${d}" "${state_dir}" || busy_rc=$?
		case "${busy_rc}" in
		0) ;;
		1)
			late_busy+=("$(quote_words "${key}")")
			continue
			;;
		3)
			late_unanswered+=("$(quote_words "${key}")")
			late_message="${late_message:-${busy_message}}"
			continue
			;;
		*)
			report_removal_outcome
			echo "Removed ${removed} session(s) before the error; the rest were left in place." >&2
			exit 1
			;;
		esac
		# shellcheck disable=SC2310 # a predicate designed for conditions
		if [[ "${pending_overlays}" != true ]] && overlay_state_pending "${state_dir}"; then
			late_overlay+=("$(quote_words "${key}")")
			continue
		fi
		link_target=""
		if [[ -L "${d}" ]]; then
			link_target="$(readlink -- "${d}")"
		fi
		# shellcheck disable=SC2310 # a predicate designed for conditions
		if ! remove_session "${d}" "${state_dir}"; then
			quoted_key="$(quote_words "${key}")"
			quoted_remains="$(quote_words "${remains}")"
			echo "ERROR: could not fully remove session ${quoted_key}; what remains is under ${quoted_remains}." >&2
			echo "To finish by hand: rm -rf -- ${quoted_remains}" >&2
			report_removal_outcome
			echo "Removed ${removed} session(s) before the error; the rest were left in place." >&2
			exit 1
		fi
		if [[ -n "${link_target}" ]]; then
			quoted_key="$(quote_words "${key}")"
			quoted_target="$(quote_words "${link_target}")"
			link_notes+=("${quoted_key} was a symlink to ${quoted_target}; only the link was removed, its target was left in place.")
		fi
		removed=$((removed + 1))
	done
	report_removal_outcome
	if [[ "${removed}" -gt 0 ]]; then
		echo "Removed ${removed} session(s). Next run will create fresh copies."
	else
		echo "Removed 0 session(s)."
	fi
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
