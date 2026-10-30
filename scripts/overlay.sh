#!/usr/bin/env bash
# scripts/overlay.sh — host-side fuse-overlayfs lifecycle for RiotBox sessions.
#
# Subcommands:
#   resolve  Resolve a project set to its overlay data directories (sourced).
#   list     List sessions with pending overlay data.
#   diff     Show overlay changes vs host project(s).
#   accept   Apply overlay changes to host project(s).
#   reject   Discard overlay changes.
#
# diff, accept and reject take the projects the session was launched with:
# none (the current directory), one, or every project of a multi-project
# session in any order, which resolves to the same session key as the
# launch, and must be the set that launch recorded (record_projects in
# scripts/mount-projects.sh; see _overlay_check_record). A set's overlays
# are handled one project at a time; see _overlay_each. Project paths are
# printed only from that host-only record, never from the session's
# container-written .projects.
#
# `resolve` is special: it is intended to be used via `source` from another
# bash script that needs the resolved variables, not via the dispatcher. It
# is documented here for completeness; subcommand dispatch covers the four
# user-facing verbs (list, diff, accept, reject).
#
# Exit status of `list`: 0 when it listed pending overlays, 1 when there are
# none, 2 when adopting overlay data an older RiotBox left in a session dir
# failed (so the listing would be incomplete).
#
# The upper directory is container-controlled: it is the session container's
# /mnt/overlay, so every name, file type and link in it is chosen by the
# session. accept and reject therefore refuse while any live container,
# labelled riotbox.session or not (_overlay_scan_sessions), has this overlay
# mounted read-write; other sessions on the same project do not
# block, and accept names them. accept applies a private snapshot of the
# upper, never follows a link in it or in the project, and validates every
# entry before the review and again after the confirmation (for safety;
# with the apply that costs roughly 25 ms per entry); see overlay accept below
# for exactly what that covers. diff only reads, so it runs
# regardless and says when the overlay can still change.
#
# See `scripts/overlay.sh help` for usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/mount-projects.sh
source "${SCRIPT_DIR}/mount-projects.sh"
# shellcheck source=scripts/lib/overlay-ignore.sh
source "${SCRIPT_DIR}/lib/overlay-ignore.sh"

