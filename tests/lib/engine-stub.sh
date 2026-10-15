#!/usr/bin/env bash
# Stub container engine for tests of host commands that ask the engine which
# RiotBox containers are running and what they mount (overlay-accept,
# overlay-reject, session-migrate).
# shellcheck disable=SC2317 # the podman stub below runs as CONTAINER_CMD in the scripts under test
set -euo pipefail

# install_stub_engine <dir>
#   Define and export the function podman, set CONTAINER_CMD to it, and keep
#   the stub's files in <dir>.
#   Exports: CONTAINER_CMD, STUB_RUNNING, STUB_PS_CALLS
#
#   ${STUB_RUNNING} (absent by default: nothing runs) describes the
# containers, one mount per line: "<id> <source> <rw: true|false> [<state>]",
# state "running" when omitted (or "created", "paused", "exited"). `ps
# --filter label=riotbox.session` prints each ID once: with no status filter,
# only running ones, as the engines do; with one or more `--filter
# status=<s>`, those in any listed state (the engines OR a key's values).
# `inspect` prints that ID's mounts in the NUL-separated form
# running_session_mounts (scripts/lib/running-sessions.sh) asks for.
# With STUB_ENGINE_FAIL set, every call fails as an unreachable engine would;
# with STUB_INSPECT_FAIL set, only `inspect` fails. IDs listed in
# STUB_GONE_IDS have exited since `ps`: `inspect` fails on them as podman
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
			[[ " $* " == *" --filter label=riotbox.session "* ]] || return 0
			for arg in "$@"; do
				if [[ "${prev}" == --filter && "${arg}" == status=* ]]; then
					states+="${arg#status=} "
				fi
				prev="${arg}"
			done
			[[ "${states}" != " " ]] || states=" running "
			[[ -f "${STUB_RUNNING}" ]] || return 0
			while read -r id src rw state; do
				if [[ "${states}" == *" ${state:-running} "* ]]; then
					printf '%s\n' "${id}"
				fi
			done <"${STUB_RUNNING}" | sort -u
			;;
		inspect)
			if [[ -n "${STUB_INSPECT_FAIL:-}" ]]; then
				echo "stub engine: permission denied" >&2
				return 125
			fi
			local want="${*: -1}"
			if [[ " ${STUB_GONE_IDS:-} " == *" ${want} "* ]]; then
				if [[ "${STUB_GONE_STYLE:-podman}" == docker ]]; then
					echo "Error: No such container: ${want}" >&2
					return 1
				fi
				echo "Error: no such object: \"${want}\"" >&2
				return 125
			fi
			while read -r id src rw state; do
				if [[ "${id}" == "${want}" ]]; then
					printf '%s\0%s\0' "${src}" "${rw}"
				fi
			done <"${STUB_RUNNING}"
			printf '\n'
			;;
		*) ;;
		esac
	}
	export -f podman
	export CONTAINER_CMD=podman
	export STUB_RUNNING="${dir}/running"
	export STUB_PS_CALLS="${dir}/ps-calls"
}
