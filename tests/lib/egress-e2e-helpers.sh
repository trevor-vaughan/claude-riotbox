#!/usr/bin/env bash
# Helpers for tests/egress-e2e.venom.yml: real podman, the real Envoy image
# and the real riotbox-core. Run through `task test:egress-e2e`, which sets
# RIOTBOX_EGRESS_E2E=1 and RIOTBOX_EGRESS_IMAGE. Without RIOTBOX_EGRESS_E2E
# every case skips: the venom test container `task test` uses cannot create
# podman networks.

_E2E_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_CORE="$(cd "${_E2E_HELPERS_DIR}/../.." && pwd)/libexec/riotbox-core"
E2E_AGENT_IMAGE="quay.io/centos/centos:stream10@sha256:6f8d618844ed5af4365bad24bea19fb0435fd5ec808201af9aeb19d7a28eb515"
# shellcheck disable=SC2034  # consumed by tests/egress-e2e.venom.yml
E2E_BUSYBOX_IMAGE="docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"

# e2e_require
#   Skip the case (print SKIP and OK, exit 0) unless RIOTBOX_EGRESS_E2E=1.
#   With it set, a missing prerequisite fails the case instead.
e2e_require() {
	if [[ "${RIOTBOX_EGRESS_E2E:-}" != 1 ]]; then
		echo "SKIP: run through 'task test:egress-e2e' (RIOTBOX_EGRESS_E2E=1)"
		echo OK
		exit 0
	fi
	command -v podman >/dev/null || { echo "FAIL: podman not found" >&2; exit 1; }
	[[ -n "${RIOTBOX_EGRESS_IMAGE:-}" ]] || { echo "FAIL: RIOTBOX_EGRESS_IMAGE is not set" >&2; exit 1; }
	[[ -x "${E2E_CORE}" ]] || { echo "FAIL: ${E2E_CORE} is missing; run task go:build" >&2; exit 1; }
}

# e2e_setup
#   Make the case's scratch dir (E2E_TMP) and state root (E2E_ROOT), and
#   tear down every session the case starts when it exits.
e2e_setup() {
	E2E_TMP="$(mktemp -d)"
	E2E_ROOT="${E2E_TMP}/riotbox-egress"
	E2E_SESSIONS=()
	trap e2e_cleanup EXIT
}

e2e_cleanup() {
	local name
	for name in "${E2E_SESSIONS[@]}"; do
		"${E2E_CORE}" egress-down --engine podman --state-root "${E2E_ROOT}" -- "${name}" >/dev/null 2>&1 ||
			echo "WARNING: teardown of ${name} failed; remove it with: podman pod rm -f ${name}-pod" >&2
	done
	rm -rf "${E2E_TMP}"
}

# e2e_core <verb> [args...] — run a riotbox-core egress verb on this case's root.
e2e_core() {
	local verb="$1"
	shift
	case "${verb}" in
	egress-allow | egress-deny | egress-strict | egress-reload)
		"${E2E_CORE}" "${verb}" --engine podman --state-root "${E2E_ROOT}" \
			--system-conf "${E2E_TMP}/none" --user-conf "${E2E_TMP}/user.conf" "$@"
		;;
	*) "${E2E_CORE}" "${verb}" --engine podman --state-root "${E2E_ROOT}" "$@" ;;
	esac
}

# e2e_up <name> <owner-pid> [host...]
#   Start session <name>'s proxy pod, allowing the hosts as the agent's.
#   Sets E2E_FLAGS to the agent's engine flags.
e2e_up() {
	local name="$1" owner="$2" out
	shift 2
	E2E_SESSIONS+=("${name}")
	out="$(printf '%s\n' "$@" | e2e_core egress-up --system-conf "${E2E_TMP}/none" \
		--user-conf "${E2E_TMP}/user.conf" --image "${RIOTBOX_EGRESS_IMAGE}" \
		--session-key e2e --owner-pid "${owner}" -- "${name}")" || return 1
	mapfile -t E2E_FLAGS <<<"${out}"
}

# e2e_int_gateway <name>
#   Print session <name>'s internal network gateway, or nothing when it has
#   none. With DNS disabled podman 6.1 assigns none; podman 4.9 may.
e2e_int_gateway() {
	local json
	json="$(podman network inspect "$1-int")" || return 1
	python3 -c '
import json, sys
print(json.load(sys.stdin)[0]["subnets"][0].get("gateway") or "")' <<<"${json}"
}

# e2e_agent <podman run args>... — run a throwaway agent container in the
# last session started, with its flags.
e2e_agent() {
	podman run --rm "${E2E_FLAGS[@]}" "$@"
}

# e2e_codes <url> [curl args...]
#   Print "<CONNECT status> <HTTP status>" as an agent fetching url through
#   the proxy sees them; 000 for a status it never got.
e2e_codes() {
	local url="$1"
	shift
	# curl exits non-zero whenever the proxy refuses (a CONNECT 403 is exit
	# 56); the statuses it prints are the result under test, so its exit
	# status is deliberately not.
	e2e_agent "${E2E_AGENT_IMAGE}" curl -s -o /dev/null -w '%{http_connect} %{http_code}' \
		--max-time 20 "$@" "${url}" || :
}

# e2e_eventually <want> <url> — poll e2e_codes until its CONNECT status is
# <want>, for up to 15 s: Envoy applies a reload within about a second.
e2e_eventually() {
	local want="$1" url="$2" got=""
	for _ in $(seq 15); do
		got="$(e2e_codes "${url}")"
		[[ "${got%% *}" == "${want}" ]] && return 0
		sleep 1
	done
	echo "BAD: ${url}: CONNECT status ${got%% *}, want ${want}" >&2
	return 1
}
