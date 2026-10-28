#!/usr/bin/env bash
set -euo pipefail
# riotbox egress — show and change the egress allowlist of running
# RIOTBOX_EGRESS=1 sessions. riotbox-core's egress-* verbs do the work; this
# script parses the command line and supplies the paths.
# Required env: ROOT_DIR, CONTAINER_CMD

usage() {
	cat <<'EOF'
usage: riotbox egress list
       riotbox egress groups
       riotbox egress allow [--session NAME] [--save] <entry | @group>
       riotbox egress deny  [--session NAME] [--save] <entry | @group>
       riotbox egress strict --enable|--disable|--clear [--session NAME] [--save]
       riotbox egress reload [--session NAME]

Change what a running RIOTBOX_EGRESS=1 session may reach, without
restarting it. <entry> is host, host:port or *.domain (port 443 when
omitted); @group is every host of a group (see `riotbox egress groups`).

  list     each running session: when it started, its launch's PID,
           its project dirs, its access log, whether strict mode is on
           and where that comes from, the keys its proxy injects, and
           what it allows
  groups   every group: where it is defined, and its hosts
  allow    allow <entry> or @group in the session, now
  deny     stop allowing <entry> or @group in the session, now;
           connections already open stay open
  strict   --enable   allow only what egress.conf and this session list:
                      not even the package registries (@registries) or
                      the agent's own API hosts (@agent)
                      (a warning prints when the session is left strict
                      without @agent, also after --clear)
           --disable  turn strict mode off for the session
           --clear    drop the session's choice; egress.conf decides
  reload   re-read egress.conf into the session (into every running
           session when --session is omitted)

  --session NAME  the session's container name, printed at launch (see
                  also `riotbox egress list`); may be left out when only
                  one is running
  --save          also record the change in your egress.conf
                  (${XDG_CONFIG_HOME:-~/.config}/riotbox/egress.conf)
                  so later sessions get it: the entry or @group as a
                  line, or strict as `strict = on|off` (--clear removes it)

See README "Egress proxy".
EOF
}

case "${1:-}" in
-h | --help | help)
	usage
	exit 0
	;;
list | groups | allow | deny | strict | reload)
	sub="$1"
	shift
	;;
*)
	usage >&2
	exit 2
	;;
esac

session="" session_given=0 save=0 strict_mode=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--session)
		[[ $# -ge 2 ]] || {
			echo "ERROR: --session needs a session name" >&2
			usage >&2
			exit 2
		}
		session="$2"
		session_given=1
		shift 2
		;;
	--session=*)
		session="${1#--session=}"
		session_given=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--save)
		save=1
		shift
		;;
	--enable | --disable | --clear)
		if [[ -n "${strict_mode}" ]]; then
			echo "ERROR: give only one of --enable, --disable and --clear" >&2
			usage >&2
			exit 2
		fi
		case "$1" in
		--enable) strict_mode=on ;;
		--disable) strict_mode=off ;;
		*) strict_mode=clear ;;
		esac
		shift
		;;
	--)
		shift
		break
		;;
	-*)
		echo "ERROR: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*) break ;;
	esac
done

# riotbox-core treats an empty --session as a usage error; so does this.
if [[ "${session_given}" = 1 && -z "${session}" ]]; then
	echo "ERROR: --session needs a session name" >&2
	exit 2
fi
if [[ "${sub}" = strict && -z "${strict_mode}" ]]; then
	echo "ERROR: strict needs one of --enable, --disable and --clear" >&2
	usage >&2
	exit 2
fi

case "${sub}" in
list | groups) [[ $# -eq 0 && "${session_given}" = 0 && "${save}" = 0 && -z "${strict_mode}" ]] ;;
reload) [[ $# -eq 0 && "${save}" = 0 && -z "${strict_mode}" ]] ;;
strict) [[ $# -eq 0 ]] ;;
*) [[ $# -eq 1 && -z "${strict_mode}" ]] ;;
esac || {
	echo "ERROR: wrong arguments or options for ${sub}" >&2
	usage >&2
	exit 2
}

# shellcheck source=../scripts/mount-projects.sh disable=SC1091,SC2154 # ROOT_DIR is exported by bin/riotbox
source "${ROOT_DIR}/scripts/mount-projects.sh"
# shellcheck source=./egress-lib.sh disable=SC1091
source "${ROOT_DIR}/libexec/egress-lib.sh"
resolve_data_roots
# shellcheck disable=SC2310 # it has already said why it failed
riotbox_core_require || exit 1

common=(--engine "${CONTAINER_CMD}" --state-root "${RIOTBOX_EGRESS_ROOT}")
conf=(--system-conf "${EGRESS_SYSTEM_CONF}" --user-conf "${EGRESS_USER_CONF}")
target=()
[[ "${session_given}" = 0 ]] || target=(--session "${session}")
[[ "${save}" = 0 ]] || target+=(--save-to "${EGRESS_USER_CONF}")
# shellcheck disable=SC2154 # RIOTBOX_CORE comes from scripts/lib/riotbox-core.sh, sourced by mount-projects.sh
case "${sub}" in
list) exec "${RIOTBOX_CORE}" egress-list "${common[@]}" ;;
groups) exec "${RIOTBOX_CORE}" egress-groups "${common[@]}" "${conf[@]}" ;;
reload) exec "${RIOTBOX_CORE}" egress-reload "${common[@]}" "${conf[@]}" "${target[@]}" ;;
strict) exec "${RIOTBOX_CORE}" egress-strict "${common[@]}" "${conf[@]}" "${target[@]}" -- "${strict_mode}" ;;
*) exec "${RIOTBOX_CORE}" "egress-${sub}" "${common[@]}" "${conf[@]}" "${target[@]}" -- "$1" ;;
esac
