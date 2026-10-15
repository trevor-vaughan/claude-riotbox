#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/running-sessions.sh — what running containers mount.
#
# Host commands that change session data a container can also write ask the
# engine first which running containers have it mounted, and refuse when the
# engine cannot answer. Sourced on the host by
# scripts/lib/session-state.sh, and so by everything that sources it.
#
# Public:
#   running_session_mounts
#   running_mount_reaches <index> <resolved> <lexical>
#   running_mount_overlaps <index> <resolved> <lexical>
#   running_mount_label <index>
#   paths_overlap <a> <b>
# ─────────────────────────────────────────────────────────────────────────────

# One record per mount: container ID, name, source, read-write flag, each
# NUL-terminated. These field names exist in both podman's and docker's
# container inspect output; NUL, because a path may hold anything.
# shellcheck disable=SC2016 # a Go template for the engine, not shell
_RUNNING_INSPECT_FORMAT='{{$c := .ID}}{{$n := .Name}}{{range .Mounts}}{{$c}}{{"\x00"}}{{$n}}{{"\x00"}}{{.Source}}{{"\x00"}}{{.RW}}{{"\x00"}}{{end}}'

# running_session_mounts
#   Inspect the mounts of every live container, with the engine in
#   CONTAINER_CMD (default podman). Not only the ones libexec/launch.sh
#   labels riotbox.session: releases up to v0.5.3 set no label, and a session
#   one of them started is still running during the upgrade, when the key
#   move and the overlay commands first ask. Which ones are labelled is
#   kept, because callers trust an unlabelled container's mounts less
#   (running_mount_reaches). All containers are inspected in one call; if
#   that fails (one exited since the listing, say), each is inspected on its
#   own. Live means created, running or paused: a container `run` has
#   created but not yet started already has its mounts, and a paused one
#   keeps them. An exited container is gone. Sets four parallel arrays, one
#   element per read-write host mount:
#     RUNNING_MOUNT_IDS       the container's full ID
#     RUNNING_MOUNT_NAMES     its name
#     RUNNING_MOUNT_SOURCES   the mount source, canonicalised (realpath -m)
#     RUNNING_MOUNT_LEXICAL   the same, with links left alone (realpath -ms):
#                             the container keeps the dir it was given even
#                             when a component of its path is later swapped
#                             for a link, which changes the resolved form
#     RUNNING_MOUNT_LABELLED  1 when it has the riotbox.session label, else ""
#   A tmpfs (empty source) is skipped: nothing on the host. Returns non-zero
#   when the engine cannot list or inspect them; a container that exited
#   between the listing and its inspection is skipped.
running_session_mounts() {
	local engine="${CONTAINER_CMD:-podman}" ids labelled_ids id i errfile
	local -a id_list=() listed=() states=(--filter status=created --filter status=running --filter status=paused)
	local -A labelled=()
	RUNNING_MOUNT_IDS=()
	RUNNING_MOUNT_NAMES=()
	RUNNING_MOUNT_SOURCES=()
	RUNNING_MOUNT_LEXICAL=()
	RUNNING_MOUNT_LABELLED=()
	# Both engines OR the values of a repeated status filter, AND it with a
	# label filter, and list non-running containers once a status filter is
	# given (-a says so explicitly). These three states are the ones both
	# accept; docker's "restarting" is rejected by podman, and RiotBox runs
	# every container with --rm and no restart policy. Full IDs, to match
	# the two listings and the inspect output exactly.
	ids="$("${engine}" ps -a --no-trunc "${states[@]}" --format '{{.ID}}')" || return 1
	mapfile -t listed <<<"${ids}"
	for id in "${listed[@]}"; do
		[[ -z "${id}" ]] || id_list+=("${id}")
	done
	[[ "${#id_list[@]}" -gt 0 ]] || return 0
	labelled_ids="$("${engine}" ps -a --no-trunc --filter label=riotbox.session "${states[@]}" --format '{{.ID}}')" || return 1
	mapfile -t listed <<<"${labelled_ids}"
	for id in "${listed[@]}"; do
		[[ -z "${id}" ]] || labelled["${id}"]=1
	done
	errfile="$(mktemp)" || return 1
	# shellcheck disable=SC2310 # a failed batch falls back to one by one
	if ! _inspect_mounts "${engine}" "${errfile}" "${id_list[@]}"; then
		for id in "${id_list[@]}"; do
			# shellcheck disable=SC2310 # its status is checked here
			_inspect_mounts "${engine}" "${errfile}" "${id}" && continue
			# A container that exited after `ps` listed it is gone, not an
			# error: with several sessions running that is the common case.
			# podman says "no such object" (exit 125), docker "No such
			# object" or "No such container".
			grep -qiE 'no such (object|container)' "${errfile}" && continue
			cat "${errfile}" >&2
			rm -f -- "${errfile}"
			return 1
		done
	fi
	rm -f -- "${errfile}"
	for i in "${!RUNNING_MOUNT_IDS[@]}"; do
		RUNNING_MOUNT_LABELLED[i]="${labelled["${RUNNING_MOUNT_IDS[i]}"]:-}"
	done
}

