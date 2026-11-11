#!/usr/bin/env bash
set -euo pipefail
# `riotbox hub`: one page, on one host address, listing the running
# `riotbox anywhere` sessions with a link to each. riotbox-core's hub verb
# serves it (internal/hub); this file reads the config, checks the address
# and finds the directories.
# Required env: CONTAINER_CMD, ROOT_DIR (exported by bin/riotbox).
#
# The page itself grants nothing: every link leads to a session's own Yep
# Anywhere, which asks for that session's password. It still shows project
# paths, so it has its own login: a token in the printed link, kept as a
# cookie. The token and a self-signed certificate persist under
# $XDG_DATA_HOME/riotbox-hub, so the phone accepts the certificate once.

usage() {
	cat <<'EOF'
Usage: riotbox hub

Serve one page that lists every running `riotbox anywhere` session, with a
link to each. Prints the page's link once; open it on your phone and keep the
bookmark. Ctrl-C stops it. Sessions are unaffected.

Environment knobs:
  RIOTBOX_HUB_BIND=<ip:port>   Host address to serve on
                               (default 127.0.0.1:3399 — this host only)
EOF
}
case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
"") ;;
*)
	usage >&2
	exit 2
	;;
esac

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

# shellcheck source=../scripts/mount-projects.sh disable=SC1091,SC2154 # ROOT_DIR is exported by bin/riotbox
source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_data_roots
# shellcheck disable=SC2310 # it has already said why it failed
riotbox_core_require || exit 1

data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
# shellcheck disable=SC2154 # RIOTBOX_CORE comes from scripts/lib/riotbox-core.sh, sourced by mount-projects.sh
exec "${RIOTBOX_CORE}" hub --engine "${CONTAINER_CMD}" --state-root "${RIOTBOX_STATE_ROOT}" \
	--data-dir "${data_home}/riotbox-hub" --listen "${hub_addr}:${hub_port}"
