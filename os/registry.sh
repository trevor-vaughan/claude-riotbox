#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# os/registry.sh — the OS plugins egress mode uses to reach a distro's
# packages (RIOTBOX_EGRESS=1; docs/dev/os-contract.md).
#
# A plugin is os/<ID>/ holding egress-hosts, where <ID> is the ID
# /etc/os-release gives the distro. riotbox-core reads each egress-hosts as
# the group @<ID>; this file serves the container side, where
# scripts/lib/egress-os.sh runs the plugin's rewrite. A plugin's optional
# manifest.sh defines os_<ID>_repo_rewrite and nothing else on source.
#
# Public:
#   OS_REGISTRY         the plugin names, in glob (lexical) order
#   os_release_id       print the ID of ${OS_ROOT}/etc/os-release (the last ID=
#                       line wins, one pair of surrounding quotes is stripped),
#                       or nothing when the file or the line is missing. The
#                       file is parsed, never sourced.
#   os_detect           print the plugin named after os_release_id,
#                       or nothing. ID_LIKE is ignored: a derivative
#                       (Rocky, Alma, Mint) is not its parent.
#   os_call NAME VERB   run os_NAME_VERB; 127 with a message when undefined
#   os_hosts NAME       print NAME's egress-hosts entries, one per line
#   os_resolve PATH     print PATH with symlinks resolved. When OS_ROOT is set,
#                       fail unless the result lies inside OS_ROOT: an absolute
#                       symlink would otherwise reach the host's own files.
#                       Plugins resolve every file they read or rewrite with it.
#
# OS_ROOT (default empty) prefixes every path the registry and the plugins
# read or write, so tests run them against a fixture tree.
# ─────────────────────────────────────────────────────────────────────────────

_os_registry_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OS_REGISTRY=()
for _os_hosts_file in "${_os_registry_dir}"/*/egress-hosts; do
	[[ -f "${_os_hosts_file}" ]] || continue
	_os="$(basename "$(dirname "${_os_hosts_file}")")"
	case "${_os}" in
	_* | .*) continue ;;
	*) ;;
	esac
	OS_REGISTRY+=("${_os}")
	if [[ -f "${_os_registry_dir}/${_os}/manifest.sh" ]]; then
		# shellcheck source=/dev/null
		source "${_os_registry_dir}/${_os}/manifest.sh"
	fi
done
unset _os_hosts_file _os

os_release_id() {
	local file="${OS_ROOT:-}/etc/os-release" line id=""
	[[ -r "${file}" ]] || return 0
	while IFS= read -r line || [[ -n "${line}" ]]; do
		[[ "${line}" == ID=* ]] || continue
		id="${line#ID=}"
		id="${id#[\"\']}"
		id="${id%[\"\']}"
	done <"${file}"
	printf '%s' "${id}"
}

os_detect() {
	local id name
	id="$(os_release_id)"
	for name in "${OS_REGISTRY[@]}"; do
		if [[ "${name}" == "${id}" ]]; then
			printf '%s\n' "${name}"
			return 0
		fi
	done
}

os_call() {
	local name="$1" verb="$2"
	shift 2
	if ! declare -F "os_${name}_${verb}" >/dev/null; then
		echo "os_call: OS plugin ${name} has no ${verb}" >&2
		return 127
	fi
	"os_${name}_${verb}" "$@"
}

os_hosts() {
	local line
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -z "${line}" ]] || printf '%s\n' "${line}"
	done <"${_os_registry_dir}/$1/egress-hosts"
}

os_resolve() {
	local target root
	target="$(readlink -m -- "$1")" || return 1
	if [[ -n "${OS_ROOT:-}" ]]; then
		root="$(readlink -m -- "${OS_ROOT}")" || return 1
		root="${root%/}"
		if [[ "${target}" != "${root}" && "${target}" != "${root}"/* ]]; then
			echo "os_resolve: $1 resolves to ${target}, outside ${OS_ROOT}" >&2
			return 1
		fi
	fi
	printf '%s\n' "${target}"
}
