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
#   config_protect_mounts
#                 set CONFIG_PROTECT_FLAGS so no agent mount lets the agent
#                 change the user config dir; return 1, saying why, for what
#                 cannot be protected. Requires: agent_bind_mounts and
#                 bind_mount_access (scripts/lib/bind-mounts.sh) and its
#                 four flag variables.
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

# config_protect_mounts — set CONFIG_PROTECT_FLAGS to --mount flags that keep
# the agent from changing the user config dir C ($XDG_CONFIG_HOME/riotbox)
# through a read-write bind mount whose real source is above C (`riotbox ~`):
# a bind of each directory strictly between that source and C onto itself,
# then a read-only bind of C, at the matching container paths. A read-only
# bind of C alone is not enough: the agent could rename a directory above it
# and recreate C at its host path; a mount point cannot be renamed. A
# destination an agent mount already uses is skipped (it is a mount point
# already, and podman refuses a duplicate); each is listed once, CSV
# quoted as podman reads --mount. C is created (0700) first if a mount
# needs it protected. Return 1, saying why, for a read-write mount of C or
# of anything in it; an overlay upperdir or workdir at, in or above C
# (podman writes there); with RIOTBOX_NESTED=1, any mount reaching C, since
# the agent's CAP_SYS_ADMIN could remove a pin; and a link on the config's
# path inside a read-write mount, which the agent could repoint.
# Read-only and overlay mounts need no pins (bind_mount_access).
# shellcheck disable=SC2154 # agent_bind_mounts reads launch.sh's flags
config_protect_mounts() {
	local cfg dir real origin src dst opts host field upper rsrc access link part p dest path flag i k
	local -a recs=() fields=() links=() parts=() reach_src=() reach_dst=()
	local -A taken=() seen=()
	CONFIG_PROTECT_FLAGS=()
	cfg="$(realpath -m -s -- "${XDG_CONFIG_HOME:-${HOME}/.config}/riotbox/config")"
	dir="${cfg%/*}"
	real="$(realpath -m -- "${dir}")"
	# Where each link on the config's path lives: the resolved directory
	# holding it, plus its name.
	p=""
	IFS=/ read -ra parts <<<"${cfg#/}"
	for part in "${parts[@]}"; do
		p+="/${part}"
		[[ -L "${p}" ]] || continue
		link="$(realpath -m -- "${p%/*}/")"
		links+=("${link%/}/${p##*/}")
	done
	# shellcheck disable=SC2312 # agent_bind_mounts only prints
	mapfile -d '' -t recs < <(agent_bind_mounts)
	for ((i = 0; i + 4 < ${#recs[@]}; i += 5)); do
		[[ -z "${recs[i + 2]}" ]] || taken["${recs[i + 2]}"]=1
	done
	for ((i = 0; i + 4 < ${#recs[@]}; i += 5)); do
		origin="${recs[i]}" src="${recs[i + 1]}" dst="${recs[i + 2]}" opts="${recs[i + 3]}" host="${recs[i + 4]}"
		IFS=, read -ra fields <<<"${opts}"
		for field in "${fields[@]}"; do
			[[ "${field}" == upperdir=* || "${field}" == workdir=* ]] || continue
			upper="$(realpath -m -- "${field#*=}")"
			[[ "${upper%/}/" == "${real}/"* || "${real}/" == "${upper%/}/"* ]] || continue
			echo "ERROR: ${origin} sets ${field}: podman writes the agent's changes there, and it reaches the riotbox config (${cfg}), which runs as you on the host." >&2
			echo "       Keep the overlay's upperdir and workdir away from ${dir}. See README \"Config file security\"." >&2
			return 1
		done
		[[ "${host}" = 1 && -n "${src}" && -n "${dst}" ]] || continue
		rsrc="$(realpath -m -- "${src}")"
		access="$(bind_mount_access "${opts}")"
		if [[ "${access}" == rw ]]; then
			for link in "${links[@]}"; do
				[[ "${link}" == "${rsrc%/}/"* ]] || continue
				echo "ERROR: ${origin} mounts ${src} read-write, and ${link} is a link on the path to the riotbox config (${cfg}): the agent could point it at a config of its own, which would run as you on the host." >&2
				echo "       Mount it read-only (:ro), or replace the link with what it points at. See README \"Config file security\"." >&2
				return 1
			done
		fi
		[[ "${rsrc%/}/" == "${real}/"* || "${real}/" == "${rsrc%/}/"* ]] || continue
		if [[ "${RIOTBOX_NESTED:-}" = 1 ]]; then
			echo "ERROR: RIOTBOX_NESTED=1 refuses ${origin} mounting ${src}: it reaches the riotbox config (${cfg}), and nested mode's CAP_SYS_ADMIN could let the agent undo the read-only mount that protects it." >&2
			echo "       Mount a narrower directory, or run without RIOTBOX_NESTED=1. See README \"Config file security\"." >&2
			return 1
		fi
		[[ "${access}" == rw ]] || continue
		if [[ "${rsrc%/}/" == "${real}/"* ]]; then
			echo "ERROR: ${origin} mounts ${src} read-write: it holds the riotbox config (${cfg}), which runs as you on the host at every launch." >&2
			echo "       Mount it read-only (:ro), or mount a different directory. See README \"Config file security\"." >&2
			return 1
		fi
		reach_src+=("${rsrc}") reach_dst+=("${dst}")
	done
	((${#reach_src[@]})) || return 0
	if [[ ! -d "${dir}" ]] && { ! mkdir -p -- "${dir}" || ! chmod 700 -- "${dir}"; }; then
		echo "ERROR: could not create ${dir} to mount it read-only under ${reach_src[0]}." >&2
		echo "       Create it yourself (mkdir -m 700 ${dir}). See README \"Config file security\"." >&2
		return 1
	fi
	for ((i = 0; i < ${#reach_src[@]}; i++)); do
		src="${reach_src[i]}" dst="${reach_dst[i]}"
		IFS=/ read -ra parts <<<"${real#"${src%/}/"}"
		p=""
		for ((k = 0; k < ${#parts[@]}; k++)); do
			p+="/${parts[k]}"
			dest="${dst%/}${p}"
			[[ -z "${taken["${dest}"]:-}" && -z "${seen["${dest}"]:-}" ]] || continue
			seen["${dest}"]=1
			path="${src%/}${p}"
			flag="type=bind,\"source=${path//\"/\"\"}\",\"destination=${dest//\"/\"\"}\""
			((k + 1 < ${#parts[@]})) || flag+=",readonly"
			CONFIG_PROTECT_FLAGS+=(--mount "${flag}")
		done
	done
}
