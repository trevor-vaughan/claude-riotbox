#!/usr/bin/env bash
set -euo pipefail
# Remove one or more RiotBox sessions by session key or project path.
# Required env: ROOT_DIR
# Arguments: <session-key-or-path> [...] | --all
#
# A session is a directory under the data dir that carries the .projects
# marker scripts/mount-projects.sh writes at launch, plus its state dir
# under RIOTBOX_STATE_ROOT; removing a session removes both. Nothing without
# the marker is ever removed: on a rootless install the app tree (bin/,
# libexec/, scripts/, ...) and backups/ share the data dir with the sessions.

source "${ROOT_DIR}/scripts/mount-projects.sh"
source "${ROOT_DIR}/libexec/session-summary.sh"
resolve_data_roots
session_root="${RIOTBOX_DATA_DIR}"
state_root="${RIOTBOX_STATE_ROOT}"

if [[ $# -eq 0 ]]; then
	cat >&2 <<EOF
Error: specify one or more sessions to remove, or --all.

Usage:
  riotbox session-remove <session-key-or-path> [...]
  riotbox session-remove --all

Arguments can be:
  session key   The encoded key shown by 'riotbox session-list'
  project path  A path to a project directory (e.g. . or /home/user/myapp)
  --all         Remove all sessions

Run 'riotbox session-list' to see available sessions.
EOF
	exit 1
fi

# Collect session dirs to remove
to_remove=()

if [[ "$1" = "--all" ]]; then
	for d in "${session_root}"/*/; do
		[[ -f "${d}.projects" ]] || continue
		to_remove+=("${d%/}")
	done
	if [[ ${#to_remove[@]} -eq 0 ]]; then
		echo "No sessions found."
		exit 0
	fi
else
	for arg in "$@"; do
		if [[ -z "${arg}" ]]; then
			echo "ERROR: empty session key or path." >&2
			exit 1
		fi
		# An exact session key is one path component naming a marked session.
		# Keys never contain "/", and "." or ".." would leave the data dir.
		if [[ "${arg}" != */* && "${arg}" != "." && "${arg}" != ".." &&
			-f "${session_root}/${arg}/.projects" ]]; then
			to_remove+=("${session_root}/${arg}")
			continue
		fi
		# Try as a project path — resolve to session key
		if [[ -e "${arg}" ]]; then
			resolve_projects "${arg}"
			if [[ -f "${RIOTBOX_SESSION_DIR}/.projects" ]]; then
				to_remove+=("${RIOTBOX_SESSION_DIR}")
				continue
			fi
			echo "ERROR: no session found for project '${arg}'" >&2
			echo "Run 'riotbox session-list' to see available sessions." >&2
			exit 1
		fi
		if [[ -e "${session_root}/${arg}" ]]; then
			echo "ERROR: '${arg}' is not a session (no .projects marker); refusing to remove it." >&2
		else
			echo "ERROR: '${arg}' is not a session key or an existing path." >&2
		fi
		echo "Run 'riotbox session-list' to see available sessions." >&2
		exit 1
	done
fi

# Defence in depth: resolve_projects already refuses /, but this guards rm -rf.
for d in "${to_remove[@]}"; do
	if [[ "${d%/}" = "${session_root%/}" ]]; then
		echo "ERROR: refusing to remove the RiotBox data dir '${d}'." >&2
		exit 1
	fi
	# The state path is <state root>/<key>; a bad key would aim rm at the root.
	key="$(basename "${d}")"
	if [[ -z "${key}" || "${key}" = "." || "${key}" = ".." ]]; then
		echo "ERROR: refusing to remove state for invalid session key '${key}'." >&2
		exit 1
	fi
done

echo "Sessions to remove:"
for d in "${to_remove[@]}"; do session_summary "${d}" "${state_root}/$(basename "${d}")"; done
echo ""

read -rp "Remove ${#to_remove[@]} session(s)? [y/N] " answer
[[ "${answer}" =~ ^[Yy]$ ]] || {
	echo "Aborted."
	exit 0
}

for d in "${to_remove[@]}"; do rm -rf -- "${d:?}" "${state_root:?}/$(basename "${d}")"; done
echo "Removed ${#to_remove[@]} session(s)."
