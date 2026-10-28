#!/usr/bin/env bash
# os/debian/manifest.sh — Debian (docs/dev/os-contract.md). Sourced by
# os/registry.sh; defines functions only.

# shellcheck source=../lib/apt.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/apt.sh"

# os_debian_repo_rewrite: fetch from the hosts of @debian over HTTPS.
os_debian_repo_rewrite() {
	local out hosts
	out="$(os_hosts debian)" || return 1
	if [[ -z "${out}" ]]; then
		echo "os_debian_repo_rewrite: no hosts in @debian" >&2
		return 1
	fi
	mapfile -t hosts <<<"${out}"
	os_apt_https "${hosts[@]}"
}
