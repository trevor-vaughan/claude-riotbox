#!/usr/bin/env bash
set -euo pipefail
# List RiotBox session directories with project paths and usage info.
# Required env: ROOT_DIR

source "${ROOT_DIR}/scripts/mount-projects.sh"
source "${ROOT_DIR}/libexec/session-summary.sh"
resolve_data_roots
session_root="${RIOTBOX_DATA_DIR}"

if [[ ! -d "${session_root}" ]]; then
	echo "No sessions found."
	exit 0
fi
_session_list_check="$(ls -A "${session_root}")"
if [[ -z "${_session_list_check}" ]]; then
	echo "No sessions found."
	exit 0
fi

found=0
for session_dir in "${session_root}"/*/; do
	[[ -d "${session_dir}" ]] || continue
	name="$(basename "${session_dir}")"

	# Skip dirs that don't belong to a session:
	#   - backups/ is the safety backup tree, not a session.
	#   - The XDG data dir also holds the app tree on rootless installs
	#     (bin/, libexec/, scripts/, agents/, container/). Filter sessions
	#     by the .projects marker that mount-projects.sh writes at launch.
	#     Without this, `riotbox session-list` listed app subdirs as
	#     sessions and `riotbox session-remove libexec` would delete part
	#     of the installation.
	[[ "${name}" = "backups" ]] && continue
	[[ -f "${session_dir}/.projects" ]] || continue

	found=$((found + 1))

	# .projects is container-written: read it only when it is not a link,
	# and print only its cleaned copy. Existence is checked on the recorded
	# paths.
	raw_paths=()
	# shellcheck disable=SC2310 # a refused .projects shows as unknown
	if raw="$(session_projects "${session_dir%/}")"; then
		mapfile -t raw_paths <<<"${raw}"
		cleaned="$(printf '%s\n' "${raw_paths[@]}" | terminal_clean line)"
		mapfile -t project_paths <<<"${cleaned}"
	else
		project_paths=("(unknown)")
	fi

	# Last used: mtime of the session dir (updated on each launch)
	last_used="$(stat -c '%y' "${session_dir}" 2>/dev/null | cut -d. -f1)"

	# Size on disk, the session's state dir included
	size="$(session_size "${session_dir%/}" "${RIOTBOX_STATE_ROOT}/${name}")"

	# Contents inventory
	contents=()
	if [[ -d "${session_dir}/skills" ]]; then
		skill_count="$(find "${session_dir}/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
		contents+=("${skill_count} skills")
	fi
	[[ -f "${session_dir}/.claude.json" ]] && contents+=("config")
	[[ -f "${session_dir}/statusline-command.sh" ]] && contents+=("statusline")
	contents_str="$(
		IFS=', '
		echo "${contents[*]:-empty}"
	)"

	# Whether the projects still exist on disk
	missing=()
	for i in "${!raw_paths[@]}"; do
		[[ -d "${raw_paths[i]}" ]] || missing+=("${project_paths[i]}")
	done

	# Print
	if [[ ${#project_paths[@]} -eq 1 ]]; then
		echo "${project_paths[0]}"
	else
		echo "${#project_paths[@]} projects:"
		for p in "${project_paths[@]}"; do
			echo "  ${p}"
		done
	fi
	echo "  Last used:  ${last_used}"
	echo "  Size:       ${size}    Contents: ${contents_str}"
	echo "  Key:        ${name}"
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "  WARNING: project no longer exists: ${missing[*]}"
	fi
	echo ""
done

[[ "${found}" -gt 0 ]] || echo "No sessions found."
