#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mount-projects.sh — Resolves project directories into container mount flags.
#
# Two invocation modes:
#
#   1. Sourced (existing taskfile scripts). Sets these variables:
#        PROJECT_DIRS         — bash array of resolved host paths, each once
#        PROJECT_DIRS_GIVEN   — the same, as given: repeats kept
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
# shellcheck source=scripts/lib/riotbox-core.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/riotbox-core.sh"

# compute_multi_project_identity <dir>...
#   Print a set's first_seg, n_more and hash, one per line, for the container
#   name and the session key. Computed by riotbox-core set-identity; see
#   docs/dev/riotbox-core.md.
compute_multi_project_identity() {
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" set-identity -- "$@"
}

# session_key <dir>...
#   Print the session key of a resolved project set: one key per set, at most
#   255 bytes, readable prefix then hash. resolve_projects derives the session
#   dir, the state dir and the container label from it. Computed by
#   riotbox-core session-key; see docs/dev/riotbox-core.md.
session_key() {
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" session-key -- "$@"
}

# legacy_session_key <dir>...
#   Print the key releases before session_key gave the set, for the one-time
#   move of their sessions (migrate_session_key). Frozen: it must reproduce
#   what those releases computed, byte for byte, in the user's locale. It is
#   not injective ("/" and "-" alias), which is why it was replaced: one
#   project the whole path with "/" mapped to "-", leading "-" dropped; a set
#   "<first_seg>-<n_more>more-<hash8>", hash8 being the first 8 hex of the
#   SHA-256 of the sorted paths so mangled, joined by "+". Duplicates are
#   kept, as they were (tests pin v0.5.3's own output).
#   Stays in bash: its output depends on the user's locale (GNU sed ranges),
#   which Go cannot reproduce.
legacy_session_key() {
	if [[ $# -eq 1 ]]; then
		printf '%s\n' "$1" | sed 's|/|-|g; s|^-||'
		return
	fi
	local -a sorted=()
	local first_seg hash_input
	# shellcheck disable=SC2312 # sort failure is impossible on in-memory input
	mapfile -t sorted < <(printf '%s\n' "$@" | LC_ALL=C sort)
	first_seg="$(basename "${sorted[0]}")"
	first_seg="$(printf '%s' "${first_seg}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
	hash_input="$(printf '%s\n' "${sorted[@]}" | sed 's|/|-|g; s|^-||' | paste -sd'+' -)"
	# shellcheck disable=SC2312 # sha256sum and cut cannot fail on in-memory input
	printf '%s-%smore-%s\n' "${first_seg}" "$((${#sorted[@]} - 1))" "$(printf '%s' "${hash_input}" | sha256sum | cut -c1-8)"
}

# Generate a container name from project paths: a readable part, then "-"
# and a random 8-hex suffix, capped at 64 characters.
#
# The suffix is always there, and the engine is never asked which names are
# taken: two launches could both find a name free and then clash on --name,
# and the window between naming and `run` includes the launch's TTY prompts.
# Nothing keys off the name — sessions are found by the riotbox.session
# label and by their mounts (internal/engine, through riotbox-core) — so names are
# not deterministic, and two launches of one project or set never share one.
#
# Single-project: `riotbox-<basename>-<suffix>`, the basename sanitized to
# podman-legal characters and trimmed from its end to fit the cap.
#
# Multi-project: `riotbox-<first_basename>-<N>more-<hash>-<suffix>` using the
# identity from compute_multi_project_identity. The hash keeps the readable
# part distinct per set — naive basename concatenation overflowed the
# 64-char cap and the left-truncation that followed silently collapsed
# distinct project sets that happened to share a trailing run of basenames
# into one name. It is the session key's hash (riotbox-core set-identity):
# the 8-hex hash of mangled paths it replaced gave sets whose paths differ
# only by "-" for "/" one name. first_basename is trimmed to fit the cap.
generate_container_name() {
	local -a dirs=("$@")
	local max_len=64
	local prefix="riotbox" random
	random="-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

	if [[ ${#dirs[@]} -eq 0 ]]; then
		# shellcheck disable=SC2034  # used by caller after sourcing
		CONTAINER_NAME="${prefix}${random}"
		return
	fi

	local readable suffix="${random}"
	if [[ ${#dirs[@]} -gt 1 ]]; then
		local n_more hash
		local identity
		# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
		identity="$(compute_multi_project_identity "${dirs[@]}")" || return 1
		{
			read -r readable
			read -r n_more
			read -r hash
		} <<<"${identity}"
		suffix="-${n_more}more-${hash}${random}"
	else
		readable="$(basename -- "${dirs[0]}" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g')"
	fi

	local readable_max=$((max_len - ${#prefix} - 1 - ${#suffix}))
	# shellcheck disable=SC2034  # used by caller after sourcing
	CONTAINER_NAME="${prefix}-${readable:0:${readable_max}}${suffix}"
}

# Set the three per-user roots every session lives under, from XDG_DATA_HOME:
#   RIOTBOX_DATA_DIR    session dirs (each mounted at ~/.claude) and backups/;
#                       on a rootless install, the app tree as well
#   RIOTBOX_STATE_ROOT  one state dir per session (scripts/lib/session-state.sh)
#   RIOTBOX_EGRESS_ROOT one dir per RIOTBOX_EGRESS=1 launch (libexec/egress-lib.sh)
# plus the Context Mode ledger root shared by every session:
#   RIOTBOX_LEDGER_ROOT $RIOTBOX_CONTEXT_LEDGER, else beside the other three
# The one place any of them is spelled out for the launch and the session
# commands, which call this rather than deriving the paths again
# (scripts/ctx-stats.sh does not source this file and keeps its own ledger
# default).
resolve_data_roots() {
	local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
	RIOTBOX_DATA_DIR="${data_home}/riotbox"
	RIOTBOX_STATE_ROOT="${data_home}/riotbox-state"
	# shellcheck disable=SC2034  # used by caller after sourcing
	RIOTBOX_EGRESS_ROOT="${data_home}/riotbox-egress"
	RIOTBOX_LEDGER_ROOT="${RIOTBOX_CONTEXT_LEDGER:-${data_home}/riotbox-context-mode}"
}

# Lightweight resolver: populates PROJECT_DIRS (each project once), PROJECT_DIRS_GIVEN, PROJECT_SUMMARY,
# RIOTBOX_SESSION_DIR and RIOTBOX_STATE_DIR (plus the four roots from
# resolve_data_roots) without creating dirs, copying files, or spawning
# container commands. Used by recipes that only need the session path.
resolve_projects() {
	local raw_projects="$1"
	local -A _seen=()
	PROJECT_DIRS=()
	PROJECT_DIRS_GIVEN=()
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
		# A project named twice, directly or through a link, is one project:
		# mounted once, counted once, keyed once. PROJECT_DIRS_GIVEN keeps
		# the list as given, which older releases keyed (legacy_session_key).
		PROJECT_DIRS_GIVEN+=("${resolved}")
		if [[ -z "${_seen["${resolved}"]:-}" ]]; then
			_seen["${resolved}"]=1
			PROJECT_DIRS+=("${resolved}")
		fi
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
	# One key per project set (session_key); the session dir, the state dir
	# and the container label all derive from it.
	local session_key
	resolve_data_roots
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	session_key="$(session_key "${PROJECT_DIRS[@]}")" || return 1
	RIOTBOX_SESSION_DIR="${RIOTBOX_DATA_DIR}/${session_key}"
	RIOTBOX_STATE_DIR="${RIOTBOX_STATE_ROOT}/${session_key}"
}

# record_projects <previous .projects>
#   Record PROJECT_DIRS in <state dir>/projects, one path per line (the
#   format of the session dir's .projects), staged in the state dir and
#   renamed into place. The state dir's top level is never mounted, so this
#   record, unlike .projects, is the host's own: the overlay commands trust
#   only it (see recorded_projects). Session keys are unique per set
#   (session_key), and the one-time key migration moves a session only to
#   the set it recorded, so a record names a different set than this
#   launch's only when a state dir was copied or renamed by hand:
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
					echo "Warning: this session has pending overlay changes recorded for another project set;"
					echo "         they stay recorded for that set:"
					printf '%s\n' "${recorded}" | _record_indent
				} >&2
				return 0
			fi
			{
				echo "Warning: replacing this session's recorded project set, which named another set:"
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
#   Exit 0 when two newline-separated path lists name the same set. Run by
#   riotbox-core same-project-set (records.SameSet), the one implementation
#   the key move shares.
same_project_set() {
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" same-project-set -- "$1" "$2"
}

# migrate_session_key
#   The one-time move of PROJECT_DIRS' session from the key an older release
#   gave it to its own (session_key), only when the old session's evidence
#   shows it is this set's, and never while a container can write it. The
#   old keys are legacy_session_key of PROJECT_DIRS_GIVEN, which keeps a
#   project named twice twice, as those releases did, then, when that list
#   had repeats, of PROJECT_DIRS, so `riotbox /a /a` also finds the session
#   `riotbox /a` made. Call after resolve_projects, before anything touches
#   RIOTBOX_SESSION_DIR or RIOTBOX_STATE_DIR. Messages go to stderr. Returns
#   non-zero when a move or the refusal check fails; the caller must then
#   stop. Run by riotbox-core migrate-key, under the state root's
#   .migrate.lock; the rules are in internal/migrate (SessionKey).
migrate_session_key() {
	local -a legacy=()
	legacy+=(--legacy-key "$(legacy_session_key "${PROJECT_DIRS_GIVEN[@]}")")
	if [[ "${#PROJECT_DIRS_GIVEN[@]}" -ne "${#PROJECT_DIRS[@]}" ]]; then
		legacy+=(--legacy-key "$(legacy_session_key "${PROJECT_DIRS[@]}")")
	fi
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	riotbox_core_require || return 1
	"${RIOTBOX_CORE}" migrate-key --lib-dir "${_RIOTBOX_CORE_ROOT}/scripts/lib" \
		--engine "${CONTAINER_CMD:-podman}" --data-dir "${RIOTBOX_DATA_DIR}" \
		--state-root "${RIOTBOX_STATE_ROOT}" "${legacy[@]}" -- "${PROJECT_DIRS[@]}"
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

# Print, on stderr, the overlay-<verb> command for each verb given, naming
# the project set recorded for this session (record_projects): every path
# of it, since the overlay commands accept only that set, and never the
# container-written .projects.
print_overlay_commands() {
	local recorded verb
	local -a paths
	# shellcheck disable=SC2310 # no record is an answer, not an error
	if ! recorded="$(recorded_projects "${RIOTBOX_STATE_DIR}")"; then
		echo "    (unknown) — launch this project set once with this release" >&2
		return 0
	fi
	mapfile -t paths <<<"${recorded}"
	for verb in "$@"; do
		# shellcheck disable=SC2312 # quoting cannot fail
		echo "    $(overlay_command "${verb}" "${paths[@]}")" >&2
	done
}

# require_overlay_dir <dir>
#   require_real_dir for an overlay's upper or work at launch. When a session
#   left it as a link or a file, also say how to clear it: overlay-reject for
#   the recorded set removes it without following it.
require_overlay_dir() {
	# shellcheck disable=SC2310 # a predicate designed for conditions
	require_real_dir "$1" && return 0
	echo "  A session left it so. To clear it, discard this session's overlay (the entry itself is removed, never followed):" >&2
	print_overlay_commands reject
	return 1
}

# member_set_hint <subcommand> <dir>
#   After <dir> alone resolved to no session: print, on stderr, the command
#   `riotbox <subcommand>` for each multi-project session whose recorded set
#   (record_projects) lists <dir>, since such a session is reached only
#   through the whole set. The container-written .projects is never
#   consulted.
member_set_hint() {
	local subcommand="$1" dir="$2" state projects member
	local -a members states
	# dotglob: a multi-project session key starts with the first project's
	# basename, so ".dotfiles" gives a key that starts with a dot. The
	# subshell keeps the caller's shell options untouched.
	mapfile -d '' -t states < <(
		shopt -s dotglob nullglob
		for state in "${RIOTBOX_STATE_ROOT}"/*/; do printf '%s\0' "${state}"; done
	)
	for state in "${states[@]}"; do
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
		# A session an older release keyed by mangled path moves to this
		# set's key first, so everything below finds it.
		# shellcheck disable=SC2310 # it has already said why it failed
		migrate_session_key || return 1
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
		# enumerators skip it) and renamed into place by replace_entry
		# (scripts/lib/session-state.sh), which never follows a link there.
		# If something is re-planted mid-install, the launch aborts.
		local _projects_tmp _projects="${riotbox_session_dir}/.projects" _previous_projects="" _replace_rc=0
		# What .projects named before this launch, for record_projects'
		# warning about a session an older RiotBox left without a record.
		# shellcheck disable=SC2310 # an unreadable .projects names nothing
		_previous_projects="$(session_projects "${riotbox_session_dir}")" || _previous_projects=""
		_projects_tmp="$(mktemp "${RIOTBOX_DATA_DIR}/.projects.XXXXXX")" || return 1
		printf '%s\n' "${PROJECT_DIRS[@]}" >"${_projects_tmp}" || {
			rm -f -- "${_projects_tmp}"
			echo "Error: could not write the project list to ${_projects_tmp} (is the disk full?); aborting." >&2
			return 1
		}
		# shellcheck disable=SC2310 # the status picks the error message
		replace_entry "${_projects_tmp}" "${_projects}" || _replace_rc=$?
		if [[ "${_replace_rc}" -ne 0 ]]; then
			rm -f -- "${_projects_tmp}"
			if [[ "${_replace_rc}" -eq 1 ]]; then
				echo "Error: could not remove ${_projects}; aborting." >&2
			else
				echo "Error: could not rename the project list onto ${_projects} (was something planted there again?); aborting." >&2
			fi
			return 1
		fi
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
					# shellcheck disable=SC2310 # require_overlay_dir has already said why it refused
					require_overlay_dir "${_overlay_dir}/upper" || return 1
					# shellcheck disable=SC2310 # require_overlay_dir has already said why it refused
					require_overlay_dir "${_overlay_dir}/work" || return 1
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
						# shellcheck disable=SC2310 # require_overlay_dir has already said why it refused
						require_overlay_dir "${_overlay_dir}/upper" || return 1
						# shellcheck disable=SC2310 # require_overlay_dir has already said why it refused
						require_overlay_dir "${_overlay_dir}/work" || return 1
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
	# Proxy logs, the CCR cache and headroom's other state live under
	# ~/.headroom in-container. Its memory DB lands there too, but only
	# because the agent wrapper exports HEADROOM_MEMORY_DB_PATH: headroom's
	# own default is the working directory (/workspace). Mount a state-dir
	# subdir so memory persists across runs of the same project set and is
	# shared by its agents. Emitted only when the feature is enabled —
	# default sessions get no extra mount.
	if [[ "${RIOTBOX_HEADROOM:-0}" = "1" ]]; then
		if [[ "${RIOTBOX_DRY_RUN:-0}" != "1" ]]; then
			# shellcheck disable=SC2310 # ensure_real_dir has already said why it failed
			ensure_real_dir "${RIOTBOX_STATE_DIR}/headroom" || return 1
			# Only one project was ever bind-mounted at /workspace, so only a
			# single-project session can have memory left in its checkout.
			if [[ ${#PROJECT_DIRS[@]} -eq 1 ]]; then
				# Advisory: a failure to check or record costs the notice
				# (it may show again), never the launch. It takes the
				# session's migrate lock itself.
				# shellcheck disable=SC2310 # its status only picks the warning
				if ! notice_project_headroom "${PROJECT_DIRS[0]}" "${RIOTBOX_STATE_DIR}"; then
					echo "Warning: could not record that the headroom memory notice was checked; it may show again." >&2
				fi
			fi
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
	# shellcheck disable=SC2310 # failure is propagated explicitly; it has already said why
	generate_container_name "${PROJECT_DIRS[@]}" || return 1
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
