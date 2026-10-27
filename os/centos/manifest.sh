#!/usr/bin/env bash
# os/centos/manifest.sh — CentOS Stream (docs/dev/os-contract.md). Sourced by
# os/registry.sh; defines functions only.

# shellcheck source=../lib/dnf.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dnf.sh"

# os_centos_repo_rewrite: point baseos, appstream, crb and extras-common at
# mirror.stream.centos.org and EPEL at dl.fedoraproject.org, the hosts of
# @centos. Their metalinks answer with third-party mirrors, many over plain
# HTTP, that no allowlist can name. The EPEL path is the one the stock
# epel.repo's commented baseurl gives. crb, extras-common and EPEL are
# optional: EPEL exists only once epel-release, from extras-common, is
# installed. crb is rewritten even while disabled, so a later `crb enable`
# (the RiotBox image runs one) needs no second rewrite.
# shellcheck disable=SC2016 # $stream, $basearch and $releasever are dnf's
os_centos_repo_rewrite() {
	local mirror=https://mirror.stream.centos.org
	os_dnf_set_baseurl baseos "${mirror}"'/$stream/BaseOS/$basearch/os/' &&
		os_dnf_set_baseurl appstream "${mirror}"'/$stream/AppStream/$basearch/os/' &&
		os_dnf_set_baseurl --optional crb "${mirror}"'/$stream/CRB/$basearch/os/' &&
		os_dnf_set_baseurl --optional extras-common "${mirror}"'/SIGs/$stream/extras/$basearch/extras-common/' &&
		os_dnf_set_baseurl --optional epel 'https://dl.fedoraproject.org/pub/epel/$releasever${stream:+s}/Everything/$basearch/'
}
