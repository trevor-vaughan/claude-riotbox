#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# os/lib/dnf.sh — rewrite a dnf repo to one baseurl, for the OS plugins whose
# distros use dnf (os/centos, os/fedora; docs/dev/os-contract.md).
#
# Needs os_resolve from os/registry.sh, which sources this through the
# manifests.
#
# The .repo file is edited directly, not with `dnf config-manager`, whose
# syntax differs between dnf4 (CentOS Stream 10) and dnf5 (Fedora 41+).
#
# Public:
#   os_dnf_set_baseurl [--optional] REPO-ID URL
#       In the ${OS_ROOT}/etc/yum.repos.d/*.repo file holding [REPO-ID], drop
#       that section's metalink=, mirrorlist= and baseurl= lines (with any
#       indented continuation lines) and put baseurl=URL right after its
#       header. Every other line, section and comment is kept, and so is
#       the file's mode. Running it twice gives the same file. URL is
#       written as given (no backslash escapes), so dnf's own $-variables
#       stay for dnf to expand. A header with trailing blanks or a CR still
#       matches, as in dnf. If the .repo file is a symlink, its target is
#       rewritten and the link is kept; a link that leaves ${OS_ROOT} (os_resolve)
#       is an error.
#       With no such repo: an error, or with --optional, nothing.
# ─────────────────────────────────────────────────────────────────────────────

os_dnf_set_baseurl() {
	local optional=false
	if [[ "$1" == --optional ]]; then
		optional=true
		shift
	fi
	local id="$1" url="$2" dir="${OS_ROOT:-}/etc/yum.repos.d" file="" f real tmp
	for f in "${dir}"/*.repo; do
		[[ -f "${f}" ]] || continue
		real="$(os_resolve "${f}")" || return 1
		if awk -v header="[${id}]" '{ sub(/[ \t\r]+$/, "") } $0 == header { found = 1 } END { exit !found }' "${real}"; then
			file="${real}"
			break
		fi
	done
	if [[ -z "${file}" ]]; then
		"${optional}" && return 0
		echo "no [${id}] repo in ${dir}" >&2
		return 1
	fi
	tmp="$(mktemp "${file}.XXXXXX")" || return 1
	if ! RB_URL="${url}" awk -v header="[${id}]" '
		/^\[/ { line = $0; sub(/[ \t\r]+$/, "", line); in_repo = (line == header); dropping = 0; print; if (in_repo) print "baseurl=" ENVIRON["RB_URL"]; next }
		in_repo && /^(metalink|mirrorlist|baseurl)[ \t]*=/ { dropping = 1; next }
		in_repo && dropping && /^[ \t]+[^ \t]/ { next }
		{ dropping = 0; print }
	' "${file}" >"${tmp}" || ! chmod --reference="${file}" "${tmp}" || ! mv -f "${tmp}" "${file}"; then
		rm -f "${tmp}"
		echo "could not rewrite ${file}" >&2
		return 1
	fi
}
