#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/session-state.sh — host-side helpers for a session's state dir.
#
# A session owns two host directories (resolve_projects in
# scripts/mount-projects.sh derives both from one key):
#
#   ${XDG_DATA_HOME}/riotbox/<key>/        RIOTBOX_SESSION_DIR — mounted whole,
#                                          read-write, at /home/llm/.claude
#   ${XDG_DATA_HOME}/riotbox-state/<key>/  RIOTBOX_STATE_DIR — never mounted
#                                          whole; each subdir is its own mount
#
# Every bind-mount source other than the session dir itself lives in the state
# dir. Anything nested in the session dir can be replaced from inside the
# container — by a symlink, even a relative one — and the next launch's
# host-side code would then follow it and podman would mount the link's target
# read-write. The container cannot reach the state dir itself, only the subdirs
# it mounts, so it cannot replace a mount source. See
# docs/dev/decisions/session-state-dir.md.
#
# The same holds for files RiotBox reads back from the session dir:
# session_projects never reads .projects through a link, and terminal_clean
# makes what it read safe to print.
#
# Sourced on the host by scripts/mount-projects.sh,
# agents/opencode/sync-settings.sh and agents/pi/sync-settings.sh.
#
# Public:
#   ensure_real_dir <dir>
#   require_real_dir <dir>
#   migrate_legacy_state <session-dir> <state-dir> <legacy>:<new> ...
#   migrate_overlay_state <session-dir> <state-dir>
#   migrate_session_state <session-dir> <state-dir>  (list: SESSION_STATE_MIGRATIONS)
#   migrate_failed_state <session-dir> <state-dir>
#   session_projects <session-dir>
#   recorded_projects <state-dir>
#   quote_words <word>...
#   terminal_clean
# ─────────────────────────────────────────────────────────────────────────────

# Resolved now: a caller may change directory before calling terminal_clean.
_SESSION_STATE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/running-sessions.sh
source "${_SESSION_STATE_LIB_DIR}/running-sessions.sh"

# ensure_real_dir <dir>
#   Make <dir> a real directory without following a link. A symlink at <dir>
#   (dangling, relative or absolute) or anything else that is not a directory
#   is removed — the entry itself, never what it points at — with a warning on
#   stderr. Then <dir> and any missing parents are created. Returns non-zero
#   when either step fails.
#
#   Only <dir> itself is checked. Its parents are the state root and the key
#   dir, which only the user's own RiotBox creates; a user who symlinks one of
#   them to another disk means it.
ensure_real_dir() {
	local dir="${1:?ensure_real_dir requires a directory}"
	# A trailing slash would make the tests below resolve a link.
	dir="${dir%/}"
	if [[ -L "${dir}" ]] || { [[ -e "${dir}" ]] && [[ ! -d "${dir}" ]]; }; then
		echo "Warning: ${dir} is not a real directory; replacing it." >&2
		rm -f "${dir}" || return 1
	fi
	mkdir -p "${dir}"
}

# require_real_dir <dir>
#   Create <dir> as a directory, or confirm that it already is one. Unlike
#   ensure_real_dir, refuse, saying so, when it is a symlink or not a
#   directory: for dirs inside overlay/<name>, which is mounted read-write
#   into the session at /mnt/overlay, so a session can plant either there,
#   and a link where upper/ should be is tampering to stop at, not to tidy
#   up. `mkdir -p` would take a link to a directory for the directory.
require_real_dir() {
	mkdir -- "$1" 2>/dev/null && return 0
	[[ -d "$1" ]] && [[ ! -L "$1" ]] && return 0
	echo "ERROR: $1 is a symlink or not a directory (or could not be created); refusing to use it." >&2
	return 1
}

