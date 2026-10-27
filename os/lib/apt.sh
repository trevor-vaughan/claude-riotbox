#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# os/lib/apt.sh — switch apt sources to HTTPS, for the OS plugins whose
# distros use apt (os/debian, os/ubuntu; docs/dev/os-contract.md).
#
# Stock Debian and Ubuntu images fetch over plain HTTP, which the egress
# proxy never forwards. apt then needs a CA bundle to verify HTTPS, and the
# stock images ship none: without one this refuses rather than downgrade TLS.
#
# Needs os_resolve from os/registry.sh, which sources this through the
# manifests.
#
# Public:
#   os_apt_https HOST...
#       In ${OS_ROOT}/etc/apt/sources.list and sources.list.d/*.list and
#       *.sources, replace http://HOST/ with https://HOST/ for each HOST.
#       Each HOST is matched and written literally (no regex or sed
#       replacement meaning). Other hosts are left alone. A symlinked
#       sources file has its target rewritten and the link kept. Running it
#       twice gives the same files. Every path is resolved with os_resolve,
#       so a link leaving ${OS_ROOT} is an error. Fails, changing nothing,
#       with no HOST or an empty one, without a non-empty
#       ${OS_ROOT}/etc/ssl/certs/ca-certificates.crt, or with no sources
#       file. Files are rewritten one by one (sed -i), so a failure part-way
#       leaves the earlier ones rewritten; the run still fails.
# ─────────────────────────────────────────────────────────────────────────────

os_apt_https() {
	local apt="${OS_ROOT:-}/etc/apt" ca="${OS_ROOT:-}/etc/ssl/certs/ca-certificates.crt" host f target pattern replacement
	local exprs=() files=()
	if (($# == 0)); then
		echo "os_apt_https: no host given" >&2
		return 1
	fi
	for host in "$@"; do
		if [[ -z "${host}" ]]; then
			echo "os_apt_https: empty host" >&2
			return 1
		fi
	done
	ca="$(os_resolve "${ca}")" || return 1
	if [[ ! -s "${ca}" ]]; then
		echo "no CA bundle (${ca}): install ca-certificates in the image; apt cannot use HTTPS without it" >&2
		return 1
	fi
	for host in "$@"; do
		pattern="$(sed 's/[][\.*^$#]/\\&/g' <<<"${host}")" || return 1
		replacement="$(sed 's/[\&#]/\\&/g' <<<"${host}")" || return 1
		exprs+=(-e "s#http://${pattern}/#https://${replacement}/#g")
	done
	for f in "${apt}/sources.list" "${apt}"/sources.list.d/*.list "${apt}"/sources.list.d/*.sources; do
		[[ -f "${f}" ]] || continue
		target="$(os_resolve "${f}")" || return 1
		files+=("${target}")
	done
	if ((${#files[@]} == 0)); then
		echo "no apt sources under ${apt}" >&2
		return 1
	fi
	sed -i "${exprs[@]}" -- "${files[@]}"
}
