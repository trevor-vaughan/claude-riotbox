#!/usr/bin/env bash
# Helpers for tests/egress-e2e.venom.yml: real podman, the real Envoy image
# and the real riotbox-core. Run through `task test:egress-e2e`, which sets
# RIOTBOX_EGRESS_E2E=1 and RIOTBOX_EGRESS_IMAGE. Without RIOTBOX_EGRESS_E2E
# every case skips: the venom test container `task test` uses cannot create
# podman networks.

_E2E_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_CORE="$(cd "${_E2E_HELPERS_DIR}/../.." && pwd)/libexec/riotbox-core"
E2E_OS_DIR="$(cd "${_E2E_HELPERS_DIR}/../.." && pwd)/os"
E2E_EGRESS_OS_LIB="$(cd "${_E2E_HELPERS_DIR}/../.." && pwd)/scripts/lib/egress-os.sh"
E2E_AGENT_IMAGE="quay.io/centos/centos:stream10@sha256:99b8fe27dd4958b5dc2630ce35f5f6a7ff7bf9b2b1a72078102fde50d3277550"
# shellcheck disable=SC2034  # consumed by tests/egress-e2e.venom.yml
E2E_BUSYBOX_IMAGE="docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
# Stock distro images for the OS plugin cases, pinned by digest (resolved
# 2026-10-27). Debian and Ubuntu ship without ca-certificates; e2e_with_ca
# derives an image with it.
# shellcheck disable=SC2034  # consumed by tests/egress-e2e.venom.yml
E2E_FEDORA_IMAGE="docker.io/library/fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80"
# shellcheck disable=SC2034
E2E_UBI_IMAGE="registry.access.redhat.com/ubi9/ubi@sha256:48393e4261b2544f652c915b3e052256ddf66ee95cd04dc0362191f302c4e94a"
# shellcheck disable=SC2034
E2E_DEBIAN_IMAGE="docker.io/library/debian:trixie@sha256:15a71cc87173e191d5046f9c4288db4e8954b67f92e48d9587087826b0afe562"
# shellcheck disable=SC2034
E2E_UBUNTU_IMAGE="docker.io/library/ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c"
# shellcheck disable=SC2034
E2E_ARCH_IMAGE="docker.io/library/archlinux:latest@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0"

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
		--user-conf "${E2E_TMP}/user.conf" --os-dir "${E2E_OS_DIR}" --image "${RIOTBOX_EGRESS_IMAGE}" \
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

# e2e_with_ca <image>
#   Print an image that is <image> plus ca-certificates, deriving it once
#   (podman run on the default network, then commit; `podman build` is not
#   used, as it fails in the dev container). apt over HTTPS needs the CA
#   bundle, which the stock Debian and Ubuntu images lack.
e2e_with_ca() {
	local base="$1" hash tag c rc
	hash="$(printf '%s' "${base}" | sha256sum)"
	tag="localhost/riotbox-e2e-ca:${hash:0:12}"
	if ! podman image exists "${tag}"; then
		c="rbx-e2e-ca-$$"
		if ! podman run --name "${c}" "${base}" sh -c 'apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null' >&2; then
			podman rm -f "${c}" >/dev/null 2>&1
			return 1
		fi
		rc=0
		podman commit -q "${c}" "${tag}" >/dev/null || rc=$?
		podman rm -f "${c}" >/dev/null 2>&1
		((rc == 0)) || return "${rc}"
	fi
	printf '%s\n' "${tag}"
}

# e2e_os_run <plugin> <image> <command>
#   In the last session started, run <command> as root in <image> with the
#   repo's os/ at /os and scripts/lib/egress-os.sh at /egress-os.sh, after
#   the entrypoint's own step: egress_os_apply /os/registry.sh, which
#   detects the plugin from the image's /etc/os-release. Fails unless that
#   detects <plugin>, and when egress_os_apply warns of no plugin or returns
#   non-zero. <command> runs in the same shell, so it can call
#   egress_os_apply again. Prints the output; returns the command's status.
e2e_os_run() {
	local plugin="$1" image="$2" cmd="$3"
	# shellcheck disable=SC2016 # expanded in the container
	e2e_agent --user 0 -v "${E2E_OS_DIR}:/os:ro,z" -v "${E2E_EGRESS_OS_LIB}:/egress-os.sh:ro,z" "${image}" bash -c '
		source /egress-os.sh || exit 1
		detected="$(bash -c "source /os/registry.sh && os_detect")"
		[[ "${detected}" == "$1" ]] || { echo "BAD: detected plugin \"${detected}\", want $1"; exit 1; }
		export RIOTBOX_EGRESS_SESSION=x
		applied="$(egress_os_apply /os/registry.sh 2>&1)" || { echo "${applied}"; echo "BAD: egress_os_apply failed"; exit 1; }
		[[ "${applied}" != *"no OS plugin"* ]] || { echo "${applied}"; echo "BAD: egress_os_apply found no plugin"; exit 1; }
		eval "$2"' _ "${plugin}" "${cmd}" 2>&1
}

# e2e_refused <output>
#   Succeed when <output> shows the proxy refusing a host: a 403 from
#   Envoy, its x-riotbox-egress: denied header, or curl's CONNECT failure.
#   A negative control that fails for any other reason proves nothing.
e2e_refused() {
	grep -qE '403|x-riotbox-egress: denied|CONNECT tunnel failed' <<<"$1"
}