# ─── overlay resolve ───────────────────────────────────────────────────────
# resolve_overlay <verb> [project...]
#   Resolve a project set, given as a launch takes it (no path: the current
#   directory; one path; or several, in any order), to its session's overlay
#   data. <verb> (diff, accept, reject) names the command in hints.
#   Sets these variables in the caller's scope (when sourced):
#     OVERLAY_SESSION_DIR  — the project set's session directory
#     OVERLAY_PROJECTS     — the resolved host project paths
#     OVERLAY_DIRS         — parallel to OVERLAY_PROJECTS: each project's
#                            overlay subdirectory (contains upper/ and
#                            work/), under the session's state dir; empty
#                            for a project of a set that has none
#     OVERLAY_PROJECT_DIR, OVERLAY_DIR — the first project and its overlay
resolve_overlay() {
	local verb="$1"
	shift
	if [[ $# -gt 1 ]]; then
		# shellcheck disable=SC2310 # it has already said why it failed
		_overlay_resolve_set "${verb}" "$@" || return 1
		return 0
	fi
	local project_path="${1:-$(pwd)}"

	# Resolve to absolute
	if [[ -d "${project_path}" ]]; then
		project_path="$(cd "${project_path}" && pwd)"
	else
		echo "ERROR: '${project_path}' is not a directory." >&2
		return 1
	fi

	# shellcheck disable=SC2034  # used by caller after sourcing
	OVERLAY_PROJECT_DIR="${project_path}"

	# Resolve to session dir
	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	resolve_projects "${project_path}" || return 1
	# shellcheck disable=SC2310 # it has already said why it failed
	migrate_session_key || return 1
	# shellcheck disable=SC2154 # RIOTBOX_SESSION_DIR is set by resolve_projects (sourced from mount-projects.sh)
	OVERLAY_SESSION_DIR="${RIOTBOX_SESSION_DIR}"

	if [[ ! -d "${OVERLAY_SESSION_DIR}" ]]; then
		echo "ERROR: No session found for '${project_path}'." >&2
		echo "Run 'riotbox session-list' to see available sessions." >&2
		member_set_hint "overlay-${verb}" "${PROJECT_DIRS[0]}"
		return 1
	fi
	# shellcheck disable=SC2310 # it has already said why it refused
	_overlay_check_record "${verb}" || return 1

	# Overlay data lives in the session's state dir. Run the session's
	# one-time migration (migrate_session_state), which adopts any that an
	# older RiotBox left inside the session dir, before looking for it.
	# shellcheck disable=SC2154,SC2310 # RIOTBOX_STATE_DIR is set by resolve_projects; a failed migration has already said why
	migrate_session_state "${OVERLAY_SESSION_DIR}" "${RIOTBOX_STATE_DIR}" || return 1

	# A single project's overlay is always overlay/project
	# (overlay_project_names); every release has named it so, and the
	# migration carries an older tree across unchanged. Anything else under
	# this key belongs to another set and is never looked for.
	# shellcheck disable=SC2034  # used by caller after sourcing
	OVERLAY_DIR="${RIOTBOX_STATE_DIR}/overlay/project"
	# reject also takes an upper a session left as a link or a file, which
	# it removes (_overlay_reject_one); nothing else would clear it.
	if [[ ! -d "${OVERLAY_DIR}/upper" ]] &&
		! { [[ "${verb}" == reject ]] && [[ -e "${OVERLAY_DIR}/upper" || -L "${OVERLAY_DIR}/upper" ]]; }; then
		echo "ERROR: No overlay data found for '${project_path}'." >&2
		echo "Run 'riotbox overlays' to see pending overlays." >&2
		member_set_hint "overlay-${verb}" "${PROJECT_DIRS[0]}"
		return 1
	fi
	OVERLAY_PROJECTS=("${OVERLAY_PROJECT_DIR}")
	OVERLAY_DIRS=("${OVERLAY_DIR}")
}

# _overlay_resolve_set <verb> <project>...
#   resolve_overlay for a set of two or more projects. The paths are joined
#   with spaces exactly as the launch joins RIOTBOX_PROJECTS (bin/riotbox),
#   so resolve_projects derives the same session key; it sorts the set, so
#   the order does not matter. Each project's overlay is found under the
#   name the launch mounted it with (overlay_project_names).
_overlay_resolve_set() {
	local verb="$1" i j listed
	shift
	# shellcheck disable=SC2310 # it has already said why it failed
	resolve_projects "$*" || return 1
	# shellcheck disable=SC2310 # it has already said why it failed
	migrate_session_key || return 1
	listed="$(printf ' %s' "${PROJECT_DIRS[@]}")"
	OVERLAY_SESSION_DIR="${RIOTBOX_SESSION_DIR}"
	if [[ ! -d "${OVERLAY_SESSION_DIR}" ]]; then
		echo "ERROR: No session found for the project set:${listed}" >&2
		echo "Run 'riotbox session-list' to see available sessions." >&2
		return 1
	fi

	overlay_project_names "${PROJECT_DIRS[@]}"
	for i in "${!OVERLAY_NAMES[@]}"; do
		for ((j = 0; j < i; j++)); do
			if [[ "${OVERLAY_NAMES[j]}" == "${OVERLAY_NAMES[i]}" ]]; then
				echo "ERROR: ${PROJECT_DIRS[j]} and ${PROJECT_DIRS[i]} share the directory name '${OVERLAY_NAMES[i]}'," >&2
				echo "       so overlay mode keeps both projects' changes in one overlay (overlay/${OVERLAY_NAMES[i]})," >&2
				echo "       which belongs to neither; the container engine also refuses to start such a set." >&2
				echo "       Nothing was changed." >&2
				return 1
			fi
		done
	done
	# shellcheck disable=SC2310 # it has already said why it refused
	_overlay_check_record "${verb}" || return 1
	# shellcheck disable=SC2310 # a failed migration has already said why
	migrate_session_state "${OVERLAY_SESSION_DIR}" "${RIOTBOX_STATE_DIR}" || return 1

	OVERLAY_PROJECTS=("${PROJECT_DIRS[@]}")
	OVERLAY_DIRS=()
	local found=""
	local upper
	for i in "${!OVERLAY_NAMES[@]}"; do
		upper="${RIOTBOX_STATE_DIR}/overlay/${OVERLAY_NAMES[i]}/upper"
		# As for one project: reject also takes a linked or file upper.
		if [[ -d "${upper}" ]] || { [[ "${verb}" == reject ]] && [[ -e "${upper}" || -L "${upper}" ]]; }; then
			OVERLAY_DIRS+=("${RIOTBOX_STATE_DIR}/overlay/${OVERLAY_NAMES[i]}")
			found=1
		else
			OVERLAY_DIRS+=("")
		fi
	done
	if [[ -z "${found}" ]]; then
		echo "ERROR: No overlay data found for the project set:${listed}" >&2
		echo "Run 'riotbox overlays' to see pending overlays." >&2
		return 1
	fi
	# shellcheck disable=SC2034  # used by the per-project functions
	OVERLAY_PROJECT_DIR="${OVERLAY_PROJECTS[0]}"
	# shellcheck disable=SC2034  # used by the per-project functions
	OVERLAY_DIR="${OVERLAY_DIRS[0]}"
}

# _overlay_check_record <verb>
#   Refuse, saying why, unless PROJECT_DIRS is the project set the launch
#   recorded for the resolved session (record_projects). Session keys are
#   unique per set (session_key), so this refuses only a state dir copied or
#   renamed by hand: its overlays must not be applied to directories they
#   were never made for. The container-written .projects
#   is never consulted. Without a record (the session was last launched by
#   an older RiotBox) only accept refuses: diff only reads, and reject only
#   discards the session's own data. Accept is not offered behind a prompt
#   instead: the paths it would show are the ones the user just typed, so
#   confirming them proves nothing, while one overlay-mode launch records
#   the set and, with changes pending, stops before starting a session.
_overlay_check_record() {
	local verb="$1" recorded
	local -a paths
	# shellcheck disable=SC2310 # no record is an answer, not an error
	if ! recorded="$(recorded_projects "${RIOTBOX_STATE_DIR}")"; then
		[[ "${verb}" == accept ]] || return 0
		echo "ERROR: no project set is recorded for this session: an older RiotBox last launched it." >&2
		echo "       overlay-accept applies overlays only to the projects their launch recorded." >&2
		echo "       Launch the set once in overlay mode to record it; while changes are pending," >&2
		echo "       that launch stops before starting a session:" >&2
		# shellcheck disable=SC2312 # quoting cannot fail
		echo "    RIOTBOX_OVERLAY=1 riotbox $(quote_words "${PROJECT_DIRS[@]}")" >&2
		echo "       Then run overlay-accept again. overlay-diff and overlay-reject work without it." >&2
		return 1
	fi
	# shellcheck disable=SC2310,SC2312 # a predicate designed for conditions; printf cannot fail
	if same_project_set "${recorded}" "$(printf '%s\n' "${PROJECT_DIRS[@]}")"; then
		return 0
	fi
	mapfile -t paths <<<"${recorded}"
	# shellcheck disable=SC2312 # quoting cannot fail
	{
		echo "ERROR: these projects are not the set this session was launched with."
		echo "       This session's overlays belong to the set its launch recorded:"
		printf '         %s\n' "$(quote_words "${paths[@]}")"
		echo "       given:"
		printf '         %s\n' "$(quote_words "${PROJECT_DIRS[@]}")"
		echo "       To act on this session, name the recorded set:"
		echo "    $(overlay_command "${verb}" "${paths[@]}")"
	} >&2
	return 1
}

# Check if an overlay dir has any actual changes. Derived caches (.codegraph)
# are not changes — see scripts/lib/overlay-ignore.sh.
overlay_has_changes() {
	local overlay_dir="$1"
	# shellcheck disable=SC2310 # overlay_upper_has_changes is designed to be tested in conditions
	overlay_upper_has_changes "${overlay_dir}/upper"
}

# _overlay_entries <dir> [find-tests...]
#   Print every entry below <dir>, filtered by the optional find tests, as a
#   NUL-terminated <dir>-relative path, sorted bytewise so a directory comes
#   before its contents. NUL, because the names are container-chosen and may
#   hold newlines.
_overlay_entries() {
	local dir="$1"
	shift
	find "${dir}" -mindepth 1 "$@" -printf '%P\0' | LC_ALL=C sort -z
}

# _overlay_name_unsafe <name>
#   Exit 0 when <name> holds a byte sequence a terminal may act on: a C0
#   control (newline included), DEL, a UTF-8 C1 control (U+0080-U+009F) or a
#   bidi control (U+202A-U+202E, U+2066-U+2069). Matched as bytes under
#   LC_ALL=C, so the answer does not depend on the caller's locale.
_overlay_name_unsafe() {
	local LC_ALL=C
	[[ "$1" == *[$'\x01'-$'\x1f'$'\x7f']* ]] ||
		[[ "$1" == *$'\xc2'[$'\x80'-$'\x9f']* ]] ||
		[[ "$1" == *$'\xe2\x80'[$'\xaa'-$'\xae']* ]] ||
		[[ "$1" == *$'\xe2\x81'[$'\xa6'-$'\xa9']* ]]
}

# _overlay_entry_kind <path>
#   Print what an upper entry means, judged on the entry itself (lstat),
#   never on what a link points at:
#     opaque       regular file .wh..wh..opq: its directory replaces the
#                  project's
#     whiteout     regular file .wh.<name>: deletes <name>
#     devwhiteout  character device 0/0, the kernel overlayfs whiteout:
#                  deletes the entry's own name
#     link, dir, file
#     unsupported  anything else: a FIFO, socket, block device, any other
#                  character device, or a .wh.* name that is not a regular
#                  file
#   Uses the external `stat`, so a test can stand in for a device it has no
#   privilege to mknod.
_overlay_entry_kind() {
	local path="$1" info base
	info="$(stat -c '%F/%t/%T' -- "${path}")" || return 1
	base="${path##*/}"
	case "${info%%/*}" in
	"regular file" | "regular empty file")
		if [[ "${base}" == ".wh..wh..opq" ]]; then
			echo opaque
		elif [[ "${base}" == .wh.* ]]; then
			echo whiteout
		else
			echo file
		fi
		;;
	"symbolic link" | directory)
		if [[ "${base}" == .wh.* ]]; then
			echo unsupported
		elif [[ "${info%%/*}" == directory ]]; then
			echo dir
		else
			echo link
		fi
		;;
	"character special file")
		if [[ "${info#*/}" == "0/0" ]]; then
			echo devwhiteout
		else
			echo unsupported
		fi
		;;
	*) echo unsupported ;;
	esac
}

