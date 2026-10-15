#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mount-projects.sh — Resolves project directories into container mount flags.
#
# Two invocation modes:
#
#   1. Sourced (existing taskfile scripts). Sets these variables:
#        PROJECT_DIRS         — bash array of resolved host paths
#        PROJECT_VOLUME_FLAGS — -v flags for podman/docker run (includes
#                               riotbox session mount)
#        PROJECT_SUMMARY      — human-readable list for status output
#        WORKDIR              — container working directory
#        CONTAINER_NAME       — unique container name for --name flag
#        RIOTBOX_SESSION_DIR  — host-side session directory path
#        RIOTBOX_STATE_DIR    — host-side state directory path (every other
#                               mount source; see scripts/lib/session-state.sh)
#
#   2. Executed (downstream config generators / tests). Accepts:
#        --format=podman   one `-v host:container[:flag]` line per mount
#                          (default; matches sourced PROJECT_VOLUME_FLAGS).
#        --format=triple   one `host:container:mode` line per mount, where
#                          mode is `rw` or `ro`.
#      Project paths come from "$@" (after flags) or RIOTBOX_PROJECTS.
#
# Single project:  mounted at /workspace (backward compatible)
# Multiple projects: each mounted at /workspace/<dirname>
# No projects:     current directory mounted at /workspace
#
# LIMITATION: Project paths must not contain spaces. Volume flags are
# accumulated as a flat string and word-split at the container run call.
# This is a deliberate tradeoff for simplicity — paths with spaces are
# extremely uncommon for development project directories.
# ─────────────────────────────────────────────────────────────────────────────

# shellcheck source=scripts/lib/session-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/session-state.sh"
# shellcheck source=scripts/lib/overlay-ignore.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/overlay-ignore.sh"

