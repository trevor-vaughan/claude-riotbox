#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bind-mounts.sh — the agent's mounts as the engine will read them. Shared
# by the egress guards (libexec/egress-lib.sh) and the config protection
# (scripts/lib/host-config.sh). Sourcing only defines functions.
#
# Public:
#   engine_args_split <args>  print engine flags as NUL-terminated records
#   agent_bind_mounts         print each bind mount of the agent as five
#                             NUL-terminated fields. Requires:
#                             PROJECT_VOLUME_FLAGS, MOUNTS, CREDFILE_FLAGS,
#                             RIOTBOX_EXTRA_ARGS (each may be unset).
#   bind_mount_access <opts>  print ro, overlay or rw for a mount's options
# ─────────────────────────────────────────────────────────────────────────────

# engine_args_split <args> — print engine flags <args>, split on whitespace
# as launch.sh splits them into the run command, as NUL-terminated records
# in the order podman reads them: `w<word>` for each word; for each mount,
# `m<flag>` (-v, --volume or --mount) followed by its value; for each
# -e/--env, `e<value>`; for each --secret, `s<value>`; and for each --pid,
# `p<value>`. A word that is a flag's value is also printed as a
# word, so a check of words still sees it. Grouped short flags are read as
# podman parses them: its boolean ones (-d -i -P -q -t) are skipped; a v or
# an e then takes the rest of the word, less one =, or else the next word.
# Any other letter takes the rest as its own value.
engine_args_split() {
	local args="$1" arg flag="" short
	# shellcheck disable=SC2086 # split as launch.sh splits it into the run command
	for arg in ${args}; do
		case "${flag}" in
		"") ;;
		-e | --env) printf 'e%s\0' "${arg}" ;;
		--secret) printf 's%s\0' "${arg}" ;;
		--pid) printf 'p%s\0' "${arg}" ;;
		*) printf 'm%s\0%s\0' "${flag}" "${arg}" ;;
		esac
		flag=""
		printf 'w%s\0' "${arg}"
		case "${arg}" in
		--volume | --mount | --env | --secret | --pid) flag="${arg}" ;;
		--volume=* | --mount=*) printf 'm%s\0%s\0' "${arg%%=*}" "${arg#*=}" ;;
		--env=*) printf 'e%s\0' "${arg#*=}" ;;
		--secret=*) printf 's%s\0' "${arg#*=}" ;;
		--pid=*) printf 'p%s\0' "${arg#*=}" ;;
		--*) ;;
		-?*)
			short="${arg#-}"
			while [[ "${short}" == [diPqt]* ]]; do short="${short:1}"; done
			if [[ "${short}" == [ev]* ]]; then
				flag="-${short:0:1}"
				short="${short:1}"
				short="${short#=}"
				if [[ -n "${short}" ]]; then
					case "${flag}" in
					-e) printf 'e%s\0' "${short}" ;;
					*) printf 'm-v\0%s\0' "${short}" ;;
					esac
					flag=""
				fi
			fi
			;;
		*) ;;
		esac
	done
}

# agent_bind_mounts — print each bind mount of the agent's mounts
# (PROJECT_VOLUME_FLAGS, MOUNTS, CREDFILE_FLAGS, RIOTBOX_EXTRA_ARGS, read as
# engine_args_split reads them) as five NUL-terminated fields: where it
# came from, its source, its container destination without trailing
# slashes, its options (the -v options; for --mount, the fields other than
# type, source and destination, comma-joined in order), and 1 when the
# source is a host path (a -v source starting with / or ., or any --mount
# type=bind source) or 0 (a -v volume name). A -v without a destination
# (an anonymous volume) and a --mount of any other type are skipped. The source and the
# destination may be empty (`-v /a:`, `-v :/x`, a --mount without source=):
# callers must check.
agent_bind_mounts() {
	local spec origin rec value src dst opts host type field i
	local -a recs fields
	for spec in "PROJECT_VOLUME_FLAGS:project" "MOUNTS:mounts.conf" "CREDFILE_FLAGS:credential files" "RIOTBOX_EXTRA_ARGS:RIOTBOX_EXTRA_ARGS"; do
		origin="${spec#*:}"
		spec="${spec%%:*}"
		# shellcheck disable=SC2312 # engine_args_split only prints
		mapfile -d '' -t recs < <(engine_args_split "${!spec:-}")
		for ((i = 0; i < ${#recs[@]}; i++)); do
			rec="${recs[i]}"
			[[ "${rec}" == m* ]] || continue
			i=$((i + 1))
			value="${recs[i]}"
			src=""
			dst=""
			opts=""
			host=1
			if [[ "${rec}" == m--mount ]]; then
				type=volume
				IFS=, read -ra fields <<<"${value}"
				for field in "${fields[@]}"; do
					case "${field}" in
					type=*) type="${field#type=}" ;;
					src=* | source=*) src="${field#*=}" ;;
					dst=* | dest=* | destination=* | target=*) dst="${field#*=}" ;;
					*) opts="${opts:+${opts},}${field}" ;;
					esac
				done
				[[ "${type}" == bind ]] || continue
			else
				[[ "${value}" == *:* ]] || continue
				src="${value%%:*}"
				dst="${value#*:}"
				[[ "${dst}" != *:* ]] || opts="${dst#*:}"
				dst="${dst%%:*}"
				[[ "${src}" == /* || "${src}" == .* ]] || host=0
			fi
			while [[ "${dst}" == */ && "${dst}" != / ]]; do dst="${dst%/}"; done
			printf '%s\0%s\0%s\0%s\0%s\0' "${origin}" "${src}" "${dst}" "${opts}" "${host}"
		done
	done
}

# bind_mount_access <opts> — print how the agent may write through a mount
# whose options are <opts> (comma-separated, as agent_bind_mounts prints
# them): overlay (O: podman writes the agent's changes to a copy), ro, or
# rw. Fails closed: an option not recognised as read-only is not read-only,
# and rw, ro=false or readonly=false anywhere wins over any read-only option.
bind_mount_access() {
	local field ro=0 overlay=0
	local -a fields
	IFS=, read -ra fields <<<"$1"
	for field in "${fields[@]}"; do
		case "${field}" in
		ro | readonly | ro=true | readonly=true) ro=1 ;;
		O) overlay=1 ;;
		*) ;;
		esac
	done
	for field in "${fields[@]}"; do
		case "${field}" in
		rw | ro=false | readonly=false) ro=0 ;;
		*) ;;
		esac
	done
	if ((overlay)); then
		echo overlay
	elif ((ro)); then
		echo ro
	else
		echo rw
	fi
}
