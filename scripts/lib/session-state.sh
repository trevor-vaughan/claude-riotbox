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
# Sourced on the host by scripts/mount-projects.sh and
# agents/{claude,opencode,pi}/sync-settings.sh.
#
# Public:
#   ensure_real_dir <dir>
#   require_real_dir <dir>
#   valid_session_key <key>
#   replace_entry <staged> <dest>
#   migrate_session_state <session-dir> <state-dir>
#   migrate_failed_state <session-dir> <state-dir>
#   notice_project_headroom <project-dir> <state-dir>
#   session_projects <session-dir>
#   recorded_projects <state-dir>
#   quote_words <word>...
#   terminal_clean
# ─────────────────────────────────────────────────────────────────────────────

# Resolved now: a caller may change directory before calling terminal_clean.
_SESSION_STATE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/riotbox-core.sh
source "${_SESSION_STATE_LIB_DIR}/riotbox-core.sh"

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

# valid_session_key <key>
#   True when <key> can name a session: one path component, so that
#   <root>/<key> stays inside <root>. Non-empty, not "." or "..", and no "/".
#   Session commands check this before building a path they will rm -rf.
#   riotbox-core migrate-key applies the same rule to each --legacy-key
#   (migrateKey in cmd/riotbox-core/main.go); change both together.
valid_session_key() {
	[[ -n "$1" && "$1" != "." && "$1" != ".." && "$1" != */* ]]
}

# replace_entry <staged> <dest>
#   Rename <staged> onto <dest> without following a link at <dest>, for
#   entries a running container can replace at any moment. rename(2)
#   replaces a link or other non-directory instead of following it, but
#   cannot replace a directory with a file or a non-empty directory with a
#   directory. So the old copy of a staged directory is removed first, and
#   so is anything but a regular file at a staged file's destination: the
#   entry itself, never what it points at, with a warning on stderr. A link
#   or FIFO there would be replaced anyway; it is removed first only so the
#   warning names it. If an entry is re-planted after that removal, the
#   rename fails (EISDIR, ENOTDIR or ENOTEMPTY) rather than following a link
#   or merging into a directory.
#
#   Returns 1 when <dest> could not be removed (nothing is renamed), and 2
#   when the rename failed (<staged> is left for the caller to clean up).
#   Prints no error of its own beyond rm's or mv's: the caller knows what
#   the entry is.
replace_entry() {
	local staged="$1" dest="$2"
	if [[ -d "${staged}" ]]; then
		rm -rf -- "${dest}" || return 1
	elif [[ -L "${dest}" ]] || { [[ -e "${dest}" ]] && [[ ! -f "${dest}" ]]; }; then
		echo "Warning: ${dest} is not a regular file; removing it." >&2
		rm -rf -- "${dest}" || return 1
	fi
	mv -T -- "${staged}" "${dest}" || return 2
}

# migrate_session_state <session-dir> <state-dir>
#   The one-time migration of a session dir an older RiotBox left behind:
#   each pair riotbox-core's list holds (headroom, git-ai, .config-opencode,
#   .local-share-opencode, .pi-agent, overlay) that <state-dir>/.migrated
#   does not list yet, recorded after it runs, under the flock on
#   <state-dir>/.migrate.lock. The entry point for launches and overlay
#   commands. Returns 1 when a step failed; that pair stays unrecorded and
#   the next call retries it. Run by riotbox-core migrate-state; the rules,
#   the marker format and the invariant (a recorded pair is never imported
#   again) are in internal/migrate.
migrate_session_state() {
	local session_dir="${1:?migrate_session_state requires a session dir}"
	local state_dir="${2:?migrate_session_state requires a state dir}"
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" migrate-state --lib-dir "${_RIOTBOX_CORE_ROOT}/scripts/lib" -- "${session_dir}" "${state_dir}"
}

# migrate_failed_state <session-dir> <state-dir>
#   riotbox session-migrate: retry each pair .migrated records as failed,
#   and only those, under the same lock as migrate_session_state. Refuses,
#   failing closed, while a live container (CONTAINER_CMD, default podman)
#   can write the session. Prints "Nothing to migrate." on stdout when no
#   pair needed a retry. Returns 0 when every retried pair moved or none
#   needed one, 1 when any is still stranded or a step failed. Run by
#   riotbox-core migrate-failed; see internal/migrate.
migrate_failed_state() {
	local session_dir="${1:?migrate_failed_state requires a session dir}"
	local state_dir="${2:?migrate_failed_state requires a state dir}"
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" migrate-failed --lib-dir "${_RIOTBOX_CORE_ROOT}/scripts/lib" \
		--engine "${CONTAINER_CMD:-podman}" -- "${session_dir}" "${state_dir}"
}

# notice_project_headroom <project-dir> <state-dir>
#   Once per session: say on stderr where headroom memory an older RiotBox
#   left in <project-dir>/.headroom or an overlay upper may be, and how to
#   delete it or copy it to <state-dir>/headroom. Nothing is moved or
#   deleted. Recorded in .migrated as project-headroom-notice whether or not
#   it printed, under the session's migrate lock, which it takes itself.
#   Returns 1 when the check could not be recorded. Run by riotbox-core
#   headroom-notice; see internal/migrate.
notice_project_headroom() {
	local project_dir="${1:?notice_project_headroom requires a project dir}"
	local state_dir="${2:?notice_project_headroom requires a state dir}"
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" headroom-notice --lib-dir "${_RIOTBOX_CORE_ROOT}/scripts/lib" -- "${project_dir}" "${state_dir}"
}

# _with_migrate_lock <state-dir> <command> [args...]
#   Run <command> holding an exclusive flock on a session's
#   <state-dir>/.migrate.lock, saying so on stderr when it has to wait, and
#   return its status. riotbox-core's internal/lock takes the same lock, so
#   bash and Go callers exclude each other.
_with_migrate_lock() {
	local state_dir="$1" lock_fd rc=0
	shift
	exec {lock_fd}>"${state_dir}/.migrate.lock" || return 1
	if ! flock --nonblock "${lock_fd}"; then
		echo "Waiting for another RiotBox command on this session to finish migrating its state…" >&2
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

# recorded_projects <state-dir>
#   Print the project paths the launch recorded (record_projects). Returns 1
#   when there is no record: the session was last launched by an older
#   RiotBox, or never. A record that is a link or not a regular file counts
#   as none. Read by riotbox-core recorded-projects; see
#   docs/dev/riotbox-core.md.
recorded_projects() {
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" recorded-projects -- "$1"
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
#   last launched has no record. Decided by riotbox-core is-session; see
#   internal/records. Callers run riotbox_core_require once first: a
#   missing binary would make every dir read as "not a session". It is not
#   checked here, as session loops call this once per dir; a binary that
#   cannot run still returns non-zero, so nothing is taken for a session.
is_session() {
	"${RIOTBOX_CORE}" is-session -- "$1" "$2"
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
#   through terminal_clean before printing it. Read by riotbox-core
#   session-projects with one no-follow, non-blocking read of at most 64 KiB,
#   NULs dropped; see docs/dev/riotbox-core.md.
session_projects() {
	local dir="${1:?session_projects requires a session dir}"
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" session-projects -- "${dir}"
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