# migrate_legacy_state [--replace-empty] <session-dir> <state-dir> <legacy>:<new> ...
#   One-time move of state an older RiotBox kept inside the session dir. For
#   each pair, <session-dir>/<legacy> becomes <state-dir>/<new>:
#
#     legacy absent                    nothing
#     legacy a symlink or not a dir    removed without being followed; warning
#     legacy a dir, new absent         moved; one notice
#     legacy a dir, new an empty real  with --replace-empty only (the user's
#       dir                            retry: migrate_failed_state): moved over
#                                      it, as when new is absent
#     legacy a dir, new present        both left untouched; warning naming both.
#                                      Never merged: either side may hold the
#                                      data the user wants. Stranded.
#     the move fails                   warning naming riotbox session-migrate
#                                      and the command that finishes the move
#                                      by hand; legacy left in place, and
#                                      <new> may be empty or (on a failed
#                                      cross-disk copy) partial. Stranded.
#     moved entry is no longer a dir   (the container swapped it for a link
#                                      after the check; rename moves the link
#                                      itself) removed from <new>; warning
#
#   Idempotent: once moved, a legacy entry is absent. Creates <state-dir> and
#   its parent (mode 0700) only when a real legacy dir is about to move.
#   Messages go to stderr, because some callers print mount flags on stdout.
#   Returns 1, without touching later pairs, when removing an entry fails: it
#   fails closed rather than carry on past something it cannot remove.
#   Otherwise returns 2 when any pair was left stranded (legacy data still in
#   the session dir, so the user must act), and 0 when none was. Never
#   retries anything itself; migrate_session_state records stranded pairs as
#   failed.
migrate_legacy_state() {
	local replace_empty=""
	if [[ "${1:-}" == --replace-empty ]]; then
		replace_empty=1
		shift
	fi
	local session_dir="${1:?migrate_legacy_state requires a session dir}"
	local state_dir="${2:?migrate_legacy_state requires a state dir}"
	shift 2
	local pair legacy new err stranded=0
	for pair in "$@"; do
		legacy="${session_dir}/${pair%%:*}"
		new="${state_dir}/${pair#*:}"
		if [[ ! -e "${legacy}" && ! -L "${legacy}" ]]; then
			continue
		fi
		if [[ -L "${legacy}" || ! -d "${legacy}" ]]; then
			echo "Warning: ${legacy} is not a real directory; removed it without following it." >&2
			rm -f "${legacy}" || return 1
			continue
		fi
		# A launch that left a pair stranded goes on to create <new>, so the
		# retry finds it, usually still empty. rename(2) replaces an empty
		# directory atomically, and fails (ENOTEMPTY) if it filled since.
		if [[ -e "${new}" || -L "${new}" ]] &&
			! { [[ -n "${replace_empty}" ]] && _is_empty_real_dir "${new}"; }; then
			echo "Warning: both ${legacy} and ${new} exist; left both untouched." >&2
			echo "         RiotBox now uses ${new}. Move anything you need out of ${legacy}, then delete it." >&2
			stranded=1
			continue
		fi
		# -T: if <new> appeared since the check above, replace it only if it
		# is an empty directory, and otherwise fail, instead of moving the
		# legacy dir INTO it.
		if ! err="$({ mkdir -p "${state_dir}" &&
			chmod 700 "${state_dir%/*}" "${state_dir}"; } 2>&1)"; then
			echo "Warning: could not prepare ${state_dir}; left ${legacy} in place:" >&2
			printf '%s\n' "${err}" >&2
			# shellcheck disable=SC2312 # the hint always prints something
			echo "         Once the cause is fixed, run $(_session_migrate_hint "${state_dir}")." >&2
			stranded=1
			continue
		fi
		if ! err="$(mv -T "${legacy}" "${new}" 2>&1)"; then
			echo "Warning: could not move ${legacy} to ${new}; left it in place:" >&2
			printf '%s\n' "${err}" >&2
			# shellcheck disable=SC2312 # the hint always prints something
			echo "         RiotBox will not retry this move on its own. Once the cause is fixed, run $(_session_migrate_hint "${state_dir}"), or move it by hand:" >&2
			printf '           mv -T -- %q %q\n' "${legacy}" "${new}" >&2
			echo "         If ${new} exists by then (empty, partly copied from another disk, or written by a later launch), move it aside first." >&2
			stranded=1
			continue
		fi
		# rename(2) moves the entry itself. If the container swapped the
		# legacy dir for a link after the check above, the link is now at
		# <new>; discard it rather than let a launch mount its target.
		if [[ -L "${new}" || ! -d "${new}" ]]; then
			echo "Warning: ${legacy} changed during the move; discarded it." >&2
			rm -f "${new}" || return 1
			continue
		fi
		echo "Notice: moved ${legacy} to ${new}" >&2
	done
	[[ "${stranded}" -eq 0 ]] || return 2
}

