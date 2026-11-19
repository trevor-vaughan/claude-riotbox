#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# host-config.sh — the host config files ($XDG_CONFIG_HOME/riotbox/config,
# $RIOTBOX_SYSCONF_DIR/config) are bash that riotbox sources as the user, so
# anyone able to write one runs code as the user. See docs/dev/host-config.md.
# Sourcing only defines functions.
#
# Public:
#   riotbox_config_vet
#                 set RIOTBOX_CONFIG_FILES to the config files to source, in
#                 order; return 1, saying why, when one is not safe to
#                 source. The caller sources each at its own scope.
# ─────────────────────────────────────────────────────────────────────────────

# _riotbox_config_why <path> — print why <path> must not be trusted, or
# nothing: it is owned by neither this user nor root, or group or other may
# write it. Each reason carries its fix.
_riotbox_config_why() {
	local out uid mode
	if ! out="$(stat -c '%u %a' -- "$1" 2>&1)"; then
		echo "cannot be checked (${out})"
		return
	fi
	read -r uid mode <<<"${out}"
	if [[ "${uid}" != "${EUID}" && "${uid}" != 0 ]]; then
		echo "is owned by uid ${uid}, not you or root (chown ${EUID} $1)"
	elif ((8#${mode} & 8#022)); then
		echo "is writable by group or other (chmod go-w $1)"
	fi
}

# riotbox_config_vet — set RIOTBOX_CONFIG_FILES to the resolved paths of the
# user config then the system config (the precedence the callers document),
# leaving out a file that does not exist (a dangling link included). Return
# 1, saying why on stderr, when a present file is not a regular file, or
# when it, the directory holding its name, or the directory holding the file
# it resolves to fails _riotbox_config_why: whoever could write any of them
# could put code in the file, or point its name at their own. Warn when the
# user config is readable by others: it often holds keys.
riotbox_config_vet() {
	local file real path why mode
	RIOTBOX_CONFIG_FILES=()
	for file in "${XDG_CONFIG_HOME:-${HOME}/.config}/riotbox/config" "${RIOTBOX_SYSCONF_DIR:-/etc/riotbox}/config"; do
		[[ -e "${file}" ]] || continue
		if ! real="$(realpath -e -- "${file}" 2>&1)"; then
			why="cannot be resolved (${real})"
			path="${file}"
		elif [[ ! -f "${real}" ]]; then
			why="is not a regular file (replace it with one)"
			path="${real}"
		else
			why=""
			for path in "${real}" "$(realpath -e -- "${file%/*}")" "${real%/*}"; do
				why="$(_riotbox_config_why "${path}")"
				[[ -z "${why}" ]] || break
			done
		fi
		if [[ -n "${why}" ]]; then
			echo "ERROR: riotbox will not source ${file}: ${path} ${why}." >&2
			echo "       Whoever can write it can run commands as you. See README \"Config file security\"." >&2
			return 1
		fi
		if [[ "${file}" == "${XDG_CONFIG_HOME:-${HOME}/.config}/riotbox/config" ]] &&
			mode="$(stat -c '%a' -- "${real}")" && ((8#${mode} & 8#044)); then
			echo "WARNING: ${file} is readable by other users and may hold keys: chmod 600 ${real}" >&2
		fi
		RIOTBOX_CONFIG_FILES+=("${real}")
	done
}
