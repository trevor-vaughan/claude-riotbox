#!/usr/bin/env bash
set -euo pipefail
# `riotbox hub`: one page, on one host address, listing the running
# `riotbox anywhere` sessions, and one port per session that proxies it, so
# the sessions can stay on loopback. riotbox-core's hub verb serves it
# (internal/hub); this file reads the config, checks the address and finds
# the directories.
# Required env: CONTAINER_CMD, ROOT_DIR (exported by bin/riotbox).
#
# The hub has its own login, a token in the printed link kept as a cookie,
# because the page shows project paths and its session ports carry traffic.
# It signs the browser in to the session it opens, so the token is the one
# key to those sessions. The token and a
# self-signed certificate persist under $XDG_DATA_HOME/riotbox-hub, so the
# phone accepts the certificate once.

usage() {
	cat <<'EOF'
Usage: riotbox hub [SUBCOMMAND]

Serve one page that lists every running `riotbox anywhere` session, and one
port per session (the number the session publishes on loopback) that proxies
it. Prints the page's link once; open it on your phone and keep the bookmark.
Ctrl-C stops it. Sessions are unaffected.

To front sessions on loopback, bind the hub to the host's LAN address and
allow its port and the sessions' ports (3399-3419 by default) in the firewall.

Subcommands (without one, the hub runs in this terminal):
  install      Run the hub as a systemd user service: start it now and at login
  uninstall    Stop and remove that service (the token and certificate stay)
  status       Print the link, then the service's status
  logs [ARGS]  Show the service's journal (ARGS go to journalctl, e.g. -f)
  link         Print the link (open it on a browser to sign in)
  new-token    Replace the token and print the new link; every browser must
               open the new link again

Environment knobs:
  RIOTBOX_HUB_BIND=<ip:port>   Host address to serve on
                               (default 127.0.0.1:3399 — this host only)
EOF
}
subcommand="${1:-}"
case "${subcommand}" in
-h | --help)
	usage
	exit 0
	;;
"" | link | new-token | install | uninstall | status | logs) ;;
*)
	usage >&2
	exit 2
	;;
esac

# Only `logs` takes arguments (they go to journalctl). For every other
# subcommand -h/--help anywhere among them prints usage and does nothing;
# anything else is a mistake that must not rotate a token or remove a service.
if [[ "${subcommand}" != logs ]]; then
	for arg in "${@:2}"; do
		if [[ "${arg}" == -h || "${arg}" == --help ]]; then
			usage
			exit 0
		fi
	done
	if [[ $# -gt 1 ]]; then
		usage >&2
		exit 2
	fi
fi

unit_name="riotbox-hub.service"
data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"

# These two need neither the config nor the address.
case "${subcommand}" in
logs)
	shift
	exec journalctl --user -u "${unit_name}" "$@"
	;;
uninstall)
	if ! out="$(systemctl --user disable --now "${unit_name}" 2>&1)"; then
		# Not being installed is the state uninstall is after; anything else is a real failure.
		if ! grep -Eq 'does not exist|not loaded' <<<"${out}"; then
			printf 'ERROR: could not stop %s: %s\n' "${unit_name}" "${out}" >&2
			exit 1
		fi
	fi
	rm -f "${unit_dir}/${unit_name}"
	systemctl --user daemon-reload
	echo "Removed ${unit_name}. The token and certificate stay in ${data_home}/riotbox-hub;"
	echo "delete that directory to forget them."
	exit 0
	;;
*) ;;
esac

# The unit records these as they stand in the caller's environment, before the
# config files below can set them as shell variables (see the install branch).
unit_env_names=(PATH XDG_DATA_HOME XDG_CONFIG_HOME RIOTBOX_SYSCONF_DIR RIOTBOX_CONTEXT_LEDGER RIOTBOX_HUB_BIND)
declare -A caller_env
for name in "${unit_env_names[@]}"; do
	if [[ -n "${!name:-}" ]]; then caller_env[${name}]="${!name}"; fi
done

RIOTBOX_CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/riotbox/config"
RIOTBOX_CONFIG_SYSTEM="${RIOTBOX_SYSCONF_DIR:-/etc/riotbox}/config"
# shellcheck disable=SC1090
[[ -f "${RIOTBOX_CONFIG_USER}" ]] && source "${RIOTBOX_CONFIG_USER}"
# shellcheck disable=SC1090,SC1091
[[ -f "${RIOTBOX_CONFIG_SYSTEM}" ]] && source "${RIOTBOX_CONFIG_SYSTEM}"

# shellcheck source=./anywhere-lib.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/anywhere-lib.sh"
bind="${RIOTBOX_HUB_BIND:-127.0.0.1:3399}"
# The parser names RIOTBOX_ANYWHERE_BIND in its messages; say which one failed.
if ! anywhere_parse_bind "${bind}" 2>/dev/null; then
	printf 'ERROR: RIOTBOX_HUB_BIND=%q is not ADDRESS:PORT.\n' "${bind}" >&2
	echo "  ADDRESS is an IP literal, not a host name: 192.168.1.20:3399, or [fd00::20]:3399 for IPv6." >&2
	exit 1