# _inspect_mounts <engine> <errfile> <id>...
#   Append the read-write host mounts of the containers to the IDS, NAMES
#   and SOURCES arrays (running_session_mounts), with the engine's stderr in
#   <errfile>. Appends nothing, and returns non-zero, when the engine fails
#   or its output is malformed.
_inspect_mounts() {
	local engine="$1" errfile="$2" i id src lexical nl=$'\n'
	shift 2
	local -a fields=() ids=() names=() sources=() lexicals=()
	# shellcheck disable=SC2312 # the status is checked through wait below
	mapfile -d '' -t fields < <("${engine}" container inspect --format "${_RUNNING_INSPECT_FORMAT}" "$@" 2>"${errfile}")
	# shellcheck disable=SC2154 # $! is the process substitution's PID
	wait "$!" || return 1
	# The engine ends each container's output with a newline, so a record's
	# ID starts with the newlines of the containers before it, and the
	# output ends with a field of newlines only. The newline is held in a
	# variable: $'...' inside "${...}" is literal when bash runs as sh, and
	# this file is sourced into sh-mode scripts.
	if [[ "${#fields[@]}" -gt 0 ]] && [[ -z "${fields[-1]//"${nl}"/}" ]]; then
		unset 'fields[-1]'
	fi
	[[ $((${#fields[@]} % 4)) -eq 0 ]] || return 1
	for ((i = 0; i < ${#fields[@]}; i += 4)); do
		id="${fields[i]}"
		while [[ "${id}" == "${nl}"* ]]; do
			id="${id#"${nl}"}"
		done
		[[ -n "${id}" ]] || return 1
		if [[ -z "${fields[i + 2]}" ]] || [[ "${fields[i + 3]}" != true ]]; then
			continue
		fi
		src="$(realpath -m -- "${fields[i + 2]}")" || return 1
		lexical="$(realpath -ms -- "${fields[i + 2]}")" || return 1
		ids+=("${id}")
		names+=("${fields[i + 1]#/}")
		sources+=("${src}")
		lexicals+=("${lexical}")
	done
	RUNNING_MOUNT_IDS+=("${ids[@]}")
	RUNNING_MOUNT_NAMES+=("${names[@]}")
	RUNNING_MOUNT_SOURCES+=("${sources[@]}")
	RUNNING_MOUNT_LEXICAL+=("${lexicals[@]}")
}

# running_mount_reaches <index> <resolved> <lexical>
#   True when mount <index> of running_session_mounts can write to a path,
#   given as realpath -m (<resolved>) and realpath -ms (<lexical>) print it;
#   either form matching the mount's own form of it is enough. For a
#   container with the riotbox.session label, when its source and the path
#   overlap either way (running_mount_overlaps): a RiotBox session mounting
#   an ancestor (a project that contains the data dir) writes there too.
#   For an unlabelled one, only when its source is the path or inside it:
#   v0.5.3 mounted nothing above a session, while toolbox and distrobox
#   keep containers running with / mounted read-write, which would
#   otherwise block every session command. Use this for refusals; use
#   running_mount_overlaps for warnings.
running_mount_reaches() {
	if [[ -n "${RUNNING_MOUNT_LABELLED[$1]}" ]]; then
		running_mount_overlaps "$@"
		return
	fi
	[[ "${RUNNING_MOUNT_SOURCES[$1]%/}/" == "${2%/}/"* ]] ||
		[[ "${RUNNING_MOUNT_LEXICAL[$1]%/}/" == "${3%/}/"* ]]
}

# running_mount_overlaps <index> <resolved> <lexical>
#   True when mount <index> and the path (as for running_mount_reaches)
#   overlap either way, whatever the container's label.
running_mount_overlaps() {
	paths_overlap "${RUNNING_MOUNT_SOURCES[$1]}" "$2" ||
		paths_overlap "${RUNNING_MOUNT_LEXICAL[$1]}" "$3"
}

# running_mount_label <index>
#   Print how messages name the container of mount <index>: its name, else
#   the first 12 characters of its ID.
running_mount_label() {
	local name="${RUNNING_MOUNT_NAMES[$1]}"
	printf '%s\n' "${name:-${RUNNING_MOUNT_IDS[$1]:0:12}}"
}

# paths_overlap <a> <b>
#   Exit 0 when two canonical paths are equal or one contains the other.
paths_overlap() {
	[[ "${2%/}/" == "${1%/}/"* ]] || [[ "${1%/}/" == "${2%/}/"* ]]
}