# migrate_overlay_state [--replace-empty] <session-dir> <state-dir>
#   migrate_legacy_state (with --replace-empty, if given) for overlay/, then
#   remove every entry directly under <state-dir>/overlay that is a symlink
#   or not a directory, with a warning.
#   Each overlay/<name> is a mount source of its own, one level below what
#   migrate_legacy_state checks, and while overlay/ sat in the session dir the
#   container could swap one for a link — which scripts/overlay.sh would then
#   follow into `rm -rf <link>/upper`. Safe on every call: nothing but RiotBox
#   writes directly under <state-dir>/overlay. Returns as migrate_legacy_state
#   does: 1 on a failed removal, 2 when overlay/ was left stranded, else 0.
migrate_overlay_state() {
	local -a opt=()
	if [[ "${1:-}" == --replace-empty ]]; then
		opt=(--replace-empty)
		shift
	fi
	local session_dir="${1:?migrate_overlay_state requires a session dir}"
	local state_dir="${2:?migrate_overlay_state requires a state dir}"
	local rc=0
	migrate_legacy_state "${opt[@]}" "${session_dir}" "${state_dir}" overlay:overlay || rc=$?
	[[ "${rc}" -ne 1 ]] || return 1
	local overlay_base="${state_dir}/overlay" entry
	if [[ ! -d "${overlay_base}" || -L "${overlay_base}" ]]; then
		return "${rc}"
	fi
	# shellcheck disable=SC2312 # a find failure leaves nothing listed to remove
	while IFS= read -r -d '' entry; do
		echo "Warning: ${entry} is not a real directory; removed it without following it." >&2
		rm -f "${entry}" || return 1
	done < <(find "${overlay_base}" -mindepth 1 -maxdepth 1 ! -type d -print0)
	return "${rc}"
}

# SESSION_STATE_MIGRATIONS
#   Everything an older RiotBox kept in the session dir, in the order
#   migrate_session_state moves it: <legacy>:<new> pairs for
#   migrate_legacy_state, and "overlay" for migrate_overlay_state.
SESSION_STATE_MIGRATIONS=(
	headroom:headroom git-ai:git-ai
	.config-opencode:opencode-config .local-share-opencode:opencode-data
	.pi-agent:pi-agent
	overlay
)

# migrate_session_state <session-dir> <state-dir>
#   The one-time migration of a session dir an older RiotBox left behind:
#   each entry of SESSION_STATE_MIGRATIONS that <state-dir>/.migrated does
#   not list yet. The entry point for launches and overlay commands.
#
#   Invariant: once .migrated names an entry's legacy name (the part before
#   ":"; "overlay" for the overlay tree), this never imports anything at that
#   legacy path in <session-dir> again. Migration moves session-dir content
#   into the state dir as trusted data, and the session dir is the
#   container's read-write ~/.claude: run on every launch, it let a running
#   container plant a legacy entry (say overlay/project/upper/x, from a
#   read-only session) and have the next launch adopt it as pending overlay
#   data. .migrated sits at the top of the state dir, which no container
#   mounts. setup_projects creates the state dir before calling this, so a
#   new session records every entry on its first launch.
#
#   To add a migration, append its pair to SESSION_STATE_MIGRATIONS. Sessions
#   that already have a .migrated run only the new pair, once, at their first
#   launch after the upgrade: that launch is the new legacy path's only
#   automatic import window, and what a container plants there afterwards
#   stays put.
#
#   Marker format, one line per record, appended in order:
#     <name>          the entry ran; never run automatically again
#     failed:<name>   it left legacy data stranded (a failed move, or both
#                     copies exist); written after a <name> line
#   One record names no entry of SESSION_STATE_MIGRATIONS and moves nothing:
#     project-headroom-notice  notice_project_headroom has checked for
#                     headroom memory an older release left in the project
#                     (and printed the notice if it found some); written by
#                     a headroom launch only. The passes here skip it.
#   An entry is failed while its last line is failed:<name>; a later <name>
#   line (migrate_failed_state succeeded, or nothing is left to move) makes
#   it done. Every stranded entry also gets a plain line, so a reader that
#   knows only plain names, as the first release of this marker did, never
#   retries it either.
#
#   An entry is recorded only after it returns 0 or 2 (stranded). On a
#   failure this returns non-zero with that entry unrecorded, so the next
#   call retries it. Then, for each entry already failed before this call:
#   while its legacy path is a real directory that holds anything, one
#   notice line on stderr names it and the riotbox session-migrate command
#   (with the session's recorded projects; for two copies, as the way to
#   see how to resolve them); once it is
#   gone, empty (podman leaves empty mountpoint dirs in the session dir) or
#   not a real directory, the entry is recorded as done, quietly. Nothing
#   here retries a failed entry.
#
#   Several launches and overlay commands of one session can run at once, and
#   each rebuilds .migrated, so the whole read-migrate-record pass holds an
#   exclusive flock on <state-dir>/.migrate.lock: a later caller then sees
#   what an earlier one recorded and skips it. That is a different file from
#   setup_projects' .sync.lock, taken only after this returns, so the two
#   never nest. When <state-dir> does not exist and the session dir holds no
#   legacy entry, there is nothing to do or record, and this returns 0
#   without creating it (an overlay command; the next launch creates it and
#   records every entry). Otherwise <state-dir> and its parent are created,
#   mode 0700, to hold the lock. <state-dir> may be a link the user made to
#   another disk: .migrated and the lock are used through it.
migrate_session_state() {
	local session_dir="${1:?migrate_session_state requires a session dir}"
	local state_dir="${2:?migrate_session_state requires a state dir}"
	local entry legacy found=0
	if [[ ! -d "${state_dir}" ]]; then
		for entry in "${SESSION_STATE_MIGRATIONS[@]}"; do
			legacy="${session_dir}/${entry%%:*}"
			if [[ -e "${legacy}" || -L "${legacy}" ]]; then
				found=1
				break
			fi
		done
		[[ "${found}" -eq 1 ]] || return 0
		mkdir -p "${state_dir}" || return 1
		chmod 700 "${state_dir%/*}" "${state_dir}" || return 1
	fi
	_with_migrate_lock "${state_dir}" _migrate_session_state_locked "${session_dir}" "${state_dir}"
}

