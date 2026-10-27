#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# egress-lib.sh — RIOTBOX_EGRESS=1: the egress proxy's defaults and the
# launch-side half of it. See docs/dev/egress.md.
#
# Sourced by launch.sh (gate, start, teardown) and libexec/egress.sh (conf
# paths). Sourcing only sets the variables below and defines functions; the
# Taskfile sources it to read the default image.
#
# Variables:
#   RIOTBOX_EGRESS_DEFAULT_IMAGE  the Envoy image, pinned by digest; the
#                                 RIOTBOX_EGRESS_IMAGE setting overrides it
#   EGRESS_SYSTEM_CONF            the system egress.conf
#   EGRESS_USER_CONF              the user egress.conf
#   EGRESS_FLAGS                  set by egress_start: the agent's extra
#                                 engine flags (pod, network, proxy env,
#                                 RIOTBOX_EGRESS_SESSION, and, when the
#                                 proxy injects keys, the session CA and a
#                                 placeholder per key)
#   EGRESS_MASK_FLAGS             set by egress_mask_data: the agent's tmpfs
#                                 masks over the egress root
#   EGRESS_PLACEHOLDER            what an injected key holds in the agent;
#                                 equals riotbox-core's inject.Placeholder
#   EGRESS_INJECTED               set by egress_start: the names of the keys
#                                 the proxy injects
#
# Public:
#   egress_gate   return 1, saying why, when egress mode cannot be enforced
#                 alongside the rest of the configuration. Requires:
#                 CONTAINER_CMD.
#   egress_gate_mounts
#                 the same for the mounts launch.sh builds itself (mounts.conf,
#                 project volumes, credential files). Requires: MOUNTS,
#                 PROJECT_VOLUME_FLAGS, CREDFILE_FLAGS.
#   egress_mask_data
#                 set EGRESS_MASK_FLAGS to hide the egress root from the
#                 agent wherever its mounts reach it; return 1, saying why,
#                 for a mount of a file in it, an overlay upperdir/workdir
#                 reaching it, or, with RIOTBOX_NESTED=1, any mount that
#                 needs a mask. Requires: RIOTBOX_EGRESS_ROOT,
#                 PROJECT_VOLUME_FLAGS, MOUNTS, CREDFILE_FLAGS.
#   egress_gate_env
#                 after egress_start, the same for RIOTBOX_EXTRA_ARGS that
#                 would put an injected key in the agent, or let it read
#                 one from a host process. Requires: EGRESS_INJECTED.
#   egress_start  sweep orphaned egress pods, start this launch's pod
#                 (sending egress-up the agent's variables, whose provider
#                 keys the proxy injects), export each injected key's
#                 placeholder over the key, set EGRESS_FLAGS, say on stderr
#                 which session to name to `riotbox egress`, and trap EXIT
#                 (and INT/TERM, through it) to remove the pod. Requires:
#                 CONTAINER_CMD, CONTAINER_NAME, SESSION_KEY, PROJECT_DIRS,
#                 PASSTHROUGH_FLAGS, RIOTBOX_EGRESS_ROOT, ROOT_DIR (its os/ is
#                 passed as --os-dir), RIOTBOX_CORE and
#                 riotbox_core_require (scripts/lib/riotbox-core.sh), and
#                 agent_call (agents/registry.sh).
# ─────────────────────────────────────────────────────────────────────────────

RIOTBOX_EGRESS_DEFAULT_IMAGE="docker.io/envoyproxy/envoy:distroless-v1.40.1@sha256:48a8c5ec92d9775d5483e32fbb2d6775439bdf957c1602d47afb90644526c093"
EGRESS_SYSTEM_CONF="${RIOTBOX_SYSCONF_DIR:-/etc/riotbox}/egress.conf"
EGRESS_USER_CONF="${XDG_CONFIG_HOME:-${HOME}/.config}/riotbox/egress.conf"
EGRESS_FLAGS=()
EGRESS_MASK_FLAGS=()
EGRESS_PLACEHOLDER="riotbox-egress-placeholder"
EGRESS_INJECTED=()