# _overlay_scan_sessions
#   Classify the read-write mounts of every live container (riotbox-core
#   overlay-scan, with the engine in CONTAINER_CMD, default podman). Sets
#     _OVERLAY_HOLDERS  names of containers with a read-write mount reaching
#                       OVERLAY_DIR: at or below it for any container, and
#                       also above it for a riotbox.session-labelled one.
#                       They run on this overlay, and block accept and
#                       reject
#     _OVERLAY_SHARERS  "<name> <source>" per other read-write mount
#                       overlapping OVERLAY_PROJECT_DIR either way, labelled
#                       or not: other sessions on the project, which RiotBox
#                       supports running side by side, or a toolbox with
#                       $HOME mounted, any of which can change the project
#                       during the apply; they only warn
#   Returns non-zero when the engine cannot list or inspect them.
#   Needs OVERLAY_DIR and OVERLAY_PROJECT_DIR (resolve_overlay). See
#   docs/dev/riotbox-core.md for the verb's records.
_overlay_scan_sessions() {
	local i
	local -a fields=()
	_OVERLAY_HOLDERS=()
	_OVERLAY_SHARERS=()
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	# The records hold NULs, which a command substitution drops, so they are
	# read through a process substitution, and its exit status through wait.
	# shellcheck disable=SC2312 # the status is checked through wait below
	mapfile -d '' -t fields < <("${RIOTBOX_CORE}" overlay-scan --lib-dir "${_RIOTBOX_CORE_ROOT}/scripts/lib" \
		--engine "${CONTAINER_CMD:-podman}" -- "${OVERLAY_DIR}" "${OVERLAY_PROJECT_DIR}")
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	wait "$!" || return 1
	[[ $((${#fields[@]} % 2)) -eq 0 ]] || return 1
	for ((i = 0; i < ${#fields[@]}; i += 2)); do
		case "${fields[i]}" in
		holder) _OVERLAY_HOLDERS+=("${fields[i + 1]}") ;;
		sharer) _OVERLAY_SHARERS+=("${fields[i + 1]}") ;;
		*) return 1 ;;
		esac
	done
}

# _overlay_refuse_if_running <verb> [warn]
#   Return non-zero, saying why, unless the engine confirms that no live
#   container can write this overlay (_overlay_scan_sessions). Fails closed: an
#   engine that cannot answer is a refusal, because such a container can
#   still change the overlay. Other sessions on the project do not block;
#   with "warn" they are named, since they can change the project.
_overlay_refuse_if_running() {
	local verb="$1" warn="${2:-}" sharer
	# shellcheck disable=SC2310 # the engine's status is the point of the test
	if ! _overlay_scan_sessions; then
		echo "ERROR: could not ask '${CONTAINER_CMD:-podman}' which containers use the overlay of ${OVERLAY_PROJECT_DIR}." >&2
		echo "       overlay-${verb} refuses while it cannot tell: a session running on the overlay can still change it." >&2
		echo "       Make sure the container engine works (and that session has exited), then retry." >&2
		return 1
	fi
	if [[ "${#_OVERLAY_HOLDERS[@]}" -gt 0 ]]; then
		echo "ERROR: container ${_OVERLAY_HOLDERS[*]} mounts the overlay of ${OVERLAY_PROJECT_DIR} read-write and is still running." >&2
		echo "       It can still change the overlay. Stop that container (exit its session), then run overlay-${verb} again." >&2
		return 1
	fi
	if [[ -n "${warn}" ]] && [[ "${#_OVERLAY_SHARERS[@]}" -gt 0 ]]; then
		for sharer in "${_OVERLAY_SHARERS[@]}"; do
			echo "Warning: container ${sharer%% *} has ${sharer#* } mounted read-write, overlapping ${OVERLAY_PROJECT_DIR}." >&2
		done
		echo "         overlay-${verb} checks the project again after you confirm, but changes made while" >&2
		echo "         the apply itself runs are not detected." >&2
	fi
}

# _overlay_check_dest <project> <rel>
#   Fail, saying why, unless <project>/<rel> is reached through directories
#   inside <project> (already canonical): the nearest existing ancestor of its
#   parent must resolve, links and all, to a directory inside the project.
#   The final component is not checked here; the caller decides what an
#   existing entry there means.
_overlay_check_dest() {
	local project="$1" rel="$2" probe=. resolved
	if [[ "${rel}" == */* ]]; then
		probe="${rel%/*}"
	fi
	while [[ "${probe}" != . ]] && [[ ! -e "${project}/${probe}" ]] && [[ ! -L "${project}/${probe}" ]]; do
		if [[ "${probe}" == */* ]]; then
			probe="${probe%/*}"
		else
			probe=.
		fi
	done
	if resolved="$(realpath -e -- "${project}/${probe}" 2>/dev/null)" && [[ -d "${resolved}" ]] &&
		{ [[ "${resolved}" == "${project}" ]] || [[ "${resolved}" == "${project}/"* ]]; }; then
		return 0
	fi
	echo "ERROR: ${rel} cannot be applied: ${probe} in the project resolves outside the project or is not a directory." >&2
	echo "       Nothing was applied." >&2
	return 1
}

# ─── overlay list ──────────────────────────────────────────────────────────
# List sessions with pending overlay data.
# Exit 0 if overlays exist, 1 if none, 2 if adopting legacy overlay data failed
# or riotbox-core is missing or does not match VERSION (checked even when
# there is no session).
overlay_list() {
	resolve_data_roots

	# Run each session's one-time migration (migrate_session_state), which
	# adopts the overlay data and other state an older RiotBox left inside a
	# session dir, so an upgrade does not hide pending changes until that
	# project's next launch. riotbox-core migrate-all does it under the state
	# root's lock, which the key move (migrate_session_key) holds while it
	# renames a session: an old-key session is then either not moved yet or
	# gone, never half moved. See internal/migrate (AllSessions).
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 2
	"${RIOTBOX_CORE}" migrate-all --lib-dir "${_RIOTBOX_CORE_ROOT}/scripts/lib" -- "${RIOTBOX_DATA_DIR}" "${RIOTBOX_STATE_ROOT}" || return 2

	if [[ ! -d "${RIOTBOX_STATE_ROOT}" ]]; then
		echo "No pending overlays."
		return 1
	fi

	local found=0
	local state_dir name overlay_base overlay_dir
	local -a project_paths raw_paths commands overlay_dirs
	local -A project_of
	local projects last_modified local_added local_deleted size rel kind i verb

	for state_dir in "${RIOTBOX_STATE_ROOT}"/*/; do
		[[ -d "${state_dir}" ]] || continue
		name="$(basename "${state_dir}")"

		overlay_base="${state_dir}overlay"
		[[ -d "${overlay_base}" ]] || continue

		# Project paths come only from the set the launch recorded in the
		# host-only state dir (record_projects), never from the session's
		# container-written .projects: a session could name any directory
		# there, and a key cannot be decoded back to its set. Paths are cleaned for
		# printing; the commands quote them as recorded (overlay_command).
		# Each overlay is shown with the project it was mounted for
		# (overlay_project_names).
		raw_paths=() commands=() project_of=()
		# shellcheck disable=SC2310 # a session without a record shows as unknown
		if projects="$(recorded_projects "${state_dir%/}")"; then
			mapfile -t raw_paths <<<"${projects}"
			projects="$(printf '%s\n' "${projects}" | terminal_clean line)"
			mapfile -t project_paths <<<"${projects}"
			overlay_project_names "${raw_paths[@]}"
			for i in "${!OVERLAY_NAMES[@]}"; do
				[[ -n "${project_of["${OVERLAY_NAMES[i]}"]+set}" ]] ||
					project_of["${OVERLAY_NAMES[i]}"]="${project_paths[i]}"
			done
			for verb in diff accept reject; do
				commands+=("$(overlay_command "${verb}" "${raw_paths[@]}")")
			done
		else
			project_paths=("(unknown) — launch this project set once with this release")
		fi

		# dotglob: an overlay folder is named after its project's basename,
		# so ".dotfiles" is an overlay like any other. nullglob: an empty
		# overlay/ expands to nothing.
		shopt -s dotglob nullglob
		overlay_dirs=("${overlay_base}"/*/)
		shopt -u dotglob nullglob

		# Check each overlay subdir for non-empty upper
		for overlay_dir in "${overlay_dirs[@]}"; do
			[[ -d "${overlay_dir}/upper" ]] || continue
			# shellcheck disable=SC2310 # designed to be tested in conditions
			overlay_upper_has_changes "${overlay_dir}/upper" || continue

			# This overlay has changes
			if [[ "${found}" -eq 0 ]]; then
				echo "Pending overlays:"
				echo ""
			fi
			found=$((found + 1))

			# Timestamp from overlay dir mtime
			last_modified="$(stat -c '%y' "${overlay_dir}/upper" 2>/dev/null | cut -d. -f1)"

			# Count changes in upper dir
			local_added=0 local_deleted=0
			# shellcheck disable=SC2312 # walker failure means no entries; loop just won't execute
			while IFS= read -r -d '' rel; do
				# shellcheck disable=SC2310 # designed to be tested in conditions
				overlay_path_ignored "${rel}" && continue
				# shellcheck disable=SC2310 # an entry that vanished mid-listing is not counted
				kind="$(_overlay_entry_kind "${overlay_dir}upper/${rel}")" || continue
				case "${kind}" in
				opaque | whiteout | devwhiteout) local_deleted=$((local_deleted + 1)) ;;
				*) local_added=$((local_added + 1)) ;;
				esac
			done < <(_overlay_entries "${overlay_dir}upper" -not -type d)

			size="$(du -sh "${overlay_dir}" 2>/dev/null | cut -f1)"

			overlay_dir="${overlay_dir%/}"
			echo "  Project  ${project_of["${overlay_dir##*/}"]:-${project_paths[0]}}"
			echo "  Changed  ${last_modified}"
			echo "  Files    ${local_added} added/modified, ${local_deleted} deleted  (${size} on disk)"
			echo "  Key      ${name}"
			if [[ "${#commands[@]}" -gt 0 ]]; then
				echo "  Review   ${commands[0]}"
				echo "  Apply    ${commands[1]}"
				echo "  Discard  ${commands[2]}"
			fi
			echo ""
		done

		# A snapshot an overlay-accept never put back (it was killed, or is
		# still running) holds reviewed-but-unapplied changes.
		for overlay_dir in "${overlay_dirs[@]}"; do
			overlay_dir="${overlay_dir%/}"
			# shellcheck disable=SC2310 # designed to be tested in conditions
			overlay_is_stranded_snapshot "${overlay_dir}" || continue
			if [[ "${found}" -eq 0 ]]; then
				echo "Pending overlays:"
				echo ""
			fi
			found=$((found + 1))
			rel="${overlay_dir##*/}"
			echo "  Project  ${project_of["${rel%.accepting.*}"]:-${project_paths[0]}}"
			echo "  Status   interrupted (or still running) overlay-accept; changes kept in ${overlay_dir}"
			# shellcheck disable=SC2312 # quoting cannot fail
			echo "  Recover  mv -T $(quote_words "${overlay_dir}" "${overlay_dir%.accepting.*}/upper")"
			echo "  Key      ${name}"
			if [[ "${#commands[@]}" -gt 0 ]]; then
				echo "  Review   ${commands[0]}"
			fi
			echo ""
		done
	done

	if [[ "${found}" -eq 0 ]]; then
		echo "No pending overlays."
		return 1
	fi
	return 0
}

# ─── per-project runs ──────────────────────────────────────────────────────
# _overlay_each <done-label> <function> [args...]
#   Run <function>, which acts on OVERLAY_PROJECT_DIR and OVERLAY_DIR, for
#   each project resolve_overlay found. A single project is run directly, as
#   it always was. For a set, each project runs in turn in its own subshell
#   with errexit on, so a failure or refusal ends that project's run only:
#   every project gets the full checks, prompt and apply of its own, and none
#   is left half-handled because another failed. A project without overlay
#   data is skipped; an interrupt (status 128 or more) stops the rest and
#   becomes the return status. With a <done-label> ("applied", "discarded")
#   a line per project handled so far follows, judged on its overlay
#   afterwards: changes still there mean it was declined (status 0), failed
#   or interrupted; none before the run means it was unchanged. Otherwise
#   returns 1 when any project failed.
_overlay_each() {
	local label="$1" fn="$2" i rc status=0 errexit="" outcome note changed
	shift 2
	if [[ "${#OVERLAY_PROJECTS[@]}" -eq 1 ]]; then
		"${fn}" "$@"
		return
	fi
	local -a results=()
	for i in "${!OVERLAY_PROJECTS[@]}"; do
		OVERLAY_PROJECT_DIR="${OVERLAY_PROJECTS[i]}"
		OVERLAY_DIR="${OVERLAY_DIRS[i]}"
		if [[ "${i}" -gt 0 ]]; then
			echo ""
		fi
		if [[ -z "${OVERLAY_DIR}" ]]; then
			echo "No overlay data for ${OVERLAY_PROJECT_DIR}; skipped."
			results+=("$(printf '  %-11s %s  (no overlay data)' skipped "${OVERLAY_PROJECT_DIR}")")
			continue
		fi
		changed=""
		# shellcheck disable=SC2310 # overlay_has_changes is designed to be tested in conditions
		if overlay_has_changes "${OVERLAY_DIR}"; then
			changed=1
		fi
		[[ "$-" != *e* ]] || errexit=1
		set +e
		(
			set -e
			"${fn}" "$@"
		)
		rc=$?
		[[ -z "${errexit}" ]] || set -e
		[[ "${rc}" -eq 0 ]] || status=1
		if [[ -n "${label}" ]]; then
			outcome="${label}" note=""
			# shellcheck disable=SC2310 # overlay_has_changes is designed to be tested in conditions
			if [[ ! -d "${OVERLAY_DIR}/upper" ]]; then
				note="  (see the messages above)"
			elif overlay_has_changes "${OVERLAY_DIR}"; then
				outcome=declined note="  (changes still pending)"
			elif [[ -z "${changed}" ]]; then
				outcome=unchanged
			fi
			[[ "${rc}" -eq 0 ]] || outcome=failed
			[[ "${rc}" -lt 128 ]] || outcome=interrupted
			results+=("$(printf '  %-11s %s%s' "${outcome}" "${OVERLAY_PROJECT_DIR}" "${note}")")
		fi
		if [[ "${rc}" -ge 128 ]]; then
			status="${rc}"
			break
		fi
	done
	if [[ -n "${label}" ]]; then
		echo ""
		echo "Result per project:"
		printf '%s\n' "${results[@]}"
	fi
	return "${status}"
}

# ─── overlay diff ──────────────────────────────────────────────────────────
# Show changes in overlay upper dirs, one project after another.
# Usage: overlay_diff [project-path...]
overlay_diff() {
	# shellcheck disable=SC2310 # resolve_overlay is designed to be tested with ||
	resolve_overlay diff "$@" || return $?
	_overlay_each "" _overlay_diff_one
}

# Show the changes of one project's overlay (OVERLAY_DIR) against the project.
_overlay_diff_one() {
	local upper="${OVERLAY_DIR}/upper"
	local project="${OVERLAY_PROJECT_DIR}"

	# shellcheck disable=SC2310 # the engine's status is the point of the test
	if ! _overlay_scan_sessions 2>/dev/null; then
		echo "Note: could not ask '${CONTAINER_CMD:-podman}' whether a session on this overlay is running;" >&2
		echo "      if one is, the overlay can change while you read this." >&2
	elif [[ "${#_OVERLAY_HOLDERS[@]}" -gt 0 ]]; then
		echo "Note: container ${_OVERLAY_HOLDERS[*]} mounts the overlay of ${project} read-write and is still running; the overlay can change while you read this." >&2
	fi

	echo "Overlay diff for: ${project}"
	echo ""

	local found=0
	local hidden=0 kept=0
	local rel shown base dir kind target
	# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
	while IFS= read -r -d '' rel; do
		# shellcheck disable=SC2310 # designed to be tested in conditions
		if overlay_path_kept "${rel}"; then
			kept=$((kept + 1))
			continue
		fi
		# shellcheck disable=SC2310 # designed to be tested in conditions
		if overlay_path_ignored "${rel}"; then
			hidden=$((hidden + 1))
			continue
		fi
		# Names are container-chosen: never print a control character raw.
		shown="${rel}"
		# shellcheck disable=SC2310 # designed to be tested in conditions
		if _overlay_name_unsafe "${rel}"; then
			shown="$(quote_words "${rel}")"
		fi
		base="${shown##*/}"
		dir=.
		if [[ "${shown}" == */* ]]; then
			dir="${shown%/*}"
		fi
		# shellcheck disable=SC2310 # an entry that vanished mid-listing is skipped
		kind="$(_overlay_entry_kind "${upper}/${rel}")" || continue
		found=$((found + 1))

		case "${kind}" in
		opaque) echo "D  ${dir}/  (directory replaced)" ;;
		whiteout) echo "D  ${dir}/${base#.wh.}" ;;
		devwhiteout) echo "D  ${dir}/${base}" ;;
		link)
			target="$(readlink -- "${upper}/${rel}")" || target="?"
			echo "L  ${shown} -> $(quote_words "${target}")"
			;;
		unsupported) echo "?  ${shown}  (not a file, directory, link or whiteout; overlay-accept refuses it)" ;;
		file)
			# The contents are container-written too: the diffs go through
			# terminal_clean, which keeps tabs and newlines.
			if [[ -f "${project}/${rel}" ]]; then
				echo "M  ${shown}"
				# Show diff if both are text files
				if file "${upper}/${rel}" | grep -q text && file "${project}/${rel}" | grep -q text; then
					# shellcheck disable=SC2310 # diff exits non-zero on a difference; only a terminal_clean failure is an error
					diff -u "${project}/${rel}" "${upper}/${rel}" \
						--label "a/${shown}" --label "b/${shown}" 2>/dev/null | terminal_clean text || [[ "${PIPESTATUS[1]}" -eq 0 ]]
				else
					echo "   (binary file)"
				fi
			else
				echo "A  ${shown}"
				if file "${upper}/${rel}" | grep -q text; then
					# Show the new file content as a unified diff against /dev/null
					# shellcheck disable=SC2310 # diff exits non-zero on a difference; only a terminal_clean failure is an error
					diff -u /dev/null "${upper}/${rel}" --label /dev/null --label "b/${shown}" 2>/dev/null | terminal_clean text || [[ "${PIPESTATUS[1]}" -eq 0 ]]
				else
					echo "   (binary file)"
				fi
			fi
			;;
		*) ;;
		esac
	done < <(_overlay_entries "${upper}" -not -type d 2>/dev/null)

	if [[ "${found}" -eq 0 ]]; then
		echo "No changes."
	fi

	# Application is deliberately unfiltered (see scripts/lib/overlay-ignore.sh):
	# whenever overlay-accept applies anything at all it copies these entries to
	# the project too, so omitting them here without saying so would let bytes
	# reach the host that the review never showed.
	if [[ "${hidden}" -gt 0 ]]; then
		echo ""
		echo "Note: ${hidden} file(s) under .codegraph/ not shown (derived cache)."
		echo "      overlay-accept does not filter them: they are copied to the"
		echo "      project whenever it applies changes."
	fi
	if [[ "${kept}" -gt 0 ]]; then
		echo ""
		echo "Note: ${kept} file(s) under .headroom/ not shown (headroom memory)."
		echo "      overlay-accept and overlay-reject leave them in the overlay;"
		echo "      they are never copied to the project."
	fi
}

# ─── overlay accept ────────────────────────────────────────────────────────
# Apply overlay changes to host project(s).
# Usage: overlay_accept [--force] [project-path...]
#
# For a set of projects, each one is accepted in turn exactly as below,
# with its own checks, review and prompt (_overlay_each): declining or
# failing one leaves its changes pending and the others proceed. The exit
# status is 1 when any project failed; declining is not a failure.
#
# What accept guarantees, and what it does not:
#
# - It refuses while a live container, labelled riotbox.session or not, has
#   this overlay mounted read-write, and when the engine cannot say. Other sessions on the same
#   project (which RiotBox supports) do not block; their read-write mounts
#   of the project are named in a warning.
# - The upper is renamed to a snapshot outside the session's mount
#   (overlay/<name>.accepting.<pid>), so a container started afterwards cannot
#   reach what is reviewed and applied, and the engine is asked again once the
#   snapshot is taken.
# - Every entry and the project path it lands on are validated before the
#   review is shown, and the whole validation runs again after the user
#   confirms. If anything differs (a type, a link target, an entry added or
#   gone, a project directory turned into a link) nothing is applied.
# - During the apply, each source is read through directories verified to be
#   the snapshot's own, and each copied entry is checked to be what was
#   validated; only validated entries are applied.
#
# Not covered: a process that already holds a directory or file open inside
# the upper (a container started between the check and the rename) can
# still change the bytes of a regular
# file between the review and its copy; the review lists names, not contents.
# And another session on the project can change the project while the apply
# itself runs, after the second validation.
#
# Every exit that does not apply puts the snapshot back as the upper; if that
# is impossible, a warning names where the changes are. `riotbox overlays`
# lists a snapshot left by a killed accept, and the launch guard treats it as
# pending.
overlay_accept() {
	local FORCE=false
	local -a projects=()
	local arg
	for arg in "$@"; do
		case "${arg}" in
		--force | -f) FORCE=true ;;
		*) projects+=("${arg}") ;;
		esac
	done

	# shellcheck disable=SC2310 # resolve_overlay is designed to be tested with ||
	resolve_overlay accept "${projects[@]}" || return $?
	_overlay_each applied _overlay_locked _overlay_accept_one "${FORCE}"
}

# _overlay_locked <function> [args...]
#   Run <function> holding an exclusive flock on
#   <state-dir>/.overlay-<name>.lock, so an accept and a reject (or two of
#   either) never work on one overlay at once: each moves the upper aside,
#   and one could restore or delete the other's live <name>.rejecting.* dir
#   or accept snapshot. Refuses at once when another command holds it. The
#   lock file is at the state dir's top level, which no container mounts;
#   not in overlay/, whose non-directories the session-state migration
#   removes. Lock order: resolve_overlay takes and releases the state root's
#   and the session's .migrate.lock before this, and nothing takes either
#   while holding this one; a launch's .sync.lock never meets it.
_overlay_locked() {
	local lock="${OVERLAY_DIR%/overlay/*}/.overlay-${OVERLAY_DIR##*/}.lock" fd rc=0
	exec {fd}>"${lock}" || return 1
	if ! flock -n "${fd}"; then
		exec {fd}>&-
		echo "ERROR: another overlay-accept or overlay-reject is working on the overlay of ${OVERLAY_PROJECT_DIR}." >&2
		echo "       Let it finish, then run this again." >&2
		return 1
	fi
	# Not `"$@" || rc=$?`: that would switch errexit off inside <function>,
	# and _overlay_each relies on it to end a project's run at an unexpected
	# failure. Under errexit a failure exits this (sub)shell, which releases
	# the lock with it.
	"$@"
	rc=$?
	exec {fd}>&-
	return "${rc}"
}

# _overlay_accept_one <force>
#   Accept one project's overlay (OVERLAY_PROJECT_DIR, OVERLAY_DIR).
_overlay_accept_one() {
	local FORCE="$1"
	# shellcheck disable=SC2310 # designed to be tested with ||
	_overlay_refuse_if_running accept warn || return 1
	# shellcheck disable=SC2310 # designed to be tested with ||
	_overlay_recover_rejecting || return 1

	local upper="${OVERLAY_DIR}/upper"
	local work="${OVERLAY_DIR}/work"
	local project="${OVERLAY_PROJECT_DIR}"

	if [[ -L "${upper}" ]] || [[ ! -d "${upper}" ]]; then
		echo "ERROR: ${upper} is not a real directory; refusing to apply it." >&2
		return 1
	fi

	# shellcheck disable=SC2310 # overlay_has_changes is designed to be tested in if-conditions
	if ! overlay_has_changes "${OVERLAY_DIR}"; then
		echo "No overlay changes to apply for ${project}."
		return 0
	fi

	# The traps go in before the rename, so no signal can land between the
	# two; the handler does nothing until the snapshot exists.
	local snapshot="${OVERLAY_DIR}.accepting.$$"
	_OVERLAY_UPPER="${upper}"
	_OVERLAY_SNAPSHOT="${snapshot}"
	_OVERLAY_APPLYING=""
	trap _overlay_restore_snapshot EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	if ! mv -T -- "${upper}" "${snapshot}"; then
		_OVERLAY_SNAPSHOT=""
		trap - EXIT INT TERM HUP
		return 1
	fi
	# shellcheck disable=SC2310 # designed to be tested in conditions
	if ! _overlay_refuse_if_running accept; then
		_overlay_restore_snapshot
		trap - EXIT INT TERM HUP
		return 1
	fi

	local rc=0
	# shellcheck disable=SC2310 # its status picks the outcome; it checks every step itself
	_overlay_apply_snapshot "${snapshot}" "${project}" "${FORCE}" || rc=$?
	case "${rc}" in
	0)
		_OVERLAY_SNAPSHOT=""
		trap - EXIT INT TERM HUP
		# The snapshot holds only applied changes now, plus any kept entries.
		# It must not outlive this as <name>.accepting.<pid>, which reads as
		# an interrupted accept: pending, re-applied by the next accept. So
		# when the kept entries cannot go back into the upper they are set
		# aside in a sibling the bookkeeping ignores, and failing that the
		# snapshot itself is renamed to one.
		local aside
		# shellcheck disable=SC2310 # its status picks the recovery
		if _overlay_move_kept "${snapshot}" "${upper}"; then
			rm -rf -- "${snapshot}"
		elif aside="$(mktemp -d -- "${OVERLAY_DIR}.headroom.XXXXXX")" &&
			_overlay_move_kept "${snapshot}" "${aside}"; then
			rm -rf -- "${snapshot}"
			echo "Warning: .headroom from the overlay is in ${aside}; it could not be moved back into ${upper}." >&2
			echo "         It is headroom memory an older RiotBox left there, never applied to the project." >&2
			# shellcheck disable=SC2312 # quoting cannot fail
			echo "         Exit every session of this project, then move it back with: mv -T $(quote_words "${aside}/.headroom" "${upper}/.headroom"); or delete $(quote_words "${aside}")." >&2
		elif aside="$(mktemp -d -- "${OVERLAY_DIR}.applied.XXXXXX")" &&
			mv -T -- "${snapshot}" "${aside}/data"; then
			# Nested one level down: at the top, a project's own upper/
			# would make the sibling look like an overlay dir with changes.
			echo "Warning: could not set .headroom aside; ${aside}/data holds it together with the changes just applied." >&2
			# shellcheck disable=SC2312 # quoting cannot fail
			echo "         Take .headroom from it if you want to keep it, then delete $(quote_words "${aside}")." >&2
		else
			echo "Warning: ${snapshot} holds .headroom and the changes just applied, and reads as an interrupted accept." >&2
			echo "         Take .headroom from it if you want to keep it, then delete it; do not move it back as the upper." >&2
		fi
		# shellcheck disable=SC2310 # the engine's status is the point of the test
		if ! _overlay_scan_sessions 2>/dev/null || [[ "${#_OVERLAY_HOLDERS[@]}" -gt 0 ]]; then
			echo "Notice: a session on this overlay is running now (or the engine could not say);" >&2
			echo "        left ${work} in place." >&2
			# shellcheck disable=SC2310 # designed to be tested with ||
			require_real_dir "${upper}" || return 1
		else
			rm -rf -- "${work}"
			# shellcheck disable=SC2310 # designed to be tested with ||
			require_real_dir "${upper}" || return 1
			# shellcheck disable=SC2310 # designed to be tested with ||
			require_real_dir "${work}" || return 1
		fi
		echo "Applied. Overlay data cleaned."
		;;
	2)
		_overlay_restore_snapshot
		trap - EXIT INT TERM HUP
		echo "Aborted."
		;;
	*)
		_overlay_restore_snapshot
		trap - EXIT INT TERM HUP
		return 1
		;;
	esac
}

# Put an accept's snapshot back as the upper, unless something took the
# upper's place meanwhile, and warn when the apply had already begun.
# Idempotent: also runs as the EXIT trap, possibly before the rename.
_overlay_restore_snapshot() {
	[[ -n "${_OVERLAY_SNAPSHOT:-}" ]] || return 0
	local snap="${_OVERLAY_SNAPSHOT}"
	_OVERLAY_SNAPSHOT=""
	if [[ ! -e "${snap}" ]] && [[ ! -L "${snap}" ]]; then
		return 0
	fi
	if [[ -e "${_OVERLAY_UPPER}" ]] || [[ -L "${_OVERLAY_UPPER}" ]] ||
		! mv -T -- "${snap}" "${_OVERLAY_UPPER}"; then
		echo "Warning: the overlay changes are kept in ${snap};" >&2
		echo "         ${_OVERLAY_UPPER} could not be restored from it." >&2
		# shellcheck disable=SC2312 # quoting cannot fail
		echo "         Move it back with: mv -T $(quote_words "${snap}" "${_OVERLAY_UPPER}")" >&2
	fi
	if [[ -n "${_OVERLAY_APPLYING:-}" ]]; then
		echo "Warning: the apply stopped partway; ${OVERLAY_PROJECT_DIR} may be partially changed." >&2
		echo "         Run overlay-accept again to complete it." >&2
	fi
}

# _overlay_plan <snapshot> <project>
#   Validate every entry of the snapshot against the project (both
#   canonical) and plan the apply. Returns non-zero, saying why, if anything
#   would be unsafe; then nothing has been changed. Sets:
#     _OP_REVIEW       the review lines
#     _OP_SUMMARY      the summary line
#     _OP_OPAQUE       directories to replace (pass 1)
#     _OP_DELETIONS    project paths to delete (pass 2)
#     _OP_COPIES       entries to copy, sorted so parents come first (pass 3)
#     _OP_KIND         entry -> validated kind (_overlay_entry_kind)
#     _OP_TARGET       link entry -> validated target
#     _OP_FINGERPRINT  all of the above as one string, to compare two plans
#   Opaque directories go first, then whiteouts, then copies, so nothing is
#   copied into a directory that is about to be replaced.
_overlay_plan() {
	local snap="$1" project="$2"
	_OP_REVIEW=()
	_OP_OPAQUE=()
	_OP_DELETIONS=()
	_OP_COPIES=()
	declare -gA _OP_KIND=() _OP_TARGET=()
	_OP_SUMMARY=""
	_OP_FINGERPRINT=""

	local -a rels=()
	# shellcheck disable=SC2312 # the listing's status is checked through wait below
	mapfile -d '' -t rels < <(_overlay_entries "${snap}")
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	if ! wait "$!"; then
		echo "ERROR: could not list ${snap} completely; nothing was applied." >&2
		return 1
	fi

	local rel
	local -a bad=() applied=()
	# Kept names are never applied (scripts/lib/overlay-ignore.sh): neither
	# copied into the project nor, through a whiteout, deleted from it.
	for rel in "${rels[@]}"; do
		# shellcheck disable=SC2310 # designed to be tested in conditions
		overlay_path_kept "${rel}" || applied+=("${rel}")
	done
	rels=("${applied[@]}")
	for rel in "${rels[@]}"; do
		# shellcheck disable=SC2310 # designed to be tested in conditions
		if _overlay_name_unsafe "${rel}"; then
			bad+=("${rel}")
		fi
	done
	if [[ "${#bad[@]}" -gt 0 ]]; then
		echo "ERROR: overlay entries with a control character in their name; nothing was applied:" >&2
		for rel in "${bad[@]}"; do
			# shellcheck disable=SC2312 # quoting a string cannot fail
			echo "  $(quote_words "${rel}")" >&2
		done
		return 1
	fi

	local added=0 modified=0 deleted=0
	local kind base dir target dest note
	for rel in "${rels[@]}"; do
		# shellcheck disable=SC2310 # an entry that vanished or cannot be stat'ed stops the accept
		kind="$(_overlay_entry_kind "${snap}/${rel}")" || return 1
		_OP_KIND["${rel}"]="${kind}"
		base="${rel##*/}"
		dir=.
		if [[ "${rel}" == */* ]]; then
			dir="${rel%/*}"
		fi
		dest="${project}/${rel}"
		case "${kind}" in
		opaque)
			if [[ "${dir}" == . ]]; then
				echo "ERROR: an opaque marker at the top of the overlay would replace the whole project; nothing was applied." >&2
				return 1
			fi
			# shellcheck disable=SC2310 # designed to be tested with ||
			_overlay_check_dest "${project}" "${dir}" || return 1
			_OP_OPAQUE+=("${dir}")
			_OP_REVIEW+=("  REPLACE  ${dir}/")
			deleted=$((deleted + 1))
			;;
		whiteout | devwhiteout)
			if [[ "${kind}" == whiteout ]]; then
				base="${base#.wh.}"
			fi
			if [[ -z "${base}" ]] || [[ "${base}" == . ]] || [[ "${base}" == .. ]]; then
				echo "ERROR: ${rel} is a malformed whiteout (it names no entry); nothing was applied." >&2
				return 1
			fi
			target="${base}"
			if [[ "${dir}" != . ]]; then
				target="${dir}/${base}"
			fi
			# shellcheck disable=SC2310 # designed to be tested with ||
			_overlay_check_dest "${project}" "${target}" || return 1
			_OP_DELETIONS+=("${target}")
			_OP_REVIEW+=("  DELETE   ${dir}/${base}")
			deleted=$((deleted + 1))
			;;
		dir)
			# shellcheck disable=SC2310 # designed to be tested with ||
			_overlay_check_dest "${project}" "${rel}" || return 1
			if [[ -L "${dest}" ]] || { [[ -e "${dest}" ]] && [[ ! -d "${dest}" ]]; }; then
				echo "ERROR: ${rel} cannot be applied: it is a symlink or not a directory in the project, and the overlay writes into it." >&2
				echo "       Nothing was applied." >&2
				return 1
			fi
			_OP_COPIES+=("${rel}")
			;;
		file | link)
			# shellcheck disable=SC2310 # designed to be tested with ||
			_overlay_check_dest "${project}" "${rel}" || return 1
			if [[ -d "${dest}" ]] && [[ ! -L "${dest}" ]]; then
				echo "ERROR: ${rel} cannot be applied: it would replace a directory in the project." >&2
				echo "       Nothing was applied." >&2
				return 1
			fi
			_OP_COPIES+=("${rel}")
			note=""
			if [[ -L "${dest}" ]]; then
				note="  (replaces a symlink)"
			fi
			if [[ "${kind}" == link ]]; then
				target="$(readlink -- "${snap}/${rel}")" || return 1
				_OP_TARGET["${rel}"]="${target}"
				# shellcheck disable=SC2312 # quoting a string cannot fail
				_OP_REVIEW+=("  LINK     ${rel} -> $(quote_words "${target}")${note}")
			elif [[ -e "${dest}" ]] || [[ -L "${dest}" ]]; then
				_OP_REVIEW+=("  MODIFY   ${rel}${note}")
			else
				_OP_REVIEW+=("  ADD      ${rel}")
			fi
			if [[ -e "${dest}" ]] || [[ -L "${dest}" ]]; then
				modified=$((modified + 1))
			else
				added=$((added + 1))
			fi
			;;
		*)
			echo "ERROR: ${rel} in the overlay is unsupported (not a file, directory, symlink or whiteout); nothing was applied." >&2
			return 1
			;;
		esac
		# Names hold no control character (checked above) and the target is
		# quoted, so a newline separates records unambiguously.
		# shellcheck disable=SC2312 # quoting a string cannot fail
		_OP_FINGERPRINT+="${kind} ${rel} $(quote_words "${_OP_TARGET["${rel}"]:-}")"$'\n'
	done
	_OP_SUMMARY="Summary: ${added} added, ${modified} modified, ${deleted} deleted"
	if [[ "${#_OP_REVIEW[@]}" -gt 0 ]]; then
		_OP_FINGERPRINT+="$(printf '%s\n' "${_OP_REVIEW[@]}")"$'\n'
	fi
	_OP_FINGERPRINT+="${_OP_SUMMARY}"
}

# _overlay_apply_snapshot <snapshot> <project> <force>
#   Review and apply a snapshot of the upper. Returns 0 when applied, 2 when
#   the user declined, 1 on any failure. The plan is made and shown, then made
#   again after the confirmation and must come out identical. Runs with
#   errexit suspended (its caller tests the status), so every step checks its
#   own.
_overlay_apply_snapshot() {
	local snap project force="$3"
	if ! snap="$(realpath -e -- "$1")" || ! project="$(realpath -e -- "$2")"; then
		return 1
	fi

	# shellcheck disable=SC2310 # designed to be tested with ||
	_overlay_plan "${snap}" "${project}" || return 1
	local reviewed="${_OP_FINGERPRINT}"

	echo "Overlay changes to apply to: ${project}"
	echo ""
	if [[ "${#_OP_REVIEW[@]}" -gt 0 ]]; then
		printf '%s\n' "${_OP_REVIEW[@]}"
	fi
	echo ""
	echo "${_OP_SUMMARY}"
	echo ""

	local confirm
	if [[ "${force}" != true ]]; then
		read -rp "Apply these changes? [y/N] " confirm || confirm=""
		if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
			return 2
		fi
	fi

	# The prompt may have waited a long time, and other sessions may share
	# the project: validate everything again, and apply only if the plan is
	# exactly the one reviewed.
	# shellcheck disable=SC2310 # designed to be tested in conditions
	if ! _overlay_plan "${snap}" "${project}" || [[ "${_OP_FINGERPRINT}" != "${reviewed}" ]]; then
		echo "ERROR: the overlay or the project changed after review; nothing was applied." >&2
		echo "       Run overlay-accept again to review the current changes." >&2
		return 1
	fi

	_OVERLAY_APPLYING=1
	local rel dest src_dir
	for rel in "${_OP_OPAQUE[@]}"; do
		rm -rf --one-file-system -- "${project:?}/${rel:?}" || return 1
		mkdir -p -- "${project}/${rel}" || return 1
	done
	for rel in "${_OP_DELETIONS[@]}"; do
		rm -rf --one-file-system -- "${project:?}/${rel:?}" || return 1
	done
	for rel in "${_OP_COPIES[@]}"; do
		dest="${project}/${rel}"
		if [[ "${_OP_KIND["${rel}"]}" == dir ]]; then
			mkdir -p -- "${dest}" || return 1
			continue
		fi
		src_dir="${snap}"
		if [[ "${rel}" == */* ]]; then
			src_dir="${snap}/${rel%/*}"
			mkdir -p -- "${project}/${rel%/*}" || return 1
		fi
		# Copy from inside the source's directory, entered with cd -P and
		# verified to be the snapshot's own, so a directory swapped for a link
		# after validation cannot redirect the read. -P copies a link as a
		# link; --remove-destination replaces an existing link in the project
		# instead of writing through it.
		# `cp -a` preserves context+xattr via fsetxattr, which (a) the kernel
		# denies under SELinux when the project bind mount has a different
		# label class, and (b) would smear container_t-derived labels onto
		# host files. Drop both; mode/timestamps/links are still preserved.
		# shellcheck disable=SC2310,SC2312 # every step is tested; any failure refuses the entry
		if ! (cd -P -- "${src_dir}" && [[ "$(pwd -P)" == "${src_dir}" ]] &&
			_overlay_entry_unchanged . "${rel##*/}" "${_OP_KIND["${rel}"]}" "${_OP_TARGET["${rel}"]:-}" &&
			cp -a -P --remove-destination --no-preserve=context,xattr -- "${rel##*/}" "${dest}"); then
			echo "ERROR: could not apply ${rel}, or it changed after review." >&2
			return 1
		fi
		# What landed must be what was validated: a swap between the check
		# and the copy shows up here, and the result is removed.
		case "${_OP_KIND["${rel}"]}" in
		file)
			if [[ -L "${dest}" ]] || [[ ! -f "${dest}" ]]; then
				rm -f -- "${dest}"
				echo "ERROR: ${rel} changed after review; removed what was copied." >&2
				return 1
			fi
			# A session-made setuid/setgid file must not become one on the host.
			chmod u-s,g-s -- "${dest}" || return 1
			;;
		*)
			# shellcheck disable=SC2312 # a failed readlink fails the comparison
			if [[ ! -L "${dest}" ]] || [[ "$(readlink -- "${dest}")" != "${_OP_TARGET["${rel}"]}" ]]; then
				rm -f -- "${dest}"
				echo "ERROR: ${rel} changed after review; removed what was copied." >&2
				return 1
			fi
			;;
		esac
	done
}