# migrate_failed_state <session-dir> <state-dir>
#   riotbox session-migrate: retry each entry .migrated records as failed,
#   and only those, under the same lock as migrate_session_state. Only the
#   user runs this — never a launch or overlay command — so a container
#   cannot keep an import window open by forcing failures. An entry whose
#   legacy path holds nothing (see migrate_session_state) is recorded as
#   done without a retry. Before the first retry it refuses, failing closed,
#   while a live container can write the session (running_mount_reaches)
#   (_refuse_if_session_running). Otherwise the retry is the
#   migrate_legacy_state / migrate_overlay_state call the launch made, links
#   included, with --replace-empty: the launch that left the pair stranded
#   went on to create the new dir, and an empty one holds nothing to lose. A
#   success is recorded as done; a stranded result stays failed, with that
#   call's warning, plus how to resolve two copies when the new one exists.
#
#   Prints "Nothing to migrate." on stdout when no entry needed a retry.
#   Returns 0 when every retried entry moved or none needed one, 1 when any
#   is still stranded or a step failed.
migrate_failed_state() {
	local session_dir="${1:?migrate_failed_state requires a session dir}"
	local state_dir="${2:?migrate_failed_state requires a state dir}"
	if [[ ! -f "${state_dir}/.migrated" ]]; then
		echo "Nothing to migrate."
		return 0
	fi
	_with_migrate_lock "${state_dir}" _migrate_failed_state_locked "${session_dir}" "${state_dir}"
}