# _egress_mount_why <flag> <value> [origin] — print why mounting <value> of
# <flag> (-v, --volume or --mount) is refused, or nothing. <origin> names
# where the mount came from, default RIOTBOX_EXTRA_ARGS. A host engine socket
# works across network isolation, so the agent must not get one: refused
# are a socket source and the user runtime dirs (the rootless podman
# socket's home), any directory or not-yet-existing path under them (podman
# would create the latter as a directory) and any ancestor of them. A
# regular file is allowed anywhere: it cannot carry a socket. Both
# $XDG_RUNTIME_DIR and systemd's /run/user/<uid> are protected; a relative
# $XDG_RUNTIME_DIR is ignored, as the XDG spec requires. Sources are compared
# canonical, so symlinks and .. cannot dodge it. A directory elsewhere that
# holds a socket is not caught. A relative source resolves against the
# current directory, so nothing between the gate and the engine run may
# change it.
_egress_mount_why() {
	local flag="$1" value="$2" origin="${3:-RIOTBOX_EXTRA_ARGS}" field type="" fields=() srcs=() src runtimes=() runtime path forbidden
	if [[ "${flag}" = "--mount" ]]; then
		# podman reads the value as one CSV record; a quoted field is not
		# parsed here, so it cannot be checked.
		if [[ "${value}" == *'"'* ]]; then
			echo "RIOTBOX_EGRESS=1 refuses ${origin} containing --mount with a quoted field: it cannot be checked for a route around the proxy."
			return 0
		fi
		IFS=, read -ra fields <<<"${value}"
		for field in "${fields[@]}"; do
			case "${field}" in
			type=*) type="${field#type=}" ;;
			src=* | source=*) srcs+=("${field#*=}") ;;
			# A volume's driver options can bind-mount any host path, whatever
			# the type says.
			volume-opt=*)
				echo "RIOTBOX_EGRESS=1 refuses ${origin} containing --mount with volume-opt: it cannot be checked for a route around the proxy."
				return 0
				;;
			*) ;;
			esac
		done
		case "${type}" in
		bind) ;;
		glob)
			echo "RIOTBOX_EGRESS=1 refuses ${origin} containing --mount type=glob: it cannot be checked for a route around the proxy."
			return 0
			;;
		# volume (the default when omitted), image and artifact sources are
		# names, not host paths; the other types take no source.
		*) return 0 ;;
		esac
	else
		# podman reads a -v source as a host path when it starts with / or .
		# and as a volume name otherwise.
		src="${value%%:*}"
		[[ "${src}" == /* || "${src}" == .* ]] || return 0
		srcs=("${src}")
	fi
	runtime="/run/user/$(id -u)"
	runtimes=("$(realpath -m -- "${runtime}")")
	if [[ "${XDG_RUNTIME_DIR:-}" == /* ]]; then
		runtime="$(realpath -m -- "${XDG_RUNTIME_DIR}")"
		[[ "${runtime}" = "${runtimes[0]}" ]] || runtimes+=("${runtime}")
	fi
	for src in "${srcs[@]}"; do
		path="$(realpath -m -- "${src}")"
		# A regular file cannot carry a socket, wherever it lives; the path
		# is already resolved, so a link cannot pose as one.
		[[ ! -f "${path}" ]] || continue
		forbidden=0
		[[ ! -S "${path}" ]] || forbidden=1
		for runtime in "${runtimes[@]}"; do
			# Trailing slashes make the prefix test compare whole components.
			if [[ "${path%/}/" == "${runtime%/}/"* ]] || [[ "${runtime%/}/" == "${path%/}/"* ]]; then
				forbidden=1
			fi
		done
		if [[ "${forbidden}" = 1 ]]; then
			echo "RIOTBOX_EGRESS=1 refuses ${origin} mounting ${src}: a host engine socket there could give the agent a route around the proxy."
			return 0
		fi
	done
}

# _egress_split_args <args> — print engine flags <args>, split on whitespace
# as launch.sh splits them into the run command, as NUL-terminated records
# in the order podman reads them: `w<word>` for each word; for each mount,
# `m<flag>` (-v, --volume or --mount) followed by its value; for each
# -e/--env, `e<value>`; for each --secret, `s<value>`; and for each --pid,
# `p<value>`. A word that is a flag's value is also printed as a
# word, so a check of words still sees it. Grouped short flags are read as
# podman parses them: its boolean ones (-d -i -P -q -t) are skipped; a v or
# an e then takes the rest of the word, less one =, or else the next word.
# Any other letter takes the rest as its own value.
_egress_split_args() {
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

# _egress_env_why <origin> <value> [protected-name...] — print why an engine
# -e/--env <value> from <origin> is refused, or nothing: NAME=VALUE for a
# protected name (a key the proxy injects) would replace the placeholder the
# agent must hold. The value is never printed.
_egress_env_why() {
	local origin="$1" value="$2" name protected
	shift 2
	[[ "${value}" == *=* ]] || return 0
	name="${value%%=*}"
	for protected in "$@"; do
		if [[ "${name}" == "${protected}" ]]; then
			echo "RIOTBOX_EGRESS=1 refuses ${origin} setting ${name}: the proxy injects that key, and the agent must hold only its placeholder."
			return 0
		fi
	done
}

# _egress_args_why <origin> <args> [protected-name...] — print why engine
# flags <args>, from <origin>, are refused, or nothing. The agent's only
# protection from a route around the proxy is that it has no NET_ADMIN and
# no other network; these flags could change either, and a mount or a host
# root (--rootfs, --volumes-from) could hand it a host engine socket. <args>
# is read as _egress_split_args reads it, as the engine will read it. With
# protected names (the keys the proxy injects), an -e/--env setting one
# (_egress_env_why), any --env-file, any --secret of type=env and a --pid
# other than private are refused too.
_egress_args_why() {
	local origin="$1" args="$2" why="" rec i protected=() secret_why pid_why
	local -a recs
	shift 2
	protected=("$@")
	# A type=env secret's target may be omitted (it defaults to the secret's
	# name), so any of them could set an injected key.
	secret_why="RIOTBOX_EGRESS=1 refuses ${origin} containing --secret with type=env while the proxy injects keys: it could set one in the agent."
	# launch.sh keeps the real keys in its environment for the session; in
	# the host's PID namespace (host, or joined through another container
	# or a namespace path) the agent, running as the same uid, could read
	# them from /proc/<pid>/environ.
	pid_why="RIOTBOX_EGRESS=1 refuses ${origin} sharing a PID namespace (--pid other than private) while the proxy injects keys: the agent could read a key from a host process's environment."
	# shellcheck disable=SC2312 # _egress_split_args only prints
	mapfile -d '' -t recs < <(_egress_split_args "${args}")
	for ((i = 0; i < ${#recs[@]}; i++)); do
		rec="${recs[i]}"
		case "${rec}" in
		m*)
			i=$((i + 1))
			why="$(_egress_mount_why "${rec#m}" "${recs[i]}" "${origin}")"
			;;
		e*) why="$(_egress_env_why "${origin}" "${rec#e}" "${protected[@]}")" ;;
		s*)
			if [[ ${#protected[@]} -gt 0 && ",${rec#s}," == *,type=env,* ]]; then
				why="${secret_why}"
			fi
			;;
		p*)
			if [[ ${#protected[@]} -gt 0 && "${rec#p}" != private ]]; then
				why="${pid_why}"
			fi
			;;
		*)
			case "${rec#w}" in
			--privileged | --privileged=* | --cap-add | --cap-add=* | --network | --network=* | --net | --net=* | --pod | --pod=* | --userns | --userns=* | --volumes-from | --volumes-from=* | --rootfs | --rootfs=*)
				why="RIOTBOX_EGRESS=1 refuses ${origin} containing ${rec#w}: it could give the agent a route around the proxy."
				;;
			# podman bind-mounts the --init-path host file into the agent;
			# RiotBox never sets it, so it is refused rather than checked.
			--init-path | --init-path=*)
				why="RIOTBOX_EGRESS=1 refuses ${origin} containing ${rec#w}: it mounts a host file into the agent that is not checked for the egress proxy's state."
				;;
			--env-file | --env-file=*)
				if [[ ${#protected[@]} -gt 0 ]]; then
					why="RIOTBOX_EGRESS=1 refuses ${origin} containing --env-file while the proxy injects keys: the file could set one in the agent."
				fi
				;;
			*) ;;
			esac
			;;
		esac
		[[ -z "${why}" ]] || break
	done
	[[ -z "${why}" ]] || echo "${why}"
}

# egress_gate_mounts — return 1, saying why, when flags launch.sh builds
# itself (not from RIOTBOX_EXTRA_ARGS, which egress_gate checks) would give
# the agent a route around the proxy. Each flag string is checked as
# egress_gate checks RIOTBOX_EXTRA_ARGS (_egress_args_why). Requires MOUNTS,
# PROJECT_VOLUME_FLAGS and CREDFILE_FLAGS.
# shellcheck disable=SC2154 # set by launch.sh, which sources this file
egress_gate_mounts() {
	local spec var why=""
	for spec in "MOUNTS:mounts.conf" "PROJECT_VOLUME_FLAGS:project" "CREDFILE_FLAGS:credential files"; do
		var="${spec%%:*}"
		why="$(_egress_args_why "${spec#*:}" "${!var:-}")"
		[[ -z "${why}" ]] || break
	done
	[[ -n "${why}" ]] || return 0
	echo "ERROR: ${why}" >&2
	echo "       See README \"Egress proxy\"." >&2
	return 1
}

# egress_mask_data — set EGRESS_MASK_FLAGS to an empty tmpfs over every
# container path through which an agent mount reaches RIOTBOX_EGRESS_ROOT;
# return 1, saying why, when a mount is a file in it or, with
# RIOTBOX_NESTED=1, when any mount needs a mask. The agent runs as the
# host user, so a mount of the root, of a directory above it (`riotbox ~`)
# or of a directory holding it through a link would let the agent rewrite
# its own proxy's rds.json, which Envoy reloads live, and read every
# session's access log. Mounts are read as _egress_split_args reads them,
# from PROJECT_VOLUME_FLAGS, MOUNTS, CREDFILE_FLAGS and RIOTBOX_EXTRA_ARGS,
# after egress_gate and egress_gate_mounts have refused what they cannot
# check. A bind mount of host source S at container path D reaches the
# root when the real path of the root is, or is under, the real path of
# S: the mask goes on D plus the rest of the root's real path. A source in
# the root is masked whole, at D. Only the real path counts: a link to
# the root inside a mount resolves in the container, where the target is
# not mounted unless another mount reaches it. notmpcopyup stops podman
# from copying what the tmpfs hides into it, and the tmpfs belongs to the
# container's root, so the agent cannot write there. Destinations are CSV
# quoted, as podman reads --mount, and listed once.
# shellcheck disable=SC2154 # set by launch.sh, which sources this file
egress_mask_data() {
	local root spec origin rec value src dst type field real dest i
	local -a recs fields
	local -A seen=()
	EGRESS_MASK_FLAGS=()
	root="$(realpath -m -- "${RIOTBOX_EGRESS_ROOT}")"
	for spec in "PROJECT_VOLUME_FLAGS:project" "MOUNTS:mounts.conf" "CREDFILE_FLAGS:credential files" "RIOTBOX_EXTRA_ARGS:RIOTBOX_EXTRA_ARGS"; do
		origin="${spec#*:}"
		spec="${spec%%:*}"
		# shellcheck disable=SC2312 # _egress_split_args only prints
		mapfile -d '' -t recs < <(_egress_split_args "${!spec:-}")
		for ((i = 0; i < ${#recs[@]}; i++)); do
			rec="${recs[i]}"
			[[ "${rec}" == m* ]] || continue
			i=$((i + 1))
			value="${recs[i]}"
			src=""
			dst=""
			if [[ "${rec}" == m--mount ]]; then
				type=volume
				IFS=, read -ra fields <<<"${value}"
				for field in "${fields[@]}"; do
					case "${field}" in
					type=*) type="${field#type=}" ;;
					src=* | source=*) src="${field#*=}" ;;
					dst=* | destination=* | target=*) dst="${field#*=}" ;;
					*) ;;
					esac
				done
				[[ "${type}" == bind ]] || continue
			else
				# A -v source is a host path when it starts with / or .;
				# without a destination it is an anonymous volume.
				[[ "${value}" == *:* ]] || continue
				src="${value%%:*}"
				dst="${value#*:}"
				# An overlay's upperdir and workdir are host dirs podman
				# writes to and, for upperdir, shows at the destination:
				# one in or above the root would hand the agent the root,
				# so it is refused rather than masked.
				if [[ "${dst}" == *:* ]]; then
					IFS=, read -ra fields <<<"${dst#*:}"
					for field in "${fields[@]}"; do
						[[ "${field}" == upperdir=* || "${field}" == workdir=* ]] || continue
						real="$(realpath -m -- "${field#*=}")"
						if [[ "${real%/}/" == "${root}/"* || "${root}/" == "${real%/}/"* ]]; then
							echo "ERROR: RIOTBOX_EGRESS=1 refuses ${origin} with ${field}: it reaches the egress proxy's state (${RIOTBOX_EGRESS_ROOT}), which the agent could use to change what it may reach." >&2
							echo "       See README \"Egress proxy\"." >&2
							return 1
						fi
					done
				fi
				dst="${dst%%:*}"
				[[ "${src}" == /* || "${src}" == .* ]] || continue
			fi
			[[ -n "${src}" && -n "${dst}" ]] || continue
			real="$(realpath -m -- "${src}")"
			while [[ "${dst}" == */ && "${dst}" != / ]]; do dst="${dst%/}"; done
			if [[ "${real%/}/" == "${root}/"* ]]; then
				if [[ -e "${real}" && ! -d "${real}" ]]; then
					echo "ERROR: RIOTBOX_EGRESS=1 refuses ${origin} mounting ${src}: it is a file in the egress proxy's state (${RIOTBOX_EGRESS_ROOT}), which the agent could use to change what it may reach." >&2
					echo "       See README \"Egress proxy\"." >&2
					return 1
				fi
				dest="${dst}"
			elif [[ "${root}/" == "${real%/}/"* ]]; then
				dest="${dst%/}${root#"${real%/}"}"
			else
				continue
			fi
			# Nested mode grants CAP_SYS_ADMIN in the agent's user
			# namespace, where the mask is not locked: the agent could
			# unmount it, or bind-mount the root elsewhere.
			if [[ "${RIOTBOX_NESTED:-}" = "1" ]]; then
				echo "ERROR: RIOTBOX_EGRESS=1 with RIOTBOX_NESTED=1 refuses ${origin} mounting ${src}: it holds the egress proxy's state (${RIOTBOX_EGRESS_ROOT}), and nested mode's CAP_SYS_ADMIN lets the agent remove the mask that hides it." >&2
				echo "       Mount a narrower directory, or run without RIOTBOX_NESTED=1 or RIOTBOX_EGRESS=1. See README \"Egress proxy\"." >&2
				return 1
			fi
			[[ -z "${seen["${dest}"]:-}" ]] || continue
			seen["${dest}"]=1
			EGRESS_MASK_FLAGS+=(--mount "type=tmpfs,\"destination=${dest//\"/\"\"}\",notmpcopyup")
		done
	done
}

