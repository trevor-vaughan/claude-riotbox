#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# anywhere-lib.sh — launch side of `riotbox anywhere` (Yep Anywhere).
#
# Sourced by libexec/launch.sh when RIOTBOX_ANYWHERE=1, which only the
# `riotbox anywhere` verb sets. Provides:
#   anywhere_gate  — refuse, before any side effect, the settings this mode
#                    cannot honour, validate RIOTBOX_ANYWHERE_BIND, and set
#                    ANYWHERE_FLAGS (an array) for the engine run command.
#   anywhere_password — read or create the password of a project set's Yep
#                    Anywhere and export it for the engine run command.
#
# Yep Anywhere runs INSIDE the agent container (container/anywhere.sh): it
# starts `claude` and `opencode` itself, so it has to live where they do. The
# host publishes one port, on the one address RIOTBOX_ANYWHERE_BIND names, to
# the server's fixed in-container port. Nothing else about the container
# changes: no capability, no network, no mount beyond the state subdirectory
# scripts/mount-projects.sh adds for the server's own data.
#
# Why the default is loopback: a phone can only reach a LAN address, but which
# of the host's addresses is the right one (Wi-Fi, ethernet, a VPN, a
# container bridge) is not something to guess. Binding every interface would
# expose an agent to whatever network the laptop joins next, so the user names
# the address once in ~/.config/riotbox/config and the launch refuses a name
# it would have to resolve.
#
# Why RIOTBOX_EGRESS=1 is refused: the agent's only network is then an
# --internal one, and a published port on it does not reach the host. Serving
# it needs a sidecar on a second network, which is planned but not built. Until
# then, failing loudly beats starting a server nobody can reach.
#
# Why the host keeps the password: `riotbox hub` signs a browser in to the
# session it opens by reading <state dir>/anywhere-password (internal/hub), so
# the password is generated here, not in the container. The file sits beside
# the state subdirectories and not in one of them, because only those are
# mounted: no container mounts the file. The container gets the value in its
# environment, where its own agent can read it (harmless: that agent already
# controls its own Yep Anywhere); container/anywhere.sh applies it.
# ─────────────────────────────────────────────────────────────────────────────

# The port container/anywhere.sh binds inside the container. Fixed: the host
# side is what the user chooses, and only the host side is ever visible.
ANYWHERE_CONTAINER_PORT=3400
ANYWHERE_DEFAULT_BIND="127.0.0.1:${ANYWHERE_CONTAINER_PORT}"

