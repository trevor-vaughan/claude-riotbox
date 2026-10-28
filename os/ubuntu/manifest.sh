#!/usr/bin/env bash
# os/ubuntu/manifest.sh — Ubuntu (docs/dev/os-contract.md). Sourced by
# os/registry.sh; defines functions only.

# shellcheck source=../lib/apt.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/apt.sh"

# os_ubuntu_repo_rewrite: fetch from the hosts of @ubuntu over HTTPS.
os_ubuntu_repo_rewrite() {
	local out hosts
	out="$(os_hosts ubuntu)" || return 1
	if [[ -z "${out}" ]]; then
		echo "os_ubuntu_repo_rewrite: no hosts in @ubuntu" >&2
		return 1
	fi
	mapfile -t hosts <<<"${out}"
	os_apt_https "${hosts[@]}"
}
