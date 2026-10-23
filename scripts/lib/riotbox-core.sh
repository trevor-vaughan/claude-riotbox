#!/usr/bin/env bash
# scripts/lib/riotbox-core.sh — find the riotbox-core binary and refuse a
# missing or mismatched one.
#
# Sourced by scripts/mount-projects.sh (the key adapters) and
# scripts/preflight.sh (`riotbox doctor`). The binary lives at
# libexec/riotbox-core in the app tree this file belongs to. It must print
# exactly the tree's VERSION: a binary from another release would compute
# with another release's rules, and `install.sh --binary` from a checkout
# ahead of its release is exactly how that pairing happens.
#
# Public:
#   riotbox_core_require
#     Return 0 when the binary at RIOTBOX_CORE is executable and matches
#     VERSION. Otherwise print riotbox_core_problem's message as an ERROR to
#     stderr and return 1. Every call checks afresh: the adapters run in
#     command substitutions, so a per-shell cache would never be reused.
#   riotbox_core_problem
#     Print why the binary is unusable (empty when it is usable). Used by
#     preflight, which reports through its own formatter.

_RIOTBOX_CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RIOTBOX_CORE="${_RIOTBOX_CORE_ROOT}/libexec/riotbox-core"

riotbox_core_problem() {
	local want found="missing"
	want="$(cat "${_RIOTBOX_CORE_ROOT}/VERSION" 2>/dev/null)" || want="unknown"
	if [[ -x "${RIOTBOX_CORE}" ]]; then
		found="$("${RIOTBOX_CORE}" version 2>/dev/null)" || found="unrunnable"
		[[ "${found}" == "${want}" ]] && return 0
	elif [[ -e "${RIOTBOX_CORE}" ]]; then
		found="not executable"
	fi
	printf "riotbox-core missing or does not match VERSION %s (found %s); run 'task go:build' (checkout), reinstall with ./install.sh --build|--binary (rootless), or reinstall the riotbox package (rpm/deb)\n" \
		"${want}" "${found}"
}

riotbox_core_require() {
	local problem
	problem="$(riotbox_core_problem)"
	[[ -z "${problem}" ]] && return 0
	echo "ERROR: ${problem}" >&2
	return 1
}