# anywhere_parse_bind <bind> — split an `address:port` into ANYWHERE_ADDR and
# ANYWHERE_PORT. The address must be an IPv4 literal or a bracketed IPv6
# literal; the port 1-65535. The wildcard and loopback come out as 0.0.0.0,
# 127.x.y.z, [::] or [::1] however they were spelt. Returns 1, after saying
# why, otherwise.
anywhere_parse_bind() {
	local bind="$1" addr port
	if [[ "${bind}" =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
		addr="${BASH_REMATCH[1]}"
		port="${BASH_REMATCH[2]}"
		[[ "${addr}" == *:* ]] || {
			printf 'ERROR: RIOTBOX_ANYWHERE_BIND=%q: [%s] is not an IPv6 address.\n' "${bind}" "${addr}" >&2
			return 1
		}
		# An IPv4-mapped or -compatible address (::ffff:0.0.0.0, ::ffff:0:0,
		# ::127.0.0.1) is an IPv4 address in disguise, and its wildcard and
		# loopback spellings are endless; refuse it rather than classify it.
		local lower="${addr,,}"
		if [[ "${lower}" == *.* ]] || [[ "${lower}" =~ ^[0:]*:ffff: ]]; then
			printf 'ERROR: RIOTBOX_ANYWHERE_BIND=%q: [%s] embeds an IPv4 address; use a plain IPv4 or IPv6 address.\n' "${bind}" "${addr}" >&2
			return 1
		fi
		# Eight groups of 1-4 hex digits, or fewer around exactly one "::".
		# Checked before canonicalising, so a typo such as [:] or [0:1] is
		# refused instead of becoming the wildcard or loopback.
		local groups='^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*$' given="${addr}" left right count=0 side colons
		if [[ "${addr}" == *::* ]]; then
			left="${addr%%::*}" right="${addr#*::}"
			for side in "${left}" "${right}"; do
				[[ -z "${side}" ]] && continue
				[[ "${side}" =~ ${groups} ]] || count=99
				colons="${side//[^:]/}"
				((count += ${#colons} + 1))
			done
			((count <= 7)) || addr=""
		else
			colons="${addr//[^:]/}"
			[[ "${addr}" =~ ${groups} ]] && ((${#colons} == 7)) || addr=""
		fi
		if [[ -z "${addr}" ]]; then
			printf 'ERROR: RIOTBOX_ANYWHERE_BIND=%q: [%s] is not an IPv6 address.\n' "${bind}" "${given}" >&2
			return 1
		fi
		# Every other spelling of the wildcard or loopback address, in the one
		# form the callers match on.
		if [[ "${addr}" =~ ^[0:]+$ ]]; then
			addr="::"
		elif [[ "${addr}" =~ ^[0:]*:0*1$ ]]; then
			addr="::1"
		fi
		ANYWHERE_ADDR="[${addr}]"
	elif [[ "${bind}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]+)$ ]]; then
		local i octet octets=()
		port="${BASH_REMATCH[5]}"
		for i in 1 2 3 4; do
			octet="${BASH_REMATCH[i]}"
			# 10# so a leading zero is not read as octal; >255 is not an address.
			if ((10#${octet} > 255)); then
				printf 'ERROR: RIOTBOX_ANYWHERE_BIND=%q: %s is not an IPv4 address.\n' "${bind}" "${bind%:*}" >&2
				return 1
			fi
			octets+=("$((10#${octet}))")
		done
		# Rebuilt without leading zeros, so 000.0.0.0 is matched as the wildcard.
		ANYWHERE_ADDR="${octets[0]}.${octets[1]}.${octets[2]}.${octets[3]}"
	else
		printf 'ERROR: RIOTBOX_ANYWHERE_BIND=%q is not ADDRESS:PORT.\n' "${bind}" >&2
		echo "  ADDRESS is an IP literal, not a host name: 192.168.1.20:3400, or [fd00::20]:3400 for IPv6." >&2
		return 1
	fi
	if [[ ! "${port}" =~ ^[0-9]{1,5}$ ]] || ((10#${port} < 1 || 10#${port} > 65535)); then
		printf 'ERROR: RIOTBOX_ANYWHERE_BIND=%q: port %s is not between 1 and 65535.\n' "${bind}" "${port}" >&2
		return 1
	fi
	ANYWHERE_PORT="$((10#${port}))"
}

# anywhere_port_in_use <addr> <port> — 0 when something already accepts
# connections there. A wildcard address is probed on loopback. The connect
# is bounded so an unroutable address cannot hang the launch. The tests
# replace this function.
anywhere_port_in_use() {
	local addr="$1" port="$2"
	case "${addr}" in
	0.0.0.0) addr=127.0.0.1 ;;
	"[::]") addr=::1 ;;
	*) addr="${addr#[}" addr="${addr%]}" ;;
	esac
	# shellcheck disable=SC2016 # expanded by the inner bash, from its arguments
	timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${addr}" "${port}" 2>/dev/null
}

# How many ports above the configured one a launch tries before giving up.
ANYWHERE_PORT_TRIES=20

# anywhere_pick_port — move ANYWHERE_PORT up to the first free port, so
# several `riotbox anywhere` sessions can share one RIOTBOX_ANYWHERE_BIND.
# Another launch can still take the port between this check and the engine's
# bind; the engine then fails with "address already in use".
anywhere_pick_port() {
	local first="${ANYWHERE_PORT}" port
	for ((port = first; port < first + ANYWHERE_PORT_TRIES && port <= 65535; port++)); do
		# shellcheck disable=SC2310 # its status is the answer
		if ! anywhere_port_in_use "${ANYWHERE_ADDR}" "${port}"; then
			if ((port != first)); then
				echo "NOTE: ${ANYWHERE_ADDR}:${first} is in use; Yep Anywhere takes ${ANYWHERE_ADDR}:${port}." >&2
			fi
			ANYWHERE_PORT="${port}"
			return 0
		fi
	done
	printf 'ERROR: no free port on %s from %s to %s for Yep Anywhere.\n' "${ANYWHERE_ADDR}" "${first}" "$((port - 1))" >&2
	echo "  Stop a session, or set another start port in RIOTBOX_ANYWHERE_BIND." >&2
	return 1
}

# anywhere_password <state dir> — keep the Yep Anywhere password of the project
# set whose state directory this is in <state dir>/anywhere-password (mode
# 0600, written through a temp file in the same directory and renamed). A new
# one, 24 alphanumerics, is made when the file is missing or empty, or
# RIOTBOX_ANYWHERE_RESET_PASSWORD=1. Exports RIOTBOX_ANYWHERE_PASSWORD and
# RIOTBOX_ANYWHERE_PASSWORD_NEW (1 when just made, else 0); the launch passes
# both to the engine by name only, so the value never reaches its argv. A file
# that holds anything but 6 or more alphanumerics (--setup-auth would read a
# leading "-" as the next flag) is refused, untouched, with how to recover;
# nothing is exported. Returns 1, after saying why, on any failure.
anywhere_password() {
	local dir="$1" file="$1/anywhere-password" password="" tmp
	if [[ -L "${file}" ]] || { [[ -e "${file}" ]] && [[ ! -f "${file}" ]]; }; then
		printf 'ERROR: %s is not a regular file.\n' "${file}" >&2
		echo "  Remove it and launch again." >&2
		return 1
	fi
	if [[ "${RIOTBOX_ANYWHERE_RESET_PASSWORD:-0}" != "1" ]] && [[ -f "${file}" ]]; then
		# read fails on an empty file, and on a last line without a newline
		# (which it still returns).
		IFS= read -r password <"${file}" || [[ -n "${password}" ]] || password=""
	fi
	if [[ -n "${password}" ]]; then
		if [[ ! "${password}" =~ ^[A-Za-z0-9]{6,}$ ]]; then
			printf 'ERROR: %s does not hold a Yep Anywhere password (6 or more letters and digits).\n' "${file}" >&2
			echo "  Delete it, or launch once with RIOTBOX_ANYWHERE_RESET_PASSWORD=1, to get a new one." >&2
			return 1
		fi
		RIOTBOX_ANYWHERE_PASSWORD_NEW=0
	else
		# 24 alphanumerics, ~143 bits; easy to type on a phone. No "-": the
		# --setup-auth parser reads a value starting with "-" as the next flag.
		# A finite read, not `tr < /dev/urandom | head`: under pipefail the
		# SIGPIPE that tr gets when head exits would end the script.
		while ((${#password} < 24)); do
			# shellcheck disable=SC2312 # a failed read adds nothing, and the loop reads again
			password+="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
		done
		password="${password:0:24}"
		if ! tmp="$(umask 077 && mktemp "${dir}/.anywhere-password.XXXXXX")"; then
			printf 'ERROR: cannot create a file in %s for the Yep Anywhere password.\n' "${dir}" >&2
			return 1
		fi
		if ! { printf '%s\n' "${password}" >"${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${file}"; }; then
			rm -f "${tmp}"
			printf 'ERROR: cannot write %s.\n' "${file}" >&2
			return 1
		fi
		RIOTBOX_ANYWHERE_PASSWORD_NEW=1
	fi
	export RIOTBOX_ANYWHERE_PASSWORD="${password}" RIOTBOX_ANYWHERE_PASSWORD_NEW
}

# anywhere_gate — see the header. Sets ANYWHERE_FLAGS and ANYWHERE_URL.
anywhere_gate() {
	if [[ "${RIOTBOX_EGRESS:-}" = "1" ]]; then
		cat >&2 <<'EOF'
ERROR: riotbox anywhere does not work with RIOTBOX_EGRESS=1 yet.

  Under the egress proxy the agent's only network is internal, and a port
  published from it never reaches the host. Serving Yep Anywhere there needs
  a sidecar, which is not built yet. Run without RIOTBOX_EGRESS=1, or use
  `riotbox run` / `riotbox shell` for this session.
EOF
		return 1
	fi
	if [[ "${RIOTBOX_NETWORK:-}" = "none" ]]; then
		cat >&2 <<'EOF'
ERROR: riotbox anywhere needs a network, and RIOTBOX_NETWORK=none removes it.

  The phone reaches Yep Anywhere through a published port, which a container
  with no network does not have.
EOF
		return 1
	fi

	local bind="${RIOTBOX_ANYWHERE_BIND:-${ANYWHERE_DEFAULT_BIND}}"
	# shellcheck disable=SC2310 # it has already said why it failed
	anywhere_parse_bind "${bind}" || return 1
	# shellcheck disable=SC2310 # it has already said why it failed
	anywhere_pick_port || return 1

	case "${ANYWHERE_ADDR}" in
	0.0.0.0 | "[::]")
		echo "WARNING: RIOTBOX_ANYWHERE_BIND=${bind} listens on EVERY network this host joins." >&2
		echo "         Anyone who can reach it and guesses the password drives the agent." >&2
		echo "         Prefer the one LAN address your phone uses." >&2
		;;
	127.* | "[::1]")
		echo "NOTE: Yep Anywhere is bound to ${ANYWHERE_ADDR}, which only this host can reach." >&2
		echo "      For your phone, run \`riotbox hub\` with RIOTBOX_HUB_BIND set to this host's LAN address: it serves each session on its own port." >&2
		echo "      Or publish this session itself on the host's LAN address in ~/.config/riotbox/config:" >&2
		echo "        : \"\${RIOTBOX_ANYWHERE_BIND:=192.168.1.20:${ANYWHERE_PORT}}\"" >&2
		;;
	*) ;; # a specific LAN address: what the user is told to set
	esac

	ANYWHERE_URL="https://${ANYWHERE_ADDR}:${ANYWHERE_PORT}"
	ANYWHERE_FLAGS=(
		-p "${ANYWHERE_ADDR}:${ANYWHERE_PORT}:${ANYWHERE_CONTAINER_PORT}"
		-e "RIOTBOX_ANYWHERE=1"
		-e "RIOTBOX_ANYWHERE_URL=${ANYWHERE_URL}"
		# What `riotbox hub` lists (internal/hub). It reads only this label
		# and riotbox.session; nothing else about the container.
		--label "riotbox.anywhere.url=${ANYWHERE_URL}"
	)
	# Yep Anywhere refuses /api requests whose Host header is not localhost, a
	# private IPv4 address or *.ts.net (DNS-rebinding protection), so a
	# Tailscale 100.x, IPv6 or public bind would load the page and then fail
	# every call. Allow the address the user chose; a wildcard has no single
	# address, and its private-range clients are allowed anyway.
	case "${ANYWHERE_ADDR}" in
	0.0.0.0 | "[::]") ;;
	*)
		local host="${ANYWHERE_ADDR#[}"
		ANYWHERE_FLAGS+=(-e "RIOTBOX_ANYWHERE_HOST=${host%]}")
		;;
	esac
}
