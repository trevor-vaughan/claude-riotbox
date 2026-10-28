#!/usr/bin/env bash
# os/fedora/manifest.sh — Fedora (docs/dev/os-contract.md). Sourced by
# os/registry.sh; defines functions only.

# shellcheck source=../lib/dnf.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dnf.sh"

# os_fedora_repo_rewrite: point fedora and updates at dl.fedoraproject.org,
# the host of @fedora, in place of their metalinks. fedora-cisco-openh264
# (Cisco's host, skip_if_unavailable=True in the stock file) is left alone.
# Releases past end of life move to /pub/archive/ and are not covered.
# shellcheck disable=SC2016 # $releasever and $basearch are dnf's
os_fedora_repo_rewrite() {
	local base=https://dl.fedoraproject.org/pub/fedora/linux
	os_dnf_set_baseurl fedora "${base}"'/releases/$releasever/Everything/$basearch/os/' &&
		os_dnf_set_baseurl updates "${base}"'/updates/$releasever/Everything/$basearch/'
}
