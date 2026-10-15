#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/running-sessions.sh — what running RiotBox containers mount.
#
# Host commands that change session data a container can also write ask the
# engine first which running RiotBox containers have it mounted, and refuse
# when the engine cannot answer. Sourced on the host by
# scripts/lib/session-state.sh, and so by everything that sources it.
#
# Public:
#   running_session_mounts
#   paths_overlap <a> <b>
# ─────────────────────────────────────────────────────────────────────────────

# running_session_mounts
#   Inspect the mounts of every live container labelled riotbox.session,
#   whatever its key (libexec/launch.sh labels each one), with the engine in
#   CONTAINER_CMD (default podman). Live means created, running or paused: a
#   container `run` has created but not yet started already has its mounts,
#   and a paused one keeps them. An exited container is gone. Sets two
#   parallel arrays, one element per read-write host mount:
#     RUNNING_MOUNT_IDS      the container's ID
#     RUNNING_MOUNT_SOURCES  the mount source, canonicalised (realpath -m)
#   A tmpfs (empty source) is skipped: nothing on the host. Returns non-zero
#   when the engine cannot list or inspect them; a container that exited
#   between the listing and its inspection is skipped.
running_session_mounts() {
	local engine="${CONTAINER_CMD:-podman}" ids id src i errfile
	local -a id_list=() fields=()
	RUNNING_MOUNT_IDS=()
	RUNNING_MOUNT_SOURCES=()
	# Both engines OR the values of a repeated status filter, AND it with the
	# label, and list non-running containers once a status filter is given
	# (-a says so explicitly). These three states are the ones both accept;
	# docker's "restarting" is rejected by podman, and RiotBox runs every
	# container with --rm and no restart policy.
	ids="$("${engine}" ps -a --filter label=riotbox.session \
		--filter status=created --filter status=running --filter status=paused \
		--format '{{.ID}}')" || return 1
	mapfile -t id_list <<<"${ids}"
	errfile="$(mktemp)" || return 1
	for id in "${id_list[@]}"; do
		[[ -n "${id}" ]] || continue
		# Source and RW exist under these names in both podman's and
		# docker's inspect output. NUL-separated: a path may hold anything.
		# shellcheck disable=SC2312 # the status is checked through wait below
		mapfile -d '' -t fields < <("${engine}" inspect \
			--format '{{range .Mounts}}{{.Source}}{{"\x00"}}{{.RW}}{{"\x00"}}{{end}}' "${id}" 2>"${errfile}")
		# shellcheck disable=SC2154 # $! is the process substitution's PID
		if ! wait "$!"; then
			# A container that exited after `ps` listed it is gone, not an
			# error: with several sessions running that is the common case.
			# podman says "no such object" (exit 125), docker "No such
			# object" or "No such container".
			if grep -qiE 'no such (object|container)' "${errfile}"; then
				continue
			fi
			cat "${errfile}" >&2
			rm -f -- "${errfile}"
			return 1
		fi
		# The engine ends its output with a newline after the last field.
		if [[ "${#fields[@]}" -gt 0 ]] && [[ "${fields[-1]}" == $'\n' ]]; then
			unset 'fields[-1]'
		fi
		if [[ $((${#fields[@]} % 2)) -ne 0 ]]; then
			rm -f -- "${errfile}"
			return 1
		fi
		for ((i = 0; i < ${#fields[@]}; i += 2)); do
			if [[ -z "${fields[i]}" ]] || [[ "${fields[i + 1]}" != true ]]; then
				continue
			fi
			if ! src="$(realpath -m -- "${fields[i]}")"; then
				rm -f -- "${errfile}"
				return 1
			fi
			RUNNING_MOUNT_IDS+=("${id}")
			RUNNING_MOUNT_SOURCES+=("${src}")
		done
	done
	rm -f -- "${errfile}"
}

# paths_overlap <a> <b>
#   Exit 0 when two canonical paths are equal or one contains the other.
paths_overlap() {
	[[ "${2%/}/" == "${1%/}/"* ]] || [[ "${1%/}/" == "${2%/}/"* ]]
}
