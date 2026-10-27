#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/egress-os.sh — in an egress session (RIOTBOX_EGRESS=1), point
# the distro's package manager at its own HTTPS mirror, which the @<ID>
# group allows (docs/dev/os-contract.md). Stock repo configs use metalinks
# or plain HTTP, which the proxy refuses.
#
# container/entrypoint.sh sources this file and calls egress_os_apply before
# any agent starts. In the image it is ~/.riotbox/lib/egress-os.sh and the
# plugins are ~/.riotbox/os/.
#
# Public:
#   egress_os_apply REGISTRY
#       Outside an egress session (RIOTBOX_EGRESS_SESSION unset or empty), do
#       nothing. Otherwise source REGISTRY (os/registry.sh) in a child shell,
#       find the plugin for this distro (os_detect) and run its repo_rewrite
#       as root: directly as uid 0, else under `sudo -n` (the image's user has
#       passwordless sudo, which resets the environment: the rewrite gets only
#       REGISTRY and the plugin name, as arguments). A plugin without a
#       rewrite needs none. Warns and returns 0 when no plugin matches; warns
#       and returns 1 when REGISTRY is unreadable or the rewrite fails. Either
#       way the session starts: everything but the package manager still works.
#       OS_ROOT (tests only) is honoured by the detection here, not by the
#       rewrite under a real sudo.
# ─────────────────────────────────────────────────────────────────────────────

egress_os_apply() {
	local registry="$1" name id sudo=()
	[[ -n "${RIOTBOX_EGRESS_SESSION:-}" ]] || return 0
	if [[ ! -r "${registry}" ]]; then
		echo "WARNING: egress: no OS plugin registry at ${registry}; the package manager keeps its stock mirrors, which the proxy refuses." >&2
		return 1
	fi
	# shellcheck disable=SC2016 # expanded by the child shell
	name="$(bash -c 'source "$1" && os_detect' _ "${registry}")"
	if [[ -z "${name}" ]]; then
		# shellcheck disable=SC2016 # expanded by the child shell
		id="$(bash -c 'source "$1" && os_release_id' _ "${registry}")"
		echo "WARNING: egress: no OS plugin for ID=${id:-unknown}; the package manager keeps its stock mirrors, which the proxy may refuse." >&2
		return 0
	fi
	# shellcheck disable=SC2016 # expanded by the child shell
	bash -c 'source "$1" && declare -F "os_$2_repo_rewrite" >/dev/null' _ "${registry}" "${name}" || return 0
	(( EUID == 0 )) || sudo=(sudo -n)
	# shellcheck disable=SC2016 # expanded by the child shell
	if ! "${sudo[@]}" bash -c 'source "$1" && os_call "$2" repo_rewrite' _ "${registry}" "${name}"; then
		echo "WARNING: egress: the ${name} repo rewrite failed; the package manager keeps its stock mirrors, which the proxy refuses." >&2
		return 1
	fi
}
