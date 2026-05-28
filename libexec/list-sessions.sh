#!/usr/bin/env bash
set -euo pipefail
# List RiotBox session directories with project paths and usage info.

session_root="${XDG_DATA_HOME:-$HOME/.local/share}/riotbox"

_session_list_check="$(ls -A "${session_root}" 2>/dev/null)"
if [[ ! -d "${session_root}" ]] || [[ -z "${_session_list_check}" ]]; then
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

	mapfile -t project_paths <"${session_dir}/.projects"

	# Last used: mtime of the session dir (updated on each launch)
	last_used="$(stat -c '%y' "${session_dir}" 2>/dev/null | cut -d. -f1)"

	# Size on disk
	size="$(du -sh "${session_dir}" 2>/dev/null | cut -f1)"

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
	for p in "${project_paths[@]}"; do
		[[ -d "${p}" ]] || missing+=("${p}")
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