# egress_gate_env — after egress_start: return 1, saying why, when
# RIOTBOX_EXTRA_ARGS (checked as egress_gate checks it, _egress_args_why)
# would set a key the proxy injects in the agent: an -e/--env NAME=VALUE for
# it, any --env-file, or any --secret with type=env. Each would replace the
# placeholder with a value of the user's choosing, the real key included.
# A --pid other than private is refused too: in a shared PID namespace the
# agent could read the key from launch.sh's environment. Requires
# EGRESS_INJECTED.
egress_gate_env() {
	local why
	[[ ${#EGRESS_INJECTED[@]} -gt 0 ]] || return 0
	why="$(_egress_args_why RIOTBOX_EXTRA_ARGS "${RIOTBOX_EXTRA_ARGS:-}" "${EGRESS_INJECTED[@]}")"
	[[ -n "${why}" ]] || return 0
	echo "ERROR: ${why}" >&2
	echo "       See README \"Egress proxy\"." >&2
	return 1
}

# shellcheck disable=SC2154 # CONTAINER_CMD is set by launch.sh, which sources this file
egress_gate() {
	local why=""
	if [[ "$(basename "${CONTAINER_CMD}")" != "podman" ]]; then
		why="RIOTBOX_EGRESS=1 requires podman: the agent and its proxy run as a podman pod. Docker is not supported."
	elif [[ "${RIOTBOX_SOCKET:-}" = "1" ]]; then
		why="RIOTBOX_EGRESS=1 and RIOTBOX_SOCKET=1 are mutually exclusive: with the host's podman socket the agent can start a container that bypasses the proxy."
	elif [[ "${RIOTBOX_NETWORK:-}" = "none" ]]; then
		why="RIOTBOX_EGRESS=1 and RIOTBOX_NETWORK=none are mutually exclusive: pick no network, or network through the proxy."
	else
		why="$(_egress_args_why RIOTBOX_EXTRA_ARGS "${RIOTBOX_EXTRA_ARGS:-}")"
	fi
	[[ -n "${why}" ]] || return 0
	echo "ERROR: ${why}" >&2
	echo "       See README \"Egress proxy\"." >&2
	return 1
}

# _egress_on_exit — the EXIT trap: remove this launch's egress pod, keeping
# launch.sh's exit status. INT, TERM and HUP are ignored first; INT and HUP
# stay ignored in egress-down, so a second Ctrl-C cannot cut the teardown
# short. Go does not keep an inherited ignored TERM, so a TERM still stops
# egress-down and leaves the pod for the next launch's sweep.
# shellcheck disable=SC2154 # set by launch.sh, which sources this file
_egress_on_exit() {
	local rc=$?
	trap '' INT TERM HUP
	if ! "${RIOTBOX_CORE}" egress-down --engine "${CONTAINER_CMD}" --state-root "${RIOTBOX_EGRESS_ROOT}" -- "${CONTAINER_NAME}"; then
		echo "WARNING: the egress pod of ${CONTAINER_NAME} was not fully removed; the next launch retries." >&2
	fi
	exit "${rc}"
}

# shellcheck disable=SC2154 # set by launch.sh, which sources this file
egress_start() {
	local agent="${RIOTBOX_AGENT:-claude}" hosts out dir projects=() words=() sent=() unsent=() name value i
	# shellcheck disable=SC2310 # it has already said why it failed
	riotbox_core_require || return 1
	# The agent's hosts are what the proxy exists to allow: an unknown agent,
	# a missing verb or a missing registry must stop the launch, not start a
	# proxy that blocks the agent's API. agent_call says why it failed.
	if ! declare -F agent_call >/dev/null; then
		echo "ERROR: egress_start needs agent_call (agents/registry.sh), which is not loaded." >&2
		return 1
	fi
	hosts="$(agent_call "${agent}" egress_hosts)" || return 1
	for dir in "${PROJECT_DIRS[@]}"; do
		projects+=(--project "${dir}")
	done
	# The variables the agent gets from the host by name: each "-e NAME"
	# of the passthrough flags, once. RIOTBOX_HEADROOM is sent separately.
	read -ra words <<<"${PASSTHROUGH_FLAGS:-}"
	for ((i = 1; i < ${#words[@]}; i++)); do
		name="${words[i]}"
		[[ "${words[i - 1]}" == -e && "${name}" != RIOTBOX_HEADROOM && " ${sent[*]} " != *" ${name} "* ]] || continue
		sent+=("${name}")
		[[ "${name}" == XDG_RUNTIME_DIR || "${name}" == HOME ]] || unsent+=(-u "${name}")
	done
	# The sweep runs before the placeholders replace the keys, and needs
	# none of the forwarded variables: its engine calls get none of them,
	# but for XDG_RUNTIME_DIR and HOME, which it and rootless podman need
	# to find the runtime secrets and the engine's storage.
	if ! env "${unsent[@]}" "${RIOTBOX_CORE}" egress-sweep --engine "${CONTAINER_CMD}" --state-root "${RIOTBOX_EGRESS_ROOT}"; then
		echo "WARNING: could not remove every orphaned egress pod; continuing." >&2
	fi
	# Trapped before the pod exists, so an interrupt during startup still
	# removes whatever egress-up created. INT and TERM leave through EXIT.
	trap _egress_on_exit EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	# egress-up reads the hosts, a NUL, then those variables and
	# RIOTBOX_HEADROOM as NUL-terminated NAME=VALUE records, and decides
	# which provider keys its proxy injects. printf is a builtin: no key is
	# ever on a command line.
	out="$({
		printf '%s\n' "${hosts}"
		printf '\0'
		for name in "${sent[@]}"; do
			printf '%s=%s\0' "${name}" "${!name:-}"
		done
		printf 'RIOTBOX_HEADROOM=%s\0' "${RIOTBOX_HEADROOM:-}"
	} | "${RIOTBOX_CORE}" egress-up \
		--engine "${CONTAINER_CMD}" --state-root "${RIOTBOX_EGRESS_ROOT}" \
		--system-conf "${EGRESS_SYSTEM_CONF}" --user-conf "${EGRESS_USER_CONF}" --os-dir "${ROOT_DIR}/os" \
		--image "${RIOTBOX_EGRESS_IMAGE:-${RIOTBOX_EGRESS_DEFAULT_IMAGE}}" \
		--session-key "${SESSION_KEY}" --owner-pid "$$" "${projects[@]}" -- "${CONTAINER_NAME}")" || return 1
	if [[ -z "${out}" ]]; then
		echo "ERROR: riotbox-core egress-up printed no agent flags." >&2
		return 1
	fi
	# shellcheck disable=SC2034 # read by launch.sh's run command
	mapfile -t EGRESS_FLAGS <<<"${out}"
	# For every "-e NAME=VALUE" egress-up returns for a name it was sent
	# (an injected key's placeholder; a proxy or CA variable the user also
	# forwards), export VALUE over NAME. The run command also passes NAME by
	# name (PASSTHROUGH_FLAGS), later, which the engine reads from this
	# shell's environment: so egress's value wins, and an injected key
	# reaches neither the engine nor the agent. Fail closed: a name that is
	# not one, or a failed export, stops the launch.
	for ((i = 1; i < ${#EGRESS_FLAGS[@]}; i++)); do
		[[ "${EGRESS_FLAGS[i - 1]}" == -e && "${EGRESS_FLAGS[i]}" == *=* ]] || continue
		name="${EGRESS_FLAGS[i]%%=*}"
		value="${EGRESS_FLAGS[i]#*=}"
		if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
			echo "ERROR: riotbox-core egress-up returned an -e flag without a valid variable name." >&2
			return 1
		fi
		[[ " ${sent[*]} " == *" ${name} "* ]] || continue
		if ! export "${name}=${value}"; then
			echo "ERROR: could not set ${name} to egress's value; the launch stops." >&2
			return 1
		fi
		[[ "${value}" != "${EGRESS_PLACEHOLDER}" ]] || EGRESS_INJECTED+=("${name}")
	done
	echo "egress: session ${CONTAINER_NAME}; change what it may reach with: riotbox egress allow --session ${CONTAINER_NAME} <entry>" >&2
}