# _overlay_entry_unchanged <dir> <rel> <kind> [<link-target>]
#   Exit 0 when <dir>/<rel> is still of the validated <kind> and, for a link,
#   still points at <link-target>.
_overlay_entry_unchanged() {
	local path="$1/$2" kind
	# shellcheck disable=SC2310 # an entry that vanished reads as changed
	kind="$(_overlay_entry_kind "${path}" 2>/dev/null)" || return 1
	[[ "${kind}" == "$3" ]] || return 1
	if [[ "${kind}" == link ]]; then
		local target
		target="$(readlink -- "${path}")" || return 1
		[[ "${target}" == "${4:-}" ]] || return 1
	fi
}

# ─── overlay reject ────────────────────────────────────────────────────────
# Discard overlay changes, of each project in turn for a set (as accept).
# Usage: overlay_reject [--force] [project-path...]
overlay_reject() {
	local FORCE=false
	local -a projects=()
	local arg
	for arg in "$@"; do
		case "${arg}" in
		--force | -f) FORCE=true ;;
		*) projects+=("${arg}") ;;
		esac
	done

	# shellcheck disable=SC2310 # resolve_overlay is designed to be tested with ||
	resolve_overlay reject "${projects[@]}" || return $?
	_overlay_each discarded _overlay_locked _overlay_reject_one "${FORCE}"
}