fi
# shellcheck disable=SC2154 # both set by anywhere_parse_bind (anywhere-lib.sh)
hub_addr="${ANYWHERE_ADDR}" hub_port="${ANYWHERE_PORT}"
if [[ -z "${subcommand}" || "${subcommand}" == install ]]; then
	case "${hub_addr}" in
	0.0.0.0 | "[::]")
		echo "WARNING: RIOTBOX_HUB_BIND=${bind} listens on every network this host joins." >&2
		echo "         In the link below, replace ${hub_addr} with this host's LAN address." >&2
		;;
	127.* | "[::1]")
		echo "NOTE: the hub is bound to ${hub_addr}, which only this host can reach." >&2
		echo "      For your phone, set the host's LAN address in ~/.config/riotbox/config:" >&2
		echo "        : \"\${RIOTBOX_HUB_BIND:=192.168.1.20:${hub_port}}\"" >&2
		;;
	*) ;;
	esac
fi

# shellcheck source=../scripts/mount-projects.sh disable=SC1091,SC2154 # ROOT_DIR is exported by bin/riotbox
source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_data_roots
# shellcheck disable=SC2310 # it has already said why it failed
riotbox_core_require || exit 1

hub_args=(--data-dir "${data_home}/riotbox-hub" --listen "${hub_addr}:${hub_port}")
# shellcheck disable=SC2154 # RIOTBOX_CORE comes from scripts/lib/riotbox-core.sh, sourced by mount-projects.sh
case "${subcommand}" in
"")
	exec "${RIOTBOX_CORE}" hub --engine "${CONTAINER_CMD}" --state-root "${RIOTBOX_STATE_ROOT}" "${hub_args[@]}"
	;;
link)
	exec "${RIOTBOX_CORE}" hub-link "${hub_args[@]}"
	;;
new-token)
	"${RIOTBOX_CORE}" hub-new-token "${hub_args[@]}"
	echo "A running hub uses it from its next request; every browser must open this link again."
	;;
status)
	"${RIOTBOX_CORE}" hub-link "${hub_args[@]}"
	exec systemctl --user --no-pager status "${unit_name}"
	;;
install)
	# The unit starts from systemd's environment, not this shell's, so it records
	# every variable hub.sh, resolve_data_roots and the config files are located
	# by, as the caller's environment held it (caller_env). Values the config
	# files set are left out: the service sources the same files at each start,
	# so editing the config takes effect without reinstalling. PATH is always set;
	# the rest only when set and non-empty in the caller's environment.
	# systemd reads these characters in a unit file as syntax, not as part of a value.
	env_lines=""
	for name in "${unit_env_names[@]}"; do
		[[ -v "caller_env[${name}]" ]] || continue
		if [[ "${caller_env[${name}]}" == *[$'\n"\\%']* ]]; then
			printf 'ERROR: %s contains a newline, ", \\ or %%, which a systemd unit would misread.\n' "${name}" >&2
			exit 1
		fi
		# systemd does not expand $ in Environment= values (systemd.exec(5)).
		env_lines+="Environment=\"${name}=${caller_env[${name}]}\""$'\n'
	done
	if [[ "${ROOT_DIR}" == *[$'\n"\\%$']* ]]; then
		printf 'ERROR: ROOT_DIR contains a newline, ", \\, %% or $, which a systemd unit would misread.\n' >&2
		exit 1
	fi
	if ! systemctl --user show-environment >/dev/null 2>&1; then
		echo "ERROR: 'systemctl --user' does not work here; the hub service needs a user systemd instance." >&2
		echo "       Log in through a session that has one, or run 'riotbox hub' in a terminal instead." >&2
		exit 1
	fi
	# The link creates the token when there is none; do it before the service
	# starts, so the hub starts with the token this link carries.
	"${RIOTBOX_CORE}" hub-link "${hub_args[@]}"
	mkdir -p "${unit_dir}"
	unit_tmp="$(mktemp "${unit_dir}/.${unit_name}.XXXXXX")"
	trap 'rm -f "${unit_tmp}"' EXIT
	cat >"${unit_tmp}" <<UNIT
# Written by \`riotbox hub install\`; \`riotbox hub uninstall\` removes it.
[Unit]
Description=RiotBox hub: the riotbox anywhere sessions through one place

[Service]
Type=simple
${env_lines}ExecStart="${ROOT_DIR}/bin/riotbox" hub
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
	chmod 0644 "${unit_tmp}"
	mv "${unit_tmp}" "${unit_dir}/${unit_name}"
	systemctl --user daemon-reload
	systemctl --user enable "${unit_name}"
	systemctl --user restart "${unit_name}"
	user="${USER:-$(id -un)}"
	# No answer (no logind) is as good as "no": say how to keep the hub running.
	linger="$(loginctl show-user "${user}" -p Linger --value 2>/dev/null)" || linger=no
	if [[ "${linger}" != yes ]]; then
		echo "NOTE: the hub stops when you log out. To keep it running, run once:" >&2
		echo "        loginctl enable-linger ${user}" >&2
	fi
	;;
*) ;;
esac