# notice_project_headroom <project-dir> <state-dir>
#   Once per session: for each of <project-dir>/.headroom and
#   <state-dir>/overlay/*/upper/.headroom that is a real directory, say on
#   stderr that it may hold headroom memory an older RiotBox left there, and
#   how to delete it or copy it to <state-dir>/headroom, where memory is kept
#   now. Older releases let headroom default its memory DB to the
#   container's working directory: for one project the user's checkout, or
#   in overlay mode the overlay upper. Nothing is moved or deleted: a
#   .headroom the user made with their own headroom looks the same, and
#   overlay-accept/-reject never apply or discard one in an upper
#   (OVERLAY_KEPT_NAMES). Recorded in .migrated as project-headroom-notice
#   whether or not it printed, so it is checked once. The caller holds the
#   migrate lock (_with_migrate_lock), so concurrent launches print it once.
notice_project_headroom() {
	local project="$1" state_dir="$2" name=project-headroom-notice old printed=""
	local -A recorded=() failed=()
	_read_migration_marker "${state_dir}/.migrated" recorded failed
	[[ -z "${recorded["${name}"]:-}" ]] || return 0
	for old in "${project}/.headroom" "${state_dir}"/overlay/*/upper/.headroom; do
		[[ -d "${old}" && ! -L "${old}" ]] || continue
		# A session can replace its upper with a link; the glob would follow
		# it, and the printed rm -rf would delete through it.
		if [[ "${old}" != "${project}/.headroom" ]] &&
			{ [[ -L "${old%/.headroom}" ]] || [[ -L "${old%/upper/.headroom}" ]]; }; then
			continue
		fi
		printed=1
		{
			echo "Notice: ${old} may hold headroom memory from an older RiotBox."
			if [[ "${old}" == "${project}/.headroom" ]]; then
				echo "        It was written into the project; RiotBox leaves it alone."
			else
				echo "        It was written into this session's overlay; overlay-accept never copies it into"
				echo "        the project, and overlay-reject keeps it."
			fi
			echo "        RiotBox now keeps headroom memory in ${state_dir}/headroom. To delete the old copy:"
			printf '          rm -rf -- %q\n' "${old}"
			echo "        To keep it instead, exit every RiotBox session of this project, then replace the"
			echo "        memory the new location holds (its SQLite -wal/-shm files included) with it:"
			printf '          rm -rf -- %q/memory*.db* %q && cp -a -- %q %q && rm -rf -- %q\n' \
				"${state_dir}/headroom" "${state_dir}/headroom/memories" "${old}/." "${state_dir}/headroom/" "${old}"
			if [[ "${old}" == "${project}/.headroom" ]]; then
				echo "        If .headroom/ was committed, untrack it and add it to .gitignore:"
				printf '          git -C %q rm -r --cached -- .headroom && echo .headroom/ >>%q\n' "${project}" "${project}/.gitignore"
			fi
		} >&2
	done
	[[ -z "${printed}" ]] || echo "        This notice is shown once per session." >&2
	_record_migration "${state_dir}" "${name}"
}

# _with_migrate_lock <state-dir> <command> [args...]
#   Run <command> holding an exclusive flock on <state-dir>/.migrate.lock,
#   saying so on stderr when it has to wait, and return its status. With
#   RIOTBOX_STATE_ROOT as <state-dir> that is the lock the key move
#   (migrate_session_key) and riotbox overlays take, and the message says so.
_with_migrate_lock() {
	local state_dir="$1" lock_fd rc=0
	shift
	exec {lock_fd}>"${state_dir}/.migrate.lock" || return 1
	if ! flock --nonblock "${lock_fd}"; then
		if [[ "${state_dir}" == "${RIOTBOX_STATE_ROOT:-}" ]]; then
			echo "Waiting for another RiotBox command to finish moving sessions to their new keys…" >&2
		else
			echo "Waiting for another RiotBox command on this session to finish migrating its state…" >&2
		fi
		flock --exclusive "${lock_fd}" || {
			exec {lock_fd}>&-
			return 1
		}
	fi
	# shellcheck disable=SC2310 # its status is returned after the lock is released
	"$@" || rc=$?
	exec {lock_fd}>&-
	return "${rc}"
}

# _migrate_session_state_locked <session-dir> <state-dir>
#   migrate_session_state's pass over SESSION_STATE_MIGRATIONS; the caller
#   holds the lock.
_migrate_session_state_locked() {
	local session_dir="$1" state_dir="$2"
	local entry name legacy new rc
	local -A recorded=() failed=()
	_read_migration_marker "${state_dir}/.migrated" recorded failed
	for entry in "${SESSION_STATE_MIGRATIONS[@]}"; do
		name="${entry%%:*}"
		[[ -z "${recorded["${name}"]:-}" ]] || continue
		rc=0
		if [[ "${entry}" == overlay ]]; then
			migrate_overlay_state "${session_dir}" "${state_dir}" || rc=$?
		else
			migrate_legacy_state "${session_dir}" "${state_dir}" "${entry}" || rc=$?
		fi
		case "${rc}" in
		0) _record_migration "${state_dir}" "${name}" || return 1 ;;
		2) _record_migration "${state_dir}" "${name}" "failed:${name}" || return 1 ;;
		*) return 1 ;;
		esac
		recorded["${name}"]=1
	done
	# Only entries failed before this pass: one stranded now has just warned.
	for entry in "${SESSION_STATE_MIGRATIONS[@]}"; do
		name="${entry%%:*}"
		[[ -n "${failed["${name}"]:-}" ]] || continue
		legacy="${session_dir}/${name}"
		new="${state_dir}/${entry#*:}"
		if ! _dir_has_data "${legacy}"; then
			_record_migration "${state_dir}" "${name}" || return 1
		elif [[ -e "${new}" || -L "${new}" ]] && ! _is_empty_real_dir "${new}"; then
			# shellcheck disable=SC2312 # the hint always prints something
			echo "Notice: two copies of legacy session data need resolving, ${legacy} and ${new}; run $(_session_migrate_hint "${state_dir}") to see how." >&2
		else
			# shellcheck disable=SC2312 # the hint always prints something
			echo "Notice: legacy data is still at ${legacy}; once the cause is fixed, run $(_session_migrate_hint "${state_dir}")." >&2
		fi
	done
}

# _migrate_failed_state_locked <session-dir> <state-dir>
#   migrate_failed_state's pass; the caller holds the lock.
_migrate_failed_state_locked() {
	local session_dir="$1" state_dir="$2"
	local entry name legacy new rc pending=0 stranded=0
	local -A recorded=() failed=()
	_read_migration_marker "${state_dir}/.migrated" recorded failed
	for entry in "${SESSION_STATE_MIGRATIONS[@]}"; do
		name="${entry%%:*}"
		[[ -n "${failed["${name}"]:-}" ]] || continue
		legacy="${session_dir}/${name}"
		if ! _dir_has_data "${legacy}"; then
			_record_migration "${state_dir}" "${name}" || return 1
			continue
		fi
		if [[ "${pending}" -eq 0 ]]; then
			# This narrows the race with a launch, but does not close it: a
			# launch holds .migrate.lock only inside migrate_session_state,
			# so one already past it whose container is not created yet is
			# not seen. The README says not to launch during a retry.
			_refuse_if_session_running "${session_dir}" "${state_dir}" || return 1
		fi
		pending=1
		rc=0
		if [[ "${entry}" == overlay ]]; then
			migrate_overlay_state --replace-empty "${session_dir}" "${state_dir}" || rc=$?
		else
			migrate_legacy_state --replace-empty "${session_dir}" "${state_dir}" "${entry}" || rc=$?
		fi
		case "${rc}" in
		0) _record_migration "${state_dir}" "${name}" || return 1 ;;
		2)
			stranded=1
			new="${state_dir}/${entry#*:}"
			if [[ -e "${new}" || -L "${new}" ]]; then
				echo "         RiotBox cannot merge the two copies. Exit every session of this project, then compare them:" >&2
				printf '           diff -rq %q %q\n' "${legacy}" "${new}" >&2
				echo "         Keep what you need, then delete one side (deleting ${legacy} keeps ${new}; delete or move aside ${new} to use ${legacy} instead) and run riotbox session-migrate again." >&2
				echo "         See README.md, \"Upgrading from a release that kept state in the session directory\", for how to read the diff." >&2
			fi
			;;
		*) return 1 ;;
		esac
	done
	[[ "${pending}" -eq 1 ]] || echo "Nothing to migrate."
	[[ "${stranded}" -eq 0 ]] || return 1
}

# _read_migration_marker <marker> <recorded-array> <failed-array>
#   Fill the caller's two associative arrays from <marker> (format: see
#   migrate_session_state): every name a line mentions in <recorded-array>,
#   and in <failed-array> those whose last line is failed:<name>. A missing
#   marker records nothing; a last line without a newline still counts.
_read_migration_marker() {
	local marker="$1" line name
	local -n _marker_recorded="$2" _marker_failed="$3"
	[[ -f "${marker}" ]] || return 0
	while IFS= read -r line || [[ -n "${line}" ]]; do
		name="${line#failed:}"
		[[ -n "${name}" ]] || continue
		_marker_recorded["${name}"]=1
		if [[ "${line}" == failed:* ]]; then
			_marker_failed["${name}"]=1
		else
			_marker_failed["${name}"]=""
		fi
	done <"${marker}"
}

# _record_migration <state-dir> <line>...
#   Append each <line> to <state-dir>/.migrated. The top of the state dir is
#   host-only, so a temp file and a rename are enough to keep .migrated whole
#   if this is interrupted. The existing content gets its missing final
#   newline first.
_record_migration() {
	local state_dir="$1" marker="$1/.migrated" tmp
	shift
	tmp="$(mktemp "${state_dir}/.migrated.XXXXXX")" || return 1
	# shellcheck disable=SC2312 # a failed tail adds a newline at worst, which reads as nothing
	if ! { if [[ -f "${marker}" ]]; then
		cat -- "${marker}" && { [[ -z "$(tail -c 1 -- "${marker}")" ]] || echo; }
	fi >"${tmp}" &&
		printf '%s\n' "$@" >>"${tmp}" &&
		mv -T -- "${tmp}" "${marker}"; }; then
		rm -f -- "${tmp}"
		return 1
	fi
}

# _dir_has_data <path>
#   True when <path> is a real directory, not a link, that holds at least
#   one entry, or that cannot be listed: an unreadable directory may be the
#   very cause of a failed move, and must not be taken for empty.
_dir_has_data() {
	local path="$1" first
	[[ -d "${path}" && ! -L "${path}" ]] || return 1
	first="$(find "${path}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 0
	[[ -n "${first}" ]]
}

# _is_empty_real_dir <path>
#   True when <path> is a real directory, not a link, that lists as empty.
_is_empty_real_dir() {
	[[ -d "$1" && ! -L "$1" ]] && ! _dir_has_data "$1"
}

# _session_migrate_hint <state-dir>
#   Print how to run riotbox session-migrate for the session: the command
#   with its project paths from the host-only record (recorded_projects),
#   else, for a session without one, where to run it.
_session_migrate_hint() {
	local projects
	local -a paths=()
	if projects="$(recorded_projects "$1")"; then
		mapfile -t paths <<<"${projects}"
		# shellcheck disable=SC2312 # quoting cannot fail
		printf 'riotbox session-migrate %s\n' "$(quote_words "${paths[@]}")"
	else
		echo "riotbox session-migrate from the project's directory (pass every project of a multi-project session)"
	fi
}

# _refuse_if_session_running <session-dir> <state-dir> [<mover> <retry>]
#   Return non-zero, saying why, unless the engine confirms that no live
#   container has a read-write mount that reaches the session dir or the
#   state dir (running_session_mounts, running_mount_reaches: either way
#   for a RiotBox-labelled container, only at or below them for any other). A retry moves the legacy dir and
#   may replace the new one, so a running session would keep writing into a
#   dir that is no longer where RiotBox looks, and those writes would be
#   lost. Fails closed: an engine that cannot answer is a refusal. <mover>
#   names what refuses (default session-migrate) and <retry> what to do once
#   the session has exited (default: run riotbox session-migrate again).
_refuse_if_session_running() {
	local session_dir="$1" state_dir="$2" session state session_lexical state_lexical label projects i id
	local mover="${3:-session-migrate}" retry="${4:-run riotbox session-migrate again}"
	local -a paths=() holders=() mounts=()
	local -A held=()
	if projects="$(recorded_projects "${state_dir}")"; then
		mapfile -t paths <<<"${projects}"
		label="$(quote_words "${paths[@]}")"
	else
		label="${session_dir}"
	fi
	session="$(realpath -m -- "${session_dir}")" || return 1
	state="$(realpath -m -- "${state_dir}")" || return 1
	session_lexical="$(realpath -ms -- "${session_dir}")" || return 1
	state_lexical="$(realpath -ms -- "${state_dir}")" || return 1
	if ! running_session_mounts; then
		echo "ERROR: could not ask '${CONTAINER_CMD:-podman}' whether a running container mounts the session of ${label}." >&2
		echo "       ${mover} refuses while it cannot tell: a running session can still write to what it would move." >&2
		echo "       Make sure the container engine works (and that the session has exited), then retry." >&2
		return 1
	fi
	for i in "${!RUNNING_MOUNT_IDS[@]}"; do
		id="${RUNNING_MOUNT_IDS[i]}"
		# shellcheck disable=SC2310 # a predicate designed for conditions
		if running_mount_reaches "${i}" "${session}" "${session_lexical}" ||
			running_mount_reaches "${i}" "${state}" "${state_lexical}"; then
			if [[ -z "${held["${id}"]:-}" ]]; then
				held["${id}"]=1
				holders+=("$(running_mount_label "${i}")")
				mounts+=("${RUNNING_MOUNT_SOURCES[i]}")
			fi
		fi
	done
	if [[ "${#holders[@]}" -gt 0 ]]; then
		for i in "${!holders[@]}"; do
			echo "ERROR: container ${holders[i]} mounts ${mounts[i]} read-write, which reaches the session of ${label}, and is still running." >&2
		done
		echo "       It can still write to what ${mover} would move. Stop that container (exit its session), then ${retry}." >&2
		return 1
	fi
}

# recorded_projects <state-dir>
#   Print the project paths the launch recorded (record_projects). Returns 1
#   when there is no record: the session was last launched by an older
#   RiotBox, or never.
recorded_projects() {
	local file="$1/projects" line rc=1
	[[ -f "${file}" && ! -L "${file}" ]] || return 1
	while IFS= read -r line; do
		if [[ -n "${line}" ]]; then
			printf '%s\n' "${line}"
			rc=0
		fi
	done <"${file}"
	return "${rc}"
}

# is_session <session-dir> <state-dir>
#   True when <session-dir> is a RiotBox session: it is a directory that
#   carries the .projects marker setup_projects writes, or whose <state-dir>
#   carries the launch's project record (record_projects). Session commands act only on what passes, so
#   the rootless app tree and backups/ beside the sessions are never touched.
#   The record matters because a running session can replace its own
#   .projects (with a directory, say) to hide from those commands until its
#   next launch; the record sits in the state dir itself, which the container
#   cannot reach. .projects still counts alone: a session an older RiotBox
#   last launched has no record.
is_session() {
	[[ -d "$1" ]] && { [[ -f "$1/.projects" ]] || [[ -f "$2/projects" && ! -L "$2/projects" ]]; }
}

# quote_words <word>...
#   Print the words shell-quoted and space-separated, by printf %q under
#   LC_ALL=C, so control and non-ASCII bytes come out escaped: a path pasted
#   back is exactly that path, and no byte reaches the terminal raw.
quote_words() {
	local word line=""
	for word in "$@"; do
		line="${line:+${line} }$(LC_ALL=C printf '%q' "${word}")"
	done
	printf '%s\n' "${line}"
}

# session_projects <session-dir>
#   Print the non-empty lines of <session-dir>/.projects, the project paths
#   setup_projects records at launch. The container can replace .projects
#   with anything at any moment, so this returns 1, printing nothing, when it
#   is not a regular file, when it cannot be read without following a link,
#   or when it holds no non-empty line; callers then show the session's
#   projects as unknown. The content is still container-written: pass it
#   through terminal_clean before printing it.
session_projects() {
	local file="${1:?session_projects requires a session dir}/.projects"
	local content line rc=1
	# Reports a plain link, FIFO or directory as refused without opening it.
	[[ -f "${file}" && ! -L "${file}" ]] || return 1
	# The entry can still be swapped after that test, so the one open is
	# what enforces it: nofollow fails on a link (ELOOP), nonblock keeps a
	# FIFO from blocking the open or the read, a directory fails the read,
	# and count=1 caps the read at 64 KiB however large the file is. NULs
	# are dropped here, before bash would warn about them.
	# shellcheck disable=SC2312 # dd's status is returned through PIPESTATUS
	content="$(
		dd if="${file}" iflag=nofollow,nonblock bs=64K count=1 status=none 2>/dev/null | tr -d '\000'
		exit "${PIPESTATUS[0]}"
	)" || return 1
	while IFS= read -r line; do
		if [[ -n "${line}" ]]; then
			printf '%s\n' "${line}"
			rc=0
		fi
	done <<<"${content}"
	return "${rc}"
}

# terminal_clean line|text
#   Copy stdin to stdout line by line with every terminal control and bidi
#   character replaced by "?" (scripts/lib/terminal-clean.jq). "line" is for
#   single-line values such as a path (clean); "text" keeps tabs, for
#   multi-line content such as a diff (clean_text).
terminal_clean() {
	local filter
	case "${1:?terminal_clean requires a mode: line or text}" in
	line) filter=clean ;;
	text) filter=clean_text ;;
	*)
		echo "terminal_clean: unknown mode: $1" >&2
		return 1
		;;
	esac
	jq -Rr -L "${_SESSION_STATE_LIB_DIR}" "include \"terminal-clean\"; ${filter}"
}
