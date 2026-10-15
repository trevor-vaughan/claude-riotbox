#!/usr/bin/env bash
# Stub container engine for tests of host commands that ask the engine which
# RiotBox containers are running and what they mount (overlay-accept,
# overlay-reject, session-migrate).
# shellcheck disable=SC2317 # the podman stub below runs as CONTAINER_CMD in the scripts under test
set -euo pipefail

# install_stub_engine <dir>
#   Define and export the function podman, set CONTAINER_CMD to it, and keep
#   the stub's files in <dir>.
#   Exports: CONTAINER_CMD, STUB_RUNNING, STUB_PS_CALLS, STUB_INSPECT_CALLS
#
#   ${STUB_RUNNING} (absent by default: nothing runs) describes the
# containers, one mount per line:
# "<id> <source> <rw: true|false> [<state> [unlabelled]]", state "running"
# when omitted (or "created", "paused", "exited"); "unlabelled" marks a
# container without the riotbox.session label, as releases up to v0.5.3
# started. `ps --format {{.ID}}` prints each ID once: with no status filter,
# only running ones, as the engines do; with one or more `--filter
# status=<s>`, those in any listed state (the engines OR a key's values);
# with `--filter label=riotbox.session`, only labelled ones. Any other `ps`
# (the container-name probe) prints nothing.
# `container inspect <id>...` prints each ID's mounts in the NUL-separated
# form running_session_mounts (scripts/lib/running-sessions.sh) asks for,
# naming each container after its ID, and counts its calls in
# ${STUB_INSPECT_CALLS}.
# With STUB_ENGINE_FAIL set, every call fails as an unreachable engine would;
# with STUB_INSPECT_FAIL set, only `inspect` fails. IDs listed in
# STUB_GONE_IDS have exited since `ps`: an `inspect` naming one fails as podman
# does ("Error: no such object", 125) or, with STUB_GONE_STYLE=docker, as
# docker does ("Error: No such container", 1).
# With STUB_RUNNING_FROM_CALL=<n>, ${STUB_RUNNING} is consulted only from the
# n-th `ps` on (counted in ${STUB_PS_CALLS}), so a session can "start" partway
# through a command.
install_stub_engine() {
	local dir="$1"
	# An exported function rather than a file on PATH: /dev/shm, which the
	# whiteout cases use, is mounted noexec.
	podman() {
		if [[ -n "${STUB_ENGINE_FAIL:-}" ]]; then
			echo "stub engine: cannot connect" >&2
			return 125
		fi
		local id src rw state calls arg prev="" states=" "
		case "${1:-}" in
		ps)
			calls=$(($(cat "${STUB_PS_CALLS}" 2>/dev/null || echo 0) + 1))
			echo "${calls}" >"${STUB_PS_CALLS}"
			[[ "${calls}" -ge "${STUB_RUNNING_FROM_CALL:-1}" ]] || return 0
			[[ " $* " == *" --format {{.ID}} "* ]] || return 0
			local labelled_only=""
			[[ " $* " != *" --filter label=riotbox.session "* ]] || labelled_only=1
			for arg in "$@"; do
				if [[ "${prev}" == --filter && "${arg}" == status=* ]]; then
					states+="${arg#status=} "
				fi
				prev="${arg}"
			done
			[[ "${states}" != " " ]] || states=" running "
			[[ -f "${STUB_RUNNING}" ]] || return 0
			while read -r id src rw state label; do
				[[ -z "${labelled_only}" || "${label:-}" != unlabelled ]] || continue
				if [[ "${states}" == *" ${state:-running} "* ]]; then
					printf '%s\n' "${id}"
				fi
			done <"${STUB_RUNNING}" | sort -u
			;;
		container)
			[[ "${2:-}" == inspect ]] || return 0
			calls=$(($(cat "${STUB_INSPECT_CALLS}" 2>/dev/null || echo 0) + 1))
			echo "${calls}" >"${STUB_INSPECT_CALLS}"
			if [[ -n "${STUB_INSPECT_FAIL:-}" ]]; then
				echo "stub engine: permission denied" >&2
				return 125
			fi
			shift 2
			[[ "${1:-}" != --format ]] || shift 2
			local want
			for want in "$@"; do
				[[ " ${STUB_GONE_IDS:-} " == *" ${want} "* ]] || continue
				if [[ "${STUB_GONE_STYLE:-podman}" == docker ]]; then
					echo "Error: No such container: ${want}" >&2
					return 1
				fi
				echo "Error: no such object: \"${want}\"" >&2
				return 125
			done
			for want in "$@"; do
				while read -r id src rw state; do
					if [[ "${id}" == "${want}" ]]; then
						printf '%s\0%s\0%s\0%s\0' "${id}" "${id}" "${src}" "${rw}"
					fi
				done <"${STUB_RUNNING}"
				printf '\n'
			done
			;;
		*) ;;
		esac
	}
	export -f podman
	export CONTAINER_CMD=podman
	export STUB_RUNNING="${dir}/running"
	export STUB_PS_CALLS="${dir}/ps-calls"
	export STUB_INSPECT_CALLS="${dir}/inspect-calls"
}