# _overlay_move_kept <from-dir> <to-dir>
#   Move each top-level entry of <from-dir> that overlay_path_kept names into
#   <to-dir>, creating <to-dir> (require_real_dir: never through a link)
#   before the first move only, so it is left absent when there is nothing to
#   keep. mv moves a link as a link, so a planted symlink stays a symlink in
#   the overlay and is never followed. Returns non-zero when a move fails or
#   <to-dir> is not a real directory; what moved before stays moved.
_overlay_move_kept() {
	local from="$1" to="$2" entry
	local -a entries=()
	# A listing that failed could miss a kept entry, which the caller would
	# then delete with the rest, so its status is checked.
	# shellcheck disable=SC2312 # the listing's status is checked through wait below
	mapfile -d '' -t entries < <(find "${from}" -mindepth 1 -maxdepth 1 -printf '%P\0')
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	wait "$!" || return 1
	for entry in "${entries[@]}"; do
		# shellcheck disable=SC2310 # designed to be tested in conditions
		overlay_path_kept "${entry}" || continue
		# shellcheck disable=SC2310 # designed to be tested with ||
		require_real_dir "${to}" || return 1
		mv -T -- "${from}/${entry}" "${to}/${entry}" || return 1
	done
}

# _overlay_recover_rejecting
#   An overlay-reject killed between setting the kept entries aside and
#   putting the fresh upper in place leaves them in
#   <name>.rejecting.XXXXXX, beside OVERLAY_DIR in overlay/, which no
#   container mounts. For each such real directory (a link is never
#   followed): move each kept entry back into the upper when the upper is a
#   real directory that has none, and remove the directory once empty;
#   otherwise say where the entry is and how to move it. Callers have just
#   checked that no session runs on the overlay. Returns non-zero when a
#   directory cannot be listed.
_overlay_recover_rejecting() {
	local dir entry left upper="${OVERLAY_DIR}/upper"
	local -a entries=()
	for dir in "${OVERLAY_DIR}".rejecting.*; do
		[[ -d "${dir}" && ! -L "${dir}" ]] || continue
		# shellcheck disable=SC2312 # the listing's status is checked through wait below
		mapfile -d '' -t entries < <(find "${dir}" -mindepth 1 -maxdepth 1 -printf '%P\0')
		# shellcheck disable=SC2154 # $! is the process substitution's PID
		wait "$!" || {
			echo "ERROR: could not list ${dir}, left by an overlay-reject that did not finish." >&2
			return 1
		}
		for entry in "${entries[@]}"; do
			# shellcheck disable=SC2310 # designed to be tested in conditions
			if overlay_path_kept "${entry}" && [[ -d "${upper}" && ! -L "${upper}" ]] &&
				[[ ! -e "${upper}/${entry}" && ! -L "${upper}/${entry}" ]] &&
				mv -T -- "${dir}/${entry}" "${upper}/${entry}"; then
				echo "Notice: put ${entry} back into ${upper} from ${dir}, left by an overlay-reject that did not finish."
			else
				echo "Notice: ${dir}/${entry} was set aside by an overlay-reject that did not finish." >&2
				# shellcheck disable=SC2312 # quoting cannot fail
				echo "        Move it back with: mv -T $(quote_words "${dir}/${entry}" "${upper}/${entry}") (after removing what is there), or delete it." >&2
			fi
		done
		# Removed only when empty: what could not be put back stays.
		left="$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || left=unlistable
		if [[ -z "${left}" ]]; then
			rmdir -- "${dir}" || return 1
		fi
	done
}