# Compute the canonical multi-project identity components.
#
# Emits three lines on stdout:
#   1. first_seg  — sed-mangled basename of the lexically first path
#   2. n_more     — count of remaining paths after the first
#   3. hash8      — first 8 hex chars of sha256 of the canonical form
#
# The canonical hash input is the sorted paths with `/` → `-`, any leading
# `-` stripped, joined by `+`. The container name and session directory
# basename are both derived from this output so a project set carries a
# single identity across the runtime container and its on-disk store.
# Callers consume the three lines with a grouped `read` block.
compute_multi_project_identity() {
	local -a sorted=()
	local sorted_line
	# shellcheck disable=SC2312 # sort failure is impossible on in-memory input
	while IFS= read -r sorted_line; do
		sorted+=("${sorted_line}")
	done < <(printf '%s\n' "$@" | LC_ALL=C sort)

	local first_seg
	first_seg="$(basename "${sorted[0]}")"
	first_seg="$(printf '%s' "${first_seg}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//')"

	local n_more=$((${#sorted[@]} - 1))
	local hash_input hash8
	hash_input="$(printf '%s\n' "${sorted[@]}" | sed 's|/|-|g; s|^-||' | paste -sd'+' -)"
	hash8="$(printf '%s' "${hash_input}" | sha256sum | cut -c1-8)"

	printf '%s\n%s\n%s\n' "${first_seg}" "${n_more}" "${hash8}"
}

# Generate a unique container name from project paths.
#
# Single-project: builds from the leaf (basename) upward, walking parent
# segments only when an existing container already owns the candidate name.
# A random suffix is appended if the path is fully consumed.
#
# Multi-project: emits `riotbox-<first_basename>-<N>more-<hash8>` using the
# identity from compute_multi_project_identity. The hash is what makes the
# name unique — naive basename concatenation overflowed the 64-char cap and
# the left-truncation that followed silently collapsed distinct project
# sets that happened to share a trailing run of basenames into one name.
#
# CONTAINER_CMD must be set by the caller (podman or docker) for the
# single-project disambiguation probe.
generate_container_name() {
	local -a dirs=("$@")
	local max_len=64
	local prefix="riotbox"

	if [[ ${#dirs[@]} -eq 0 ]]; then
		# shellcheck disable=SC2034  # used by caller after sourcing
		CONTAINER_NAME="${prefix}"
		return
	fi

	# ── Multi-project ────────────────────────────────────────────────
	if [[ ${#dirs[@]} -gt 1 ]]; then
		local first_seg n_more hash8
		# shellcheck disable=SC2312 # compute_multi_project_identity always succeeds for non-empty input
		{
			read -r first_seg
			read -r n_more
			read -r hash8
		} < <(compute_multi_project_identity "${dirs[@]}")

		local suffix="-${n_more}more-${hash8}"
		local readable_max=$((max_len - ${#prefix} - 1 - ${#suffix}))
		if [[ "${#first_seg}" -gt "${readable_max}" ]]; then
			first_seg="${first_seg:0:${readable_max}}"
		fi
		# shellcheck disable=SC2034  # used by caller after sourcing
		CONTAINER_NAME="${prefix}-${first_seg}${suffix}"
		return
	fi

	# ── Single-project ───────────────────────────────────────────────
	local base
	base="$(basename "${dirs[0]}")"

	local first_dir="${dirs[0]}"
	local -a segments=()
	local tmp="${first_dir}"
	while [[ "${tmp}" != "/" ]] && [[ -n "${tmp}" ]]; do
		segments=("$(basename "${tmp}")" "${segments[@]}")
		tmp="$(dirname "${tmp}")"
	done

	local candidate="${prefix}-${base}"
	candidate="$(printf '%s' "${candidate}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g')"

	local base_idx=$((${#segments[@]} - 1))
	local depth=0
	while ${CONTAINER_CMD:-podman} ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${candidate}"; do
		depth=$((depth + 1))
		local parent_idx=$((base_idx - depth))
		if [[ "${parent_idx}" -lt 0 ]]; then
			candidate="${candidate}-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"
			break
		fi
		candidate="${prefix}-${segments[${parent_idx}]}-${base}"
		candidate="$(printf '%s' "${candidate}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g')"
	done

	if [[ ${#candidate} -gt "${max_len}" ]]; then
		candidate="${candidate: -${max_len}}"
		candidate="${candidate#"${candidate%%[a-zA-Z0-9]*}"}"
	fi

	# shellcheck disable=SC2034  # used by caller after sourcing
	CONTAINER_NAME="${candidate}"
}

# Set the two per-user roots every session lives under, from XDG_DATA_HOME:
#   RIOTBOX_DATA_DIR    session dirs (each mounted at ~/.claude) and backups/;
#                       on a rootless install, the app tree as well
#   RIOTBOX_STATE_ROOT  one state dir per session (scripts/lib/session-state.sh)
# plus the Context Mode ledger root shared by every session:
#   RIOTBOX_LEDGER_ROOT $RIOTBOX_CONTEXT_LEDGER, else beside the other two
# The one place any of them is spelled out for the launch and the session
# commands, which call this rather than deriving the paths again
# (scripts/ctx-stats.sh does not source this file and keeps its own ledger
# default).
resolve_data_roots() {
	local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
	RIOTBOX_DATA_DIR="${data_home}/riotbox"
	RIOTBOX_STATE_ROOT="${data_home}/riotbox-state"
	RIOTBOX_LEDGER_ROOT="${RIOTBOX_CONTEXT_LEDGER:-${data_home}/riotbox-context-mode}"
}

# Lightweight resolver: populates PROJECT_DIRS, PROJECT_SUMMARY,
# RIOTBOX_SESSION_DIR and RIOTBOX_STATE_DIR (plus the three roots from
# resolve_data_roots) without creating dirs, copying files, or spawning
# container commands. Used by recipes that only need the session path.
resolve_projects() {
	local raw_projects="$1"
	PROJECT_DIRS=()
	PROJECT_SUMMARY=""

	# Default to current directory if no projects specified
	if [[ -z "${raw_projects}" ]]; then
		raw_projects="$(pwd)"
	fi

	# Resolve each path to absolute, canonicalising symlinks so the same
	# project reached via different paths produces the same session key.
	# Disable globbing so paths with metacharacters (*, ?) aren't expanded.
	# Paths are space-separated by design (CLI args joined by the caller).
	local _old_glob
	_old_glob="$(shopt -po noglob 2>/dev/null || true)"
	set -f
	for p in ${raw_projects}; do
		local resolved
		if ! resolved="$(cd "${p}" 2>/dev/null && pwd -P)"; then
			eval "${_old_glob}"
			echo "ERROR: project path does not exist or is not a directory: ${p}" >&2
			return 1
		fi
		if [[ "${resolved}" -ef / ]]; then
			eval "${_old_glob}"
			echo "riotbox: refusing to use / as a project: its session dir would be the RiotBox data dir itself" >&2
			return 1
		fi
		PROJECT_DIRS+=("${resolved}")
	done
	eval "${_old_glob}"

	if [[ ${#PROJECT_DIRS[@]} -eq 1 ]]; then
		PROJECT_SUMMARY="${PROJECT_DIRS[0]}"
	else
		for dir in "${PROJECT_DIRS[@]}"; do
			local name
			name="$(basename "${dir}")"
			if [[ -n "${PROJECT_SUMMARY}" ]]; then
				PROJECT_SUMMARY="${PROJECT_SUMMARY}, ${name}"
			else
				PROJECT_SUMMARY="${name}"
			fi
		done
		PROJECT_SUMMARY="${#PROJECT_DIRS[@]} projects: ${PROJECT_SUMMARY}"
	fi

	# ── Session key ───────────────────────────────────────────────────
	# Single-project keeps the human-readable, path-mangled key so
	# list-sessions output and the test helpers in tests/lib/ remain
	# decodable by reversing the `s|/|-|g` mangling. Multi-project uses
	# the same hashed identity as the container name — naive
	# concatenation of N path-mangled segments overflows NAME_MAX (255)
	# on every supported filesystem for non-trivial project sets, and
	# mkdir fails with ENAMETOOLONG.
	local session_key
	resolve_data_roots
	if [[ ${#PROJECT_DIRS[@]} -le 1 ]]; then
		session_key="$(printf '%s\n' "${PROJECT_DIRS[@]}" | sed 's|/|-|g; s|^-||')"
	else
		local first_seg n_more hash8
		# shellcheck disable=SC2312 # compute_multi_project_identity always succeeds for non-empty input
		{
			read -r first_seg
			read -r n_more
			read -r hash8
		} < <(compute_multi_project_identity "${PROJECT_DIRS[@]}")
		session_key="${first_seg}-${n_more}more-${hash8}"
	fi
	RIOTBOX_SESSION_DIR="${RIOTBOX_DATA_DIR}/${session_key}"
	RIOTBOX_STATE_DIR="${RIOTBOX_STATE_ROOT}/${session_key}"
}

# record_projects <previous .projects>
#   Record PROJECT_DIRS in <state dir>/projects, one path per line (the
#   format of the session dir's .projects), staged in the state dir and
#   renamed into place. The state dir's top level is never mounted, so this
#   record, unlike .projects, is the host's own: the overlay commands trust
#   only it (see recorded_projects). Session keys are not unique per set
#   (resolve_projects maps "/" to "-"), so a record can name a different set
#   than this launch's:
#   - while the session holds pending overlay changes it is kept, with a
#     warning, since those changes belong to the recorded set;
#   - otherwise it is replaced, with a warning.
#   A session an older RiotBox left with pending changes has no record, and
#   this launch's set is recorded. When the set <previous .projects> named
#   (what the session dir's .projects held before this launch rewrote it;
#   container-written, so shown cleaned and never as a command) differs,
#   a warning says the changes may belong to that set instead.
#   setup_projects runs this under the session's .migrate.lock
#   (_with_migrate_lock), so concurrent launches cannot interleave the
#   read, the check and the rename.
record_projects() {
	local previous="$1" record="${RIOTBOX_STATE_DIR}/projects" tmp recorded current
	current="$(printf '%s\n' "${PROJECT_DIRS[@]}")"
	# shellcheck disable=SC2310 # predicates designed for conditions
	if recorded="$(recorded_projects "${RIOTBOX_STATE_DIR}")"; then
		if ! same_project_set "${recorded}" "${current}"; then
			if overlay_state_pending "${RIOTBOX_STATE_DIR}"; then
				{
					echo "Warning: this session has pending overlay changes made for another project set"
					echo "         with the same session key; they stay recorded for that set:"
					printf '%s\n' "${recorded}" | _record_indent
				} >&2
				return 0
			fi
			{
				echo "Warning: replacing this session's recorded project set: another set with the"
				echo "         same session key was recorded for it before:"
				printf '%s\n' "${recorded}" | _record_indent
			} >&2
		fi
	elif [[ -n "${previous}" ]] && ! same_project_set "${previous}" "${current}" &&
		overlay_state_pending "${RIOTBOX_STATE_DIR}"; then
		{
			echo "Warning: this session has pending overlay changes but no recorded project set"
			echo "         (an older RiotBox launched it). Its .projects, which the session itself"
			echo "         can rewrite, names a different set; the changes may belong to it:"
			printf '%s\n' "${previous}" | terminal_clean line | _record_indent
			echo "         This launch records its own set. If the changes were made for the set"
			echo "         above, reject them, or delete ${record} and launch that set instead."
		} >&2
	fi
	tmp="$(mktemp "${RIOTBOX_STATE_DIR}/.projects.XXXXXX")" || return 1
	if ! printf '%s\n' "${PROJECT_DIRS[@]}" >"${tmp}" || ! mv -T -- "${tmp}" "${record}"; then
		rm -f -- "${tmp}"
		echo "Error: could not record the project list in ${record}; aborting." >&2
		return 1
	fi
}

# _record_indent
#   Print each line of stdin indented, for the path lists in record_projects'
#   warnings.
_record_indent() {
	local line
	while IFS= read -r line; do
		printf '           %s\n' "${line}"
	done
}

# same_project_set <list> <list>
#   Exit 0 when two newline-separated path lists name the same set.
same_project_set() {
	# shellcheck disable=SC2312 # sort cannot fail on in-memory input
	[[ "$(printf '%s\n' "$1" | LC_ALL=C sort -u)" == "$(printf '%s\n' "$2" | LC_ALL=C sort -u)" ]]
}

# overlay_project_names <dir>...
#   Set OVERLAY_NAMES, parallel to the arguments (a resolved project set in
#   PROJECT_DIRS order), to the name each project's overlay carries in
#   overlay mode: its dir under <state dir>/overlay/ and its mounts under
#   /mnt/lower/ and /mnt/overlay/ (container/overlay-setup.sh pairs those
#   by name). A single project is "project"; in a set, each is its
#   basename, so two members with one basename get one name, which the
#   container engine refuses to mount twice.
overlay_project_names() {
	local dir
	OVERLAY_NAMES=()
	if [[ $# -eq 1 ]]; then
		OVERLAY_NAMES=(project)
		return 0
	fi
	for dir in "$@"; do
		OVERLAY_NAMES+=("$(basename "${dir}")")
	done
}

# overlay_command <verb> <dir>...
#   Print the `riotbox overlay-<verb>` command line for a project set, every
#   path quoted (quote_words).
overlay_command() {
	local verb="$1"
	shift
	# shellcheck disable=SC2312 # quoting cannot fail
	printf 'riotbox overlay-%s %s\n' "${verb}" "$(quote_words "$@")"
}

# member_set_hint <subcommand> <dir>
#   After <dir> alone resolved to no session: print, on stderr, the command
#   `riotbox <subcommand>` for each multi-project session whose recorded set
#   (record_projects) lists <dir>, since such a session is reached only
#   through the whole set. The container-written .projects is never
#   consulted.
member_set_hint() {
	local subcommand="$1" dir="$2" state projects member
	local -a members
	for state in "${RIOTBOX_STATE_ROOT}"/*/; do
		# shellcheck disable=SC2310 # a session without a record names no set
		projects="$(recorded_projects "${state%/}")" || continue
		mapfile -t members <<<"${projects}"
		[[ "${#members[@]}" -gt 1 ]] || continue
		for member in "${members[@]}"; do
			if [[ "${member}" == "${dir}" ]]; then
				echo "It is part of a multi-project session; name the whole set:" >&2
				# shellcheck disable=SC2312 # quoting cannot fail
				echo "    riotbox ${subcommand} $(quote_words "${members[@]}")" >&2
				break
			fi
		done
	done
}

# Warn, on stderr, about each project in PROJECT_DIRS that contains one of
# the data roots from resolve_data_roots. Mounting such a project hands the
# container every session's data and, on a rootless install, the RiotBox
# scripts that run on the host. The user chose a warning over a refusal.
#
# A project contains a root when the real path of the root, or of any
# directory on the way to it, lies in the project (PROJECT_DIRS holds real
# paths): a project holding a symlink on the way to a root can swap that
# link, and one holding the link's target holds the data. A project inside
# a root is not reported. Each ancestor is resolved by realpath as written,
# `..` included, because `lnk/..` is the link target's parent, not the
# directory holding `lnk`; only `//` and a trailing `/` are tidied first.
# The real paths are computed once per root (one realpath call each), so
# the per-project check is string comparison only.
warn_projects_containing_data() {
	local root path ancestor real label proj hits i k warned=0
	local -a chain labels=() anc_paths=() anc_roots=()
	local seen=$'\n'
	for root in "${RIOTBOX_DATA_DIR}" "${RIOTBOX_STATE_ROOT}" "${RIOTBOX_LEDGER_ROOT}"; do
		path="${root}"
		[[ "${path}" == /* ]] || path="${PWD}/${path}"
		while [[ "${path}" == *//* ]]; do
			path="${path//\/\///}"
		done
		path="${path%/}"
		# A root of / tidies to nothing; no project can be /, so it holds nothing to report.
		[[ -n "${path}" ]] || continue
		chain=()
		ancestor="${path}"
		while [[ -n "${ancestor}" ]]; do
			chain+=("${ancestor}")
			ancestor="${ancestor%/*}"
		done
		# NUL-separated, so a newline in a path cannot shift the list.
		# shellcheck disable=SC2312 # realpath -m fails only without operands, and chain holds at least one
		mapfile -d '' -t chain < <(realpath -z -m -- "${chain[@]}")
		real="${chain[0]}"
		# Two roots that are one directory (e.g. the ledger set to the data dir) are listed once.
		[[ "${seen}" != *$'\n'"${real}"$'\n'* ]] || continue
		seen="${seen}${real}"$'\n'
		label="${path}"
		[[ "${real}" == "${path}" ]] || label="${path} -> ${real}"
		labels+=("${label}")
		for ancestor in "${chain[@]}"; do
			anc_paths+=("${ancestor}")
			anc_roots+=("$((${#labels[@]} - 1))")
		done
	done
	for proj in "${PROJECT_DIRS[@]}"; do
		hits=""
		i=-1
		for k in "${!anc_paths[@]}"; do
			# anc_paths is grouped by root; one match lists that root.
			[[ "${anc_roots[k]}" != "${i}" ]] || continue
			if [[ "${anc_paths[k]}" == "${proj}" || "${anc_paths[k]}" == "${proj}/"* ]]; then
				i="${anc_roots[k]}"
				hits="${hits}        ${labels[i]}"$'\n'
			fi
		done
		if [[ -n "${hits}" ]]; then
			warned=1
			{
				echo "WARN: project ${proj} contains RiotBox data:"
				printf '%s' "${hits}"
			} >&2
		fi
	done
	if [[ "${warned}" == 1 ]]; then
		{
			echo "      Inside the container, other sessions' data and, on a rootless install,"
			echo "      RiotBox's own scripts (which run on your host) become readable and,"
			echo "      unless the project is mounted read-only or as an overlay, writable."
			echo "      Where a project holds only a link to that data, the session cannot"
			echo "      read the data but can replace the link."
			echo "      Use a narrower project directory that does not contain these paths."
		} >&2
	fi
}

# Return 0 if the given path should be treated as not-owned by the host
# user (i.e. ineligible for `:z` relabel; routed to podman's `:O` overlay).
#
# Production gate: the path's owner UID differs from the effective UID.
# Test seam via RIOTBOX_FORCE_UNOWNED_MOUNTS:
#   ""            production check (`[ ! -O "$p" ]`)
#   "1"           sledgehammer — every path treated as unowned
#   "/a:/b:…"     literal colon-separated path list — only listed paths
#                 treated as unowned; other paths fall through to the
#                 production check
#
# The dual-mode seam exists because venom tests cannot create
# root-owned fixtures without sudo. The path-list form covers the true
# mixed case (owned + unowned in the same project set), which is the
# most interesting per-dir branching scenario.
_mount_path_is_unowned() {
	local p="$1"
	case "${RIOTBOX_FORCE_UNOWNED_MOUNTS:-}" in
	1)
		return 0
		;;
	"")
		[[ ! -O "${p}" ]]
		;;
	*)
		[[ ":${RIOTBOX_FORCE_UNOWNED_MOUNTS}:" == *":${p}:"* ]]
		;;
	esac
}

setup_projects() {
	local raw_projects="$1"
	PROJECT_VOLUME_FLAGS=""
	# shellcheck disable=SC2034  # used by caller after sourcing
	WORKDIR="/workspace"

	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	resolve_projects "${raw_projects}" || return 1
	warn_projects_containing_data

	# ── Engine guard for unowned mounts ───────────────────────────────
	# Unowned paths require podman's `:O` overlay (no Docker equivalent).
	# If any path is unowned and the runtime is not podman, abort before
	# any filesystem side effects (no session dir, no overlay tree).
	local _engine="${CONTAINER_CMD:-podman}"
	if [[ "${_engine}" != "podman" ]]; then
		local _unowned_paths=""
		local _dir
		for _dir in "${PROJECT_DIRS[@]}"; do
			# shellcheck disable=SC2310 # _mount_path_is_unowned is designed to be tested in if-conditions
			if _mount_path_is_unowned "${_dir}"; then
				_unowned_paths="${_unowned_paths}${_dir}"$'\n'
			fi
		done
		if [[ -n "${_unowned_paths}" ]]; then
			{
				echo "ERROR: project path is not owned by you and requires podman's \`:O\` overlay mount:"
				# shellcheck disable=SC2086  # intentional word-splitting on newlines in the path list
				printf '         %s\n' ${_unowned_paths}
				echo "       This feature is podman-only. Docker does not support per-mount overlays."
				echo "       Either run under podman, or copy the tree to a location you own."
			} >&2
			return 1
		fi
		unset _dir _unowned_paths
	fi

	# ── Session dir ───────────────────────────────────────────────────
	# Created, and checked writable, before the migration below: a session
	# dir a previous run left owned by another UID would make every legacy
	# move fail, and a failed move is recorded as done.
	local riotbox_session_dir="${RIOTBOX_SESSION_DIR}"
	# RIOTBOX_DRY_RUN=1 lets diagnostic callers (e.g. `riotbox mounts`)
	# compute the projected mount table without creating session dirs or
	# triggering agent host_sync writes. The dry-run agent_call still
	# returns whatever flags the manifest would emit, but it must not
	# write any host files (manifests are expected to honor the env var).
	if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
		# Bail if a previous run without --userns=keep-id left dirs owned by
		# a subordinate UID. That shows up as a failed chmod (not the owner)
		# as often as a failed write probe, so all three get the chown hint.
		if ! mkdir -p "${riotbox_session_dir}" ||
			! chmod 700 "${riotbox_session_dir}" ||
			[[ ! -w "${riotbox_session_dir}" ]]; then
			echo "ERROR: ${riotbox_session_dir} is not writable (wrong UID from a previous run)." >&2
			# shellcheck disable=SC2312 # id failure is impossible in a running bash session
			echo "  Fix with: sudo chown -R $(id -u):$(id -g) ${riotbox_session_dir}" >&2
			exit 1
		fi
		# Write project paths so list-sessions can show them without decoding
		# the key. The container can replace .projects with a link at any
		# moment, and a redirect would write through it, so the list is
		# staged in the data dir (never mounted; dot-named, so the session
		# enumerators skip it) and renamed into place: rename(2) replaces a
		# link instead of following it. It cannot replace a directory, so
		# anything other than a regular file is removed first (the entry,
		# never what it points at; only the container puts one there), as
		# agents/claude/sync-settings.sh does. If one is re-planted after
		# that, the rename fails and the launch aborts.
		local _projects_tmp _projects="${riotbox_session_dir}/.projects" _previous_projects=""
		# What .projects named before this launch, for record_projects'
		# warning about a session an older RiotBox left without a record.
		# shellcheck disable=SC2310 # an unreadable .projects names nothing
		_previous_projects="$(session_projects "${riotbox_session_dir}")" || _previous_projects=""
		_projects_tmp="$(mktemp "${RIOTBOX_DATA_DIR}/.projects.XXXXXX")" || return 1
		if [[ -L "${_projects}" ]] || { [[ -e "${_projects}" ]] && [[ ! -f "${_projects}" ]]; }; then
			echo "Warning: ${_projects} is not a regular file; removing it." >&2
			rm -rf -- "${_projects}" || {
				rm -f -- "${_projects_tmp}"
				echo "Error: could not remove ${_projects}; aborting." >&2
				return 1
			}
		fi
		printf '%s\n' "${PROJECT_DIRS[@]}" >"${_projects_tmp}" || {
			rm -f -- "${_projects_tmp}"
			echo "Error: could not write the project list to ${_projects_tmp} (is the disk full?); aborting." >&2
			return 1
		}
		mv -T -- "${_projects_tmp}" "${_projects}" || {
			rm -f -- "${_projects_tmp}"
			echo "Error: could not rename the project list onto ${_projects} (was something planted there again?); aborting." >&2
			return 1
		}
	fi

	# ── Session state dir ─────────────────────────────────────────────
	# Holds every mount source except the session dir itself — see
	# scripts/lib/session-state.sh for why none may nest in the session
	# dir. Created ahead of the overlay tree below, which lives in it, and
	# ahead of the migration, so a new session is marked as migrated on its
	# first launch.
	if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
		mkdir -p "${RIOTBOX_STATE_DIR}" || return 1
		chmod 700 "${RIOTBOX_STATE_ROOT}" "${RIOTBOX_STATE_DIR}" || return 1
		# shellcheck disable=SC2310 # a failed migration has already said why
		migrate_session_state "${RIOTBOX_SESSION_DIR}" "${RIOTBOX_STATE_DIR}" || return 1
		# shellcheck disable=SC2310 # it has already said why it failed
		_with_migrate_lock "${RIOTBOX_STATE_DIR}" record_projects "${_previous_projects}" || return 1
	fi

	if [[ "${RIOTBOX_OVERLAY:-}" = "1" ]]; then
		# ── Overlay mode: per-path branch on ownership ────────────────
		# Owned path → :ro,z lower + state-dir :z upper (persistent).
		# Unowned path → :O only (ephemeral; no state upper/work). The
		# original :ro,z lower would chcon-fail on unowned dirs; :O has
		# the same essential shape (RO source + writable container view)
		# and is the safe fallback. Persistence is fundamentally
		# incoherent against a tree you cannot write back to.
		local _unowned_for_warn=""
		local _name _lower_path _overlay_path _overlay_dir _i
		overlay_project_names "${PROJECT_DIRS[@]}"
		if [[ ${#PROJECT_DIRS[@]} -eq 1 ]]; then
			_lower_path="/mnt/lower"
			_overlay_path="/mnt/overlay"
			_name="${OVERLAY_NAMES[0]}"
			# shellcheck disable=SC2310 # _mount_path_is_unowned is designed to be tested in if-conditions
			if _mount_path_is_unowned "${PROJECT_DIRS[0]}"; then
				PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:${_lower_path}:O"
				_unowned_for_warn="${PROJECT_DIRS[0]}"$'\n'
			else
				PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:${_lower_path}:ro,z"
				_overlay_dir="${RIOTBOX_STATE_DIR}/overlay/${_name}"
				if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
					# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
					ensure_real_dir "${RIOTBOX_STATE_DIR}/overlay" || return 1
					# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
					ensure_real_dir "${_overlay_dir}" || return 1
					mkdir -p "${_overlay_dir}/upper" "${_overlay_dir}/work"
				fi
				PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${_overlay_dir}:${_overlay_path}:z"
			fi
		else
			for _i in "${!PROJECT_DIRS[@]}"; do
				dir="${PROJECT_DIRS[_i]}"
				_name="${OVERLAY_NAMES[_i]}"
				_lower_path="/mnt/lower/${_name}"
				_overlay_path="/mnt/overlay/${_name}"
				# shellcheck disable=SC2310 # _mount_path_is_unowned is designed to be tested in if-conditions
				if _mount_path_is_unowned "${dir}"; then
					PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:${_lower_path}:O"
					_unowned_for_warn="${_unowned_for_warn}${dir}"$'\n'
				else
					PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:${_lower_path}:ro,z"
					_overlay_dir="${RIOTBOX_STATE_DIR}/overlay/${_name}"
					if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
						# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
						ensure_real_dir "${RIOTBOX_STATE_DIR}/overlay" || return 1
						# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
						ensure_real_dir "${_overlay_dir}" || return 1
						mkdir -p "${_overlay_dir}/upper" "${_overlay_dir}/work"
					fi
					PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${_overlay_dir}:${_overlay_path}:z"
				fi
			done
		fi
		if [[ -n "${_unowned_for_warn}" ]]; then
			{
				echo "WARN: RIOTBOX_OVERLAY=1 falls back to ephemeral overlay (:O) for unowned paths:"
				# shellcheck disable=SC2086  # intentional word-splitting on newlines in the path list
				printf '        %s\n' ${_unowned_for_warn}
				echo "      Writes to these paths will not persist between runs."
			} >&2
		fi
	else
		# ── Normal mode: direct bind mount ────────────────────────────
		# Per-path branching on ownership:
		#   owned + RIOTBOX_READONLY=1   → :ro,z
		#   owned + default              → :z
		#   not owned (either)           → :O    (podman overlay; ephemeral writes)
		local _ro_suffix=":z"
		if [[ "${RIOTBOX_READONLY:-}" = "1" ]]; then
			_ro_suffix=":ro,z"
		fi

		local _suffix _container_path
		if [[ ${#PROJECT_DIRS[@]} -eq 1 ]]; then
			_container_path="/workspace"
			# shellcheck disable=SC2310 # _mount_path_is_unowned is designed to be tested in if-conditions
			if _mount_path_is_unowned "${PROJECT_DIRS[0]}"; then
				_suffix=":O"
			else
				_suffix="${_ro_suffix}"
			fi
			PROJECT_VOLUME_FLAGS="-v ${PROJECT_DIRS[0]}:${_container_path}${_suffix}"
		else
			for dir in "${PROJECT_DIRS[@]}"; do
				local name
				name="$(basename "${dir}")"
				_container_path="/workspace/${name}"
				# shellcheck disable=SC2310 # _mount_path_is_unowned is designed to be tested in if-conditions
				if _mount_path_is_unowned "${dir}"; then
					_suffix=":O"
				else
					_suffix="${_ro_suffix}"
				fi
				PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${dir}:${_container_path}${_suffix}"
			done
		fi
	fi

	PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${riotbox_session_dir}:/home/llm/.claude:z"

	# ── Headroom state (opt-in) ─────────────────────────────────────────
	# CCR cache, memory store, and proxy logs live under ~/.headroom
	# in-container. Mount a state-dir subdir so cross-agent memory
	# persists across runs of the same project set. Emitted only when the
	# feature is enabled — default sessions get no extra mount.
	if [[ "${RIOTBOX_HEADROOM:-0}" = "1" ]]; then
		if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
			# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
			ensure_real_dir "${RIOTBOX_STATE_DIR}/headroom" || return 1
		fi
		PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${RIOTBOX_STATE_DIR}/headroom:/home/llm/.headroom:z"
	fi

	# ── git-ai store (on by default) ────────────────────────────────────
	# The daemon, its unix sockets, and the metrics/token-usage/transcript
	# SQLite DBs live under ~/.git-ai in-container. The store cannot be
	# relocated by configuration — only HOME moves it — so runtime state
	# and durable state necessarily share one mount.
	#
	# Session-local, deliberately NOT the host's ~/.git-ai. Attribution and
	# prompt records land in refs/notes/ai inside the bind-mounted repo, so
	# they already reach the host; sharing the store would add only the
	# local analytics DBs. It would cost correctness: the directory holds
	# trace2.sock, and the host's ~/.gitconfig names that exact path, so a
	# container that judged the host's daemon dead would unlink and rebind
	# it — breaking git-ai on the host. See the spec's "Why the store is
	# session-local".
	#
	# Unlike every other RiotBox flag this one defaults ON, so the gate
	# reads :-1 rather than :-0. The spelling stays a strict "1" compare to
	# match the rest of the codebase; any other value disables.
	if [[ "${RIOTBOX_GIT_AI:-1}" = "1" ]]; then
		if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
			# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
			ensure_real_dir "${RIOTBOX_STATE_DIR}/git-ai" || return 1
		fi
		PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${RIOTBOX_STATE_DIR}/git-ai:/home/llm/.git-ai:z"
	fi

	# ── Context Mode ledger (opt-in) ────────────────────────────────────
	# One JSON record per session exit, for `riotbox ctx-stats`. Lives
	# OUTSIDE riotbox_session_dir on purpose: the counters it accumulates
	# are pruned from the store after seven days by upstream, and a
	# history that `riotbox session-reset` also erases would answer
	# nothing. See docs/dev/decisions/context-mode-ledger.md.
	#
	# Withheld from a read-only workspace, which is what `riotbox audit`
	# runs. The mount is ordinary and read-write — "write-only drop" is
	# this design's convention, not a podman guarantee — so a session that
	# can read it can enumerate every other project set by filename. An
	# untrusted repo does not get that.
	#
	# Deliberately `-z` here, not `= "1"` like the RIOTBOX_READONLY check
	# a few lines above: any non-empty value withholds the ledger, because
	# failing closed on an ambiguous value is correct for a boundary whose
	# failure mode is leaking every project set you work on, and only
	# libexec/audit.sh ever sets this variable.
	if [[ "${RIOTBOX_CONTEXT_MODE:-0}" = "1" ]] && [[ -z "${RIOTBOX_READONLY:-}" ]]; then
		local cm_ledger
		cm_ledger="${RIOTBOX_LEDGER_ROOT}/runs"
		if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
			mkdir -p "${cm_ledger}"
			chmod 0700 "${cm_ledger}"
		fi
		PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} -v ${cm_ledger}:/home/llm/.riotbox-ledger:z"
	fi

	# ── Sync each registered agent's host config ──────────────────────
	# The agent registry tells us which agents to sync. Each manifest's
	# host_sync function knows where its host config lives and what
	# volume flags to emit, and gets both the session dir and the state
	# dir: anything it mounts must come from the state dir (see
	# docs/dev/agent-contract.md). Adding a new agent extends this loop
	# without editing this file.
	#
	# Skipped under RIOTBOX_DRY_RUN=1 — host_sync hooks write host files
	# (credential nest, opencode auth, settings copies), which is the
	# wrong semantics for a read-only diagnostic. Callers that want to
	# see the projected agent mounts should launch a real session.
	if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
		# shellcheck source=agents/registry.sh
		source "${ROOT_DIR}/agents/registry.sh"
		# shellcheck disable=SC2154 # AGENT_REGISTRY is set by agents/registry.sh sourced above
		local _agent _sync_flags _sync_lock_fd
		# Sessions of one project share the session dir and the state dir,
		# and each sync replaces its copies by remove + rename, so two
		# launches syncing at once collide: the second rename finds the
		# first's copy and aborts as "changed during sync". Hold an
		# exclusive per-project lock across the loop. The state dir's top
		# level is never mounted (only subdirs such as git-ai/, headroom/
		# and overlay/<name> are), so a container cannot plant an entry at
		# .sync.lock and a plain open is safe. Closing the fd
		# releases the lock, so every exit from the loop closes it.
		exec {_sync_lock_fd}>"${RIOTBOX_STATE_DIR}/.sync.lock" || return 1
		if ! flock --nonblock "${_sync_lock_fd}"; then
			echo "Waiting for another launch of this project to finish syncing…" >&2
			flock --exclusive "${_sync_lock_fd}" || {
				exec {_sync_lock_fd}>&-
				return 1
			}
		fi
		for _agent in "${AGENT_REGISTRY[@]}"; do
			# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
			_sync_flags="$(agent_call "${_agent}" host_sync "${riotbox_session_dir}" "${RIOTBOX_STATE_DIR}")" || {
				exec {_sync_lock_fd}>&-
				return 1
			}
			if [[ -n "${_sync_flags}" ]]; then
				PROJECT_VOLUME_FLAGS="${PROJECT_VOLUME_FLAGS} ${_sync_flags}"
			fi
		done
		exec {_sync_lock_fd}>&-
		unset _agent _sync_flags _sync_lock_fd
	fi

	# ── Container name ────────────────────────────────────────────────
	generate_container_name "${PROJECT_DIRS[@]}"
}

# Print the resolved mount table in `host:container:mode` form (one per
# line, mode is `rw`, `ro`, or `ovl` (`:O` overlay)). Reads from
# PROJECT_VOLUME_FLAGS, so the caller must run setup_projects first.
print_mounts_triple() {
	local flag suffix host container mode
	# PROJECT_VOLUME_FLAGS is space-separated `-v <spec>` pairs. Parse with
	# a simple state machine: each `-v` token is followed by one spec.
	local expect_spec=0
	# shellcheck disable=SC2086  # intentional word-splitting on the flag string
	for flag in ${PROJECT_VOLUME_FLAGS}; do
		if [[ "${expect_spec}" = "0" ]]; then
			if [[ "${flag}" = "-v" ]]; then
				expect_spec=1
			fi
			continue
		fi
		expect_spec=0
		# Spec is host:container[:opts]. Split on the LAST colon to allow
		# paths to contain `:` is unsupported (matches the existing whole-
		# script LIMITATION). Use the first two colons as separators.
		host="${flag%%:*}"
		local rest="${flag#*:}"
		# rest is `container[:opts]`. opts can be `z`, `ro`, `ro,z`, `rw,z`.
		# The container path itself never contains `:` in this codebase.
		if [[ "${rest}" == *:* ]]; then
			container="${rest%%:*}"
			suffix="${rest#*:}"
		else
			container="${rest}"
			suffix=""
		fi
		case "${suffix}" in
		"") mode="rw" ;;
		"O") mode="ovl" ;;
		*)
			case ",${suffix}," in
			*,ro,*) mode="ro" ;;
			*) mode="rw" ;;
			esac
			;;
		esac
		printf '%s:%s:%s\n' "${host}" "${container}" "${mode}"
	done
}

# ── Script-mode entry ────────────────────────────────────────────────
# When this file is executed (not sourced), parse --format= flags and
# emit the resolved mount table on stdout. Sourced callers reach the
# top of the file and stop here without running setup.
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
	set -euo pipefail

	OUTPUT_FORMAT="podman"
	PROJECT_ARGS=()
	for arg in "$@"; do
		case "${arg}" in
		--format=podman) OUTPUT_FORMAT="podman" ;;
		--format=triple) OUTPUT_FORMAT="triple" ;;
		--format=*)
			echo "ERROR: unknown --format value: ${arg#--format=}" >&2
			echo "       allowed: podman, triple" >&2
			exit 2
			;;
		*) PROJECT_ARGS+=("${arg}") ;;
		esac
	done

	# ROOT_DIR is required by setup_projects (sources agents/registry.sh).
	if [[ -z "${ROOT_DIR:-}" ]]; then
		ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	fi

	# Source config for config-persisted toggles (e.g. RIOTBOX_HEADROOM). The
	# files use `: "${VAR:=default}"` so sourcing user (XDG) before system (/etc)
	# yields: env > $XDG_CONFIG_HOME/riotbox > /etc/riotbox > built-in default.
	# (env wins because := only assigns when the variable is unset.) This mirrors
	# launch.sh's sourcing logic so `riotbox mounts` reflects the same config
	# state that a real launch would see.
	_MPS_CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/riotbox/config"
	_MPS_CONFIG_SYSTEM="${RIOTBOX_SYSCONF_DIR:-/etc/riotbox}/config"
	# shellcheck disable=SC1090
	[[ -f "${_MPS_CONFIG_USER}" ]] && source "${_MPS_CONFIG_USER}"
	# shellcheck disable=SC1090,SC1091
	[[ -f "${_MPS_CONFIG_SYSTEM}" ]] && source "${_MPS_CONFIG_SYSTEM}"
	unset _MPS_CONFIG_USER _MPS_CONFIG_SYSTEM

	raw="${RIOTBOX_PROJECTS:-${PROJECT_ARGS[*]:-}}"
	setup_projects "${raw}"

	case "${OUTPUT_FORMAT}" in
	podman)
		# Trim leading whitespace and emit each `-v <spec>` pair on its
		# own line so output is consistent with detect-mounts.sh.
		# shellcheck disable=SC2086  # intentional word-splitting
		set -- ${PROJECT_VOLUME_FLAGS}
		while [[ $# -ge 2 ]]; do
			if [[ "$1" = "-v" ]]; then
				printf -- '-v %s\n' "$2"
				shift 2
			else
				shift
			fi
		done
		;;
	triple)
		print_mounts_triple
		;;
	*) ;;
	esac
fi
