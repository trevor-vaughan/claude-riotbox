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
#                 change the user config; return 1, saying why, for what
#                 cannot be protected. Requires: scripts/lib/bind-mounts.sh
#                 and its four flag variables.
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

# _config_walk <path> — resolve the absolute <path> as the kernel does,
# component by component, following every link: an absolute target restarts
# at /, a relative one is spliced in front of the components left, . is
# skipped and .. leaves the directory resolved so far. Set CONFIG_WALK_DIRS
# to each real directory descended into, once, in order, / excluded (a
# component that does not exist yet counts as one; the set holds every
# ancestor along each descent); CONFIG_WALK_LINKS to the real location of
# each link met (the resolved directory holding it, plus its name); and
# CONFIG_WALK_FILE to the real path. Return 1 past 40 links (a loop), as
# the kernel does, or when a link cannot be read.
_config_walk() {
	local cur="" comp target links=0
	local -a todo=() more=()
	local -A walked=()
	CONFIG_WALK_DIRS=() CONFIG_WALK_LINKS=() CONFIG_WALK_FILE=""
	IFS=/ read -ra todo <<<"$1"
	while ((${#todo[@]})); do
		comp="${todo[0]}"
		todo=("${todo[@]:1}")
		case "${comp}" in
		"" | .) ;;
		..) cur="${cur%/*}" ;;
		*)
			if [[ -L "${cur}/${comp}" ]]; then
				((++links <= 40)) || return 1
				CONFIG_WALK_LINKS+=("${cur}/${comp}")
				target="$(readlink -- "${cur}/${comp}")" || return 1
				[[ "${target}" != /* ]] || cur=""
				IFS=/ read -ra more <<<"${target}"
				todo=("${more[@]}" "${todo[@]}")
			elif ((${#todo[@]})); then
				cur+="/${comp}"
				[[ -z "${walked["${cur}"]:-}" ]] || continue
				walked["${cur}"]=1
				CONFIG_WALK_DIRS+=("${cur}")
			else
				CONFIG_WALK_FILE="${cur}/${comp}"
			fi
			;;
		esac
	done
	[[ -n "${CONFIG_WALK_FILE}" ]] || CONFIG_WALK_FILE="${cur:-/}"
}

# _config_under <dir> <path>... — succeed when any <path> is <dir> or is
# inside it.
_config_under() {
	local dir="${1%/}" path
	shift
	for path in "$@"; do
		[[ "${path}" != "${dir}" && "${path}" != "${dir}/"* ]] || return 0
	done
	return 1
}

# config_protect_mounts — set CONFIG_PROTECT_FLAGS to --mount flags that keep
# the agent from changing the user config F, where the host resolves
# $XDG_CONFIG_HOME/riotbox/config (_config_walk), through a read-write bind
# mount whose real source reaches it without holding it (`riotbox ~`, or a
# dotfiles repo the config links into): a bind onto itself of each directory
# walked through under that source, then a read-only bind of F's directory
# P, at the matching container paths. A read-only bind of P alone is not
# enough: the agent could rename a directory above it and recreate P at its
# host path; a mount point cannot be renamed. A destination an agent mount
# already uses is skipped (it is a mount point already, and podman refuses a
# duplicate); each is listed once, CSV quoted as podman reads --mount. P is
# created (0700) first if a mount needs it protected. A mount reaches F when
# its source is P or inside P, or holds F, a directory walked through or a
# link met. Return 1, saying why, for: a relative config path or a link
# loop; a --mount that agent_bind_mounts cannot read (mount_unreadable_why);
# an overlay upperdir or workdir in P or reaching F (podman writes there); a
# mount reaching F when the agent gets CAP_SYS_ADMIN, which could remove a
# pin (RIOTBOX_NESTED=1, or --privileged or --cap-add SYS_ADMIN or ALL in
# RIOTBOX_EXTRA_ARGS); a read-write mount holding a link met, which the
# agent could repoint, or P or anything in it; and a walked directory under
# a read-write mount that does not exist and cannot be pinned. Read-only
# and overlay mounts need no pins (bind_mount_access).
# shellcheck disable=SC2154 # agent_bind_mounts reads launch.sh's flags
config_protect_mounts() {
	local cfg file parent spec origin src dst opts host field upper rsrc access link dir dest flag elevated="" word prev="" cap why i
	local -a recs=() fields=() caps=() reach=() reach_src=() reach_dst=()
	local -A taken=() seen=()
	CONFIG_PROTECT_FLAGS=()
	cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/riotbox/config"
	if [[ "${cfg}" != /* ]]; then
		echo "ERROR: the riotbox config path ${cfg} is not absolute: riotbox would read it relative to the current directory, which the agent may be able to write." >&2
		echo "       Set XDG_CONFIG_HOME to an absolute path, or unset it. See README \"Config file security\"." >&2
		return 1
	fi
	# shellcheck disable=SC2310 # its failure is reported here
	if ! _config_walk "${cfg}"; then
		echo "ERROR: the riotbox config path ${cfg} cannot be resolved: it meets a link loop, or more than 40 links." >&2
		echo "       Fix the links on its path. See README \"Config file security\"." >&2
		return 1
	fi
	file="${CONFIG_WALK_FILE}"
	parent="${file%/*}"
	reach=("${file}" "${CONFIG_WALK_DIRS[@]}" "${CONFIG_WALK_LINKS[@]}")
	for spec in "PROJECT_VOLUME_FLAGS:project" "MOUNTS:mounts.conf" "CREDFILE_FLAGS:credential files" "RIOTBOX_EXTRA_ARGS:RIOTBOX_EXTRA_ARGS"; do
		origin="${spec#*:}"
		spec="${spec%%:*}"
		# shellcheck disable=SC2312 # engine_args_split only prints
		mapfile -d '' -t recs < <(engine_args_split "${!spec:-}")
		for ((i = 0; i < ${#recs[@]}; i++)); do
			[[ "${recs[i]}" == m* ]] || continue
			i=$((i + 1))
			[[ "${recs[i - 1]}" == m--mount ]] || continue
			why="$(mount_unreadable_why "${recs[i]}")"
			[[ -n "${why}" ]] || continue
			echo "ERROR: ${origin} has a --mount with ${why}, which riotbox cannot check for a mount reaching the riotbox config (${cfg})." >&2
			echo "       Write it as type=bind,source=…,destination=… without quotes, or as -v. See README \"Config file security\"." >&2
			return 1
		done
	done
	[[ "${RIOTBOX_NESTED:-}" != 1 ]] || elevated="RIOTBOX_NESTED=1"
	# shellcheck disable=SC2312 # engine_args_split only prints
	mapfile -d '' -t recs < <(engine_args_split "${RIOTBOX_EXTRA_ARGS:-}")
	for ((i = 0; i < ${#recs[@]} && ${#elevated} == 0; i++)); do
		[[ "${recs[i]}" == m* ]] && i=$((i + 1)) && continue
		[[ "${recs[i]}" == w* ]] || continue
		word="${recs[i]#w}"
		cap=""
		case "${word}" in
		--privileged | --privileged=true) elevated="RIOTBOX_EXTRA_ARGS ${word}" ;;
		--cap-add=*) cap="${word#*=}" flag="${word}" ;;
		*) [[ "${prev}" != --cap-add ]] || cap="${word}" flag="--cap-add ${word}" ;;
		esac
		prev="${word}"
		IFS=, read -ra caps <<<"${cap^^}"
		for cap in "${caps[@]}"; do
			[[ "${cap#CAP_}" != SYS_ADMIN && "${cap#CAP_}" != ALL ]] || elevated="RIOTBOX_EXTRA_ARGS ${flag}"
		done
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
			# shellcheck disable=SC2310 # a test, not an action
			_config_under "${parent}" "${upper}" || _config_under "${upper}" "${reach[@]}" || continue
			echo "ERROR: ${origin} sets ${field}: podman writes the agent's changes there, and it reaches the riotbox config (${cfg}), which runs as you on the host." >&2
			echo "       Keep the overlay's upperdir and workdir away from ${parent} and the path to it. See README \"Config file security\"." >&2
			return 1
		done
		[[ "${host}" = 1 && -n "${src}" && -n "${dst}" ]] || continue
		rsrc="$(realpath -m -- "${src}")"
		# shellcheck disable=SC2310 # a test, not an action
		_config_under "${parent}" "${rsrc}" || _config_under "${rsrc}" "${reach[@]}" || continue
		if [[ -n "${elevated}" ]]; then
			echo "ERROR: ${elevated} refuses ${origin} mounting ${src}: it reaches the riotbox config (${cfg}), and CAP_SYS_ADMIN could let the agent undo the read-only mount that protects it." >&2
			echo "       Mount a narrower directory, or run without ${elevated}. See README \"Config file security\"." >&2
			return 1
		fi
		access="$(bind_mount_access "${opts}")"
		[[ "${access}" == rw ]] || continue
		for link in "${CONFIG_WALK_LINKS[@]}"; do
			[[ "${link}" == "${rsrc%/}/"* ]] || continue
			echo "ERROR: ${origin} mounts ${src} read-write, and ${link} is a link on the path to the riotbox config (${cfg}): the agent could point it at a config of its own, which would run as you on the host." >&2
			echo "       Mount it read-only (:ro), or replace the link with what it points at. See README \"Config file security\"." >&2
			return 1
		done
		# shellcheck disable=SC2310 # a test, not an action
		if _config_under "${parent}" "${rsrc}"; then
			echo "ERROR: ${origin} mounts ${src} read-write: it holds the riotbox config (${file}), which runs as you on the host at every launch." >&2
			echo "       Mount it read-only (:ro), or mount a different directory. See README \"Config file security\"." >&2
			return 1
		fi
		reach_src+=("${rsrc}") reach_dst+=("${dst}")
	done
	((${#reach_src[@]})) || return 0
	if [[ ! -d "${parent}" ]] && { ! mkdir -p -- "${parent}" || ! chmod 700 -- "${parent}"; }; then
		echo "ERROR: could not create ${parent} to mount it read-only under ${reach_src[0]}." >&2
		echo "       Create it yourself (mkdir -m 700 ${parent}). See README \"Config file security\"." >&2
		return 1
	fi
	for ((i = 0; i < ${#reach_src[@]}; i++)); do
		src="${reach_src[i]}" dst="${reach_dst[i]}"
		for dir in "${CONFIG_WALK_DIRS[@]}"; do
			[[ "${dir}" == "${src%/}/"* ]] || continue
			dest="${dst%/}${dir#"${src%/}"}"
			[[ -z "${taken["${dest}"]:-}" && -z "${seen["${dest}"]:-}" ]] || continue
			seen["${dest}"]=1
			if [[ ! -d "${dir}" ]]; then
				echo "ERROR: ${dir}, on the path to the riotbox config (${cfg}), does not exist, so it cannot be protected under ${src}, and the agent could create it as a link." >&2
				echo "       Create it yourself, or fix XDG_CONFIG_HOME. See README \"Config file security\"." >&2
				return 1
			fi
			flag="type=bind,\"source=${dir//\"/\"\"}\",\"destination=${dest//\"/\"\"}\""
			[[ "${dir}" != "${parent}" ]] || flag+=",readonly"
			CONFIG_PROTECT_FLAGS+=(--mount "${flag}")
		done
	done
}