# _overlay_reject_one <force>
#   Discard one project's overlay (OVERLAY_PROJECT_DIR, OVERLAY_DIR).
_overlay_reject_one() {
	local FORCE="$1"
	# shellcheck disable=SC2310 # designed to be tested with ||
	_overlay_refuse_if_running reject || return 1
	# shellcheck disable=SC2310 # designed to be tested with ||
	_overlay_recover_rejecting || return 1

	# A session can leave upper or work as a link or a file. The launch then
	# refuses the overlay (require_real_dir) and names this command, and
	# there are no changes to find through it, so clear it first, changes
	# or not: rm -rf removes the entry itself, never what a link names.
	local stray
	for stray in "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"; do
		if [[ -L "${stray}" ]] || { [[ -e "${stray}" ]] && [[ ! -d "${stray}" ]]; }; then
			echo "Warning: ${stray} is a symlink or not a directory; removed it without following it." >&2
			rm -rf -- "${stray}" || return 1
			# shellcheck disable=SC2310 # it has already said why it refused
			require_real_dir "${stray}" || return 1
		fi
	done

	# shellcheck disable=SC2310 # overlay_has_changes is designed to be tested in if-conditions
	if ! overlay_has_changes "${OVERLAY_DIR}"; then
		echo "No overlay changes to discard for ${OVERLAY_PROJECT_DIR}."
		return 0
	fi

	echo "Discarding overlay changes for: ${OVERLAY_PROJECT_DIR}"

	local confirm
	if [[ "${FORCE}" != true ]]; then
		read -rp "Discard all changes? This cannot be undone. [y/N] " confirm
		if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
			echo "Aborted."
			return 0
		fi
	fi
	# Again, as accept does: a session can start while the prompt waits.
	# shellcheck disable=SC2310 # designed to be tested with ||
	_overlay_refuse_if_running reject || return 1

	# Kept names survive the discard (scripts/lib/overlay-ignore.sh). They
	# go into a fresh upper, so nothing else about the old one (an opaque
	# marker, its own attributes) carries over. That fresh dir is made by
	# mktemp as a sibling of the overlay dir, in overlay/, which no container
	# mounts: a fixed name inside the overlay dir could be a link a session
	# planted, and the kept entries would be moved through it. Its mode is
	# what mkdir would have given the upper.
	local upper="${OVERLAY_DIR}/upper" work="${OVERLAY_DIR}/work" fresh
	local mask
	mask="$(umask)"
	fresh="$(mktemp -d -- "${OVERLAY_DIR}.rejecting.XXXXXX")" || return 1
	chmod -- "$(printf '%o' $((0777 & ~0${mask})))" "${fresh}" || return 1
	if [[ -d "${upper}" ]] && [[ ! -L "${upper}" ]]; then
		# shellcheck disable=SC2310 # designed to be tested with ||
		_overlay_move_kept "${upper}" "${fresh}" || {
			echo "ERROR: could not set .headroom aside in ${fresh}; nothing more was discarded." >&2
			return 1
		}
	fi
	# Everything else in the overlay dir goes too: only upper/ and work/
	# belong there (container/overlay-setup.sh), so anything more is what a
	# session planted, such as links named like a temp dir. rm -rf removes a
	# link itself, never what it points at.
	local entry
	local -a entries=()
	# shellcheck disable=SC2312 # the listing's status is checked through wait below
	mapfile -d '' -t entries < <(find "${OVERLAY_DIR}" -mindepth 1 -maxdepth 1 -print0)
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	wait "$!" || {
		echo "ERROR: could not list ${OVERLAY_DIR}; what overlay-reject keeps is in ${fresh}." >&2
		return 1
	}
	for entry in "${entries[@]}"; do
		rm -rf -- "${entry}"
	done
	mv -T -- "${fresh}" "${upper}" || {
		echo "ERROR: could not put the fresh upper in place; what overlay-reject keeps is in ${fresh}." >&2
		return 1
	}
	# shellcheck disable=SC2310 # designed to be tested with ||
	require_real_dir "${work}" || return 1
	echo "Overlay data discarded."
}

# ─── dispatch ──────────────────────────────────────────────────────────────
_overlay_usage() {
	cat <<'EOF'
Usage: overlay.sh <subcommand> [args...]

Subcommands:
  list                          List sessions with pending overlay data.
  diff [project...]             Show overlay changes vs host project(s).
  accept [--force] [project...] Apply overlay changes to host project(s).
  reject [--force] [project...] Discard overlay changes.
  help                          Show this message.

Pass the projects as the session was launched with: none for the current
directory, or every project of a multi-project session, in any order.
EOF
}

overlay_main() {
	local cmd="${1:-}"
	if [[ -z "${cmd}" ]]; then
		_overlay_usage >&2
		return 2
	fi
	shift
	case "${cmd}" in
	list) overlay_list "$@" ;;
	diff) overlay_diff "$@" ;;
	accept) overlay_accept "$@" ;;
	reject) overlay_reject "$@" ;;
	-h | --help | help) _overlay_usage ;;
	*)
		echo "overlay: unknown subcommand '${cmd}'" >&2
		_overlay_usage >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
	overlay_main "$@"
fi
