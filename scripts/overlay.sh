#!/usr/bin/env bash
# scripts/overlay.sh — host-side fuse-overlayfs lifecycle for RiotBox sessions.
#
# Subcommands:
#   resolve  Resolve a project path to its overlay data directory (sourced).
#   list     List sessions with pending overlay data.
#   diff     Show overlay changes vs host project.
#   accept   Apply overlay changes to host project.
#   reject   Discard overlay changes.
#
# `resolve` is special: it is intended to be used via `source` from another
# bash script that needs the resolved variables, not via the dispatcher. It
# is documented here for completeness; subcommand dispatch covers the four
# user-facing verbs (list, diff, accept, reject).
#
# See `scripts/overlay.sh help` for usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/mount-projects.sh
source "${SCRIPT_DIR}/mount-projects.sh"

# ─── overlay resolve ───────────────────────────────────────────────────────
# Resolve a project path to its overlay data directory.
# Sets these variables in the caller's scope (when sourced):
#   OVERLAY_PROJECT_DIR  — the resolved host project path
#   OVERLAY_SESSION_DIR  — the session directory containing overlay data
#   OVERLAY_DIR          — the overlay subdirectory (contains upper/ and work/)
resolve_overlay() {
	local project_path="${1:-$(pwd)}"

	# Resolve to absolute
	if [[ -d "${project_path}" ]]; then
		project_path="$(cd "${project_path}" && pwd)"
	else
		echo "ERROR: '${project_path}' is not a directory." >&2
		return 1
	fi

	# shellcheck disable=SC2034  # used by caller after sourcing
	OVERLAY_PROJECT_DIR="${project_path}"

	# Resolve to session dir
	resolve_projects "${project_path}"
	# shellcheck disable=SC2154 # RIOTBOX_SESSION_DIR is set by resolve_projects (sourced from mount-projects.sh)
	OVERLAY_SESSION_DIR="${RIOTBOX_SESSION_DIR}"

	if [[ ! -d "${OVERLAY_SESSION_DIR}" ]]; then
		echo "ERROR: No session found for '${project_path}'." >&2
		echo "Run 'riotbox session-list' to see available sessions." >&2
		return 1
	fi

	# Find the overlay subdir
	# Single project: overlay/project/upper
	# Multi-project: overlay/<basename>/upper
	local overlay_base="${OVERLAY_SESSION_DIR}/overlay"
	if [[ -d "${overlay_base}/project/upper" ]]; then
		# shellcheck disable=SC2034  # used by caller after sourcing
		OVERLAY_DIR="${overlay_base}/project"
	else
		local name
		name="$(basename "${project_path}")"
		if [[ -d "${overlay_base}/${name}/upper" ]]; then
			# shellcheck disable=SC2034  # used by caller after sourcing
			OVERLAY_DIR="${overlay_base}/${name}"
		else
			echo "ERROR: No overlay data found for '${project_path}'." >&2
			echo "Run 'riotbox overlays' to see pending overlays." >&2
			return 1
		fi
	fi
}

# Check if an overlay dir has any actual changes (non-empty upper).
overlay_has_changes() {
	local overlay_dir="$1"
	# shellcheck disable=SC2312 # ls failure just means empty/missing dir; -n check handles it
	[[ -d "${overlay_dir}/upper" ]] && [[ -n "$(ls -A "${overlay_dir}/upper" 2>/dev/null)" ]]
}

# ─── overlay list ──────────────────────────────────────────────────────────
# List sessions with pending overlay data.
# Exit 0 if overlays exist, 1 if none.
overlay_list() {
	local session_root="${XDG_DATA_HOME:-${HOME}/.local/share}/riotbox"

	if [[ ! -d "${session_root}" ]]; then
		echo "No pending overlays."
		return 1
	fi

	local found=0
	local session_dir name overlay_base overlay_dir
	local -a project_paths
	local last_modified local_added local_deleted size base path

	for session_dir in "${session_root}"/*/; do
		[[ -d "${session_dir}" ]] || continue
		name="$(basename "${session_dir}")"
		[[ "${name}" = "backups" ]] && continue

		overlay_base="${session_dir}/overlay"
		[[ -d "${overlay_base}" ]] || continue

		# Check each overlay subdir for non-empty upper
		for overlay_dir in "${overlay_base}"/*/; do
			[[ -d "${overlay_dir}/upper" ]] || continue
			# shellcheck disable=SC2312 # ls failure means empty dir; -n check handles it
			[[ -n "$(ls -A "${overlay_dir}/upper" 2>/dev/null)" ]] || continue

			# This overlay has changes
			if [[ "${found}" -eq 0 ]]; then
				echo "Pending overlays:"
				echo ""
			fi
			found=$((found + 1))

			# Read project paths from session metadata
			if [[ -f "${session_dir}/.projects" ]]; then
				mapfile -t project_paths <"${session_dir}/.projects"
			else
				project_paths=("(unknown)")
			fi

			# Timestamp from overlay dir mtime
			last_modified="$(stat -c '%y' "${overlay_dir}/upper" 2>/dev/null | cut -d. -f1)"

			# Count changes in upper dir
			local_added=0 local_deleted=0
			# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
			while IFS= read -r path; do
				base="$(basename "${path}")"
				if [[ "${base}" == .wh.* ]]; then
					local_deleted=$((local_deleted + 1))
				else
					local_added=$((local_added + 1))
				fi
			done < <(find "${overlay_dir}/upper" -mindepth 1 -not -type d 2>/dev/null)

			size="$(du -sh "${overlay_dir}" 2>/dev/null | cut -f1)"

			echo "  Project  ${project_paths[0]}"
			echo "  Changed  ${last_modified}"
			echo "  Files    ${local_added} added/modified, ${local_deleted} deleted  (${size} on disk)"
			echo "  Key      ${name}"
			echo ""
		done
	done

	if [[ "${found}" -eq 0 ]]; then
		echo "No pending overlays."
		return 1
	fi
	return 0
}

# ─── overlay diff ──────────────────────────────────────────────────────────
# Show changes in overlay upper dir.
# Usage: overlay_diff [project-path]
overlay_diff() {
	# shellcheck disable=SC2310 # resolve_overlay is designed to be tested with ||
	resolve_overlay "${1:-}" || return $?

	local upper="${OVERLAY_DIR}/upper"
	local project="${OVERLAY_PROJECT_DIR}"

	echo "Overlay diff for: ${project}"
	echo ""

	local found=0
	local path rel base dir real_name
	# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
	while IFS= read -r path; do
		rel="${path#"${upper}"/}"
		base="$(basename "${path}")"
		dir="$(dirname "${rel}")"

		if [[ "${base}" == ".wh..wh..opq" ]]; then
			found=$((found + 1))
			echo "D  ${dir}/  (directory replaced)"
		elif [[ "${base}" == .wh.* ]]; then
			found=$((found + 1))
			real_name="${base#.wh.}"
			echo "D  ${dir}/${real_name}"
		elif [[ -f "${path}" ]]; then
			found=$((found + 1))
			if [[ -f "${project}/${rel}" ]]; then
				echo "M  ${rel}"
				# Show diff if both are text files
				if file "${path}" | grep -q text && file "${project}/${rel}" | grep -q text; then
					diff -u "${project}/${rel}" "${path}" \
						--label "a/${rel}" --label "b/${rel}" 2>/dev/null || true
				else
					echo "   (binary file)"
				fi
			else
				echo "A  ${rel}"
				if file "${path}" | grep -q text; then
					# Show the new file content as a unified diff against /dev/null
					diff -u /dev/null "${path}" --label /dev/null --label "b/${rel}" 2>/dev/null || true
				else
					echo "   (binary file)"
				fi
			fi
		fi
	done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null | sort)

	if [[ "${found}" -eq 0 ]]; then
		echo "No changes."
	fi
}

# ─── overlay accept ────────────────────────────────────────────────────────
# Apply overlay changes to host project.
# Usage: overlay_accept [--force] [project-path]
overlay_accept() {
	local FORCE=false
	local PROJECT_ARG=""
	local arg
	for arg in "$@"; do
		case "${arg}" in
		--force | -f) FORCE=true ;;
		*) PROJECT_ARG="${arg}" ;;
		esac
	done

	# shellcheck disable=SC2310 # resolve_overlay is designed to be tested with ||
	resolve_overlay "${PROJECT_ARG}" || return $?

	local upper="${OVERLAY_DIR}/upper"
	local work="${OVERLAY_DIR}/work"
	local project="${OVERLAY_PROJECT_DIR}"

	# shellcheck disable=SC2310 # overlay_has_changes is designed to be tested in if-conditions
	if ! overlay_has_changes "${OVERLAY_DIR}"; then
		echo "No overlay changes to apply for ${project}."
		return 0
	fi

	echo "Overlay changes to apply to: ${project}"
	echo ""

	# Dry-run: list what will happen
	local added=0 modified=0 deleted=0
	local path rel base dir real_name confirm
	# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
	while IFS= read -r path; do
		rel="${path#"${upper}"/}"
		base="$(basename "${path}")"
		dir="$(dirname "${rel}")"

		if [[ "${base}" == ".wh..wh..opq" ]]; then
			echo "  REPLACE  ${dir}/"
			deleted=$((deleted + 1))
		elif [[ "${base}" == .wh.* ]]; then
			real_name="${base#.wh.}"
			echo "  DELETE   ${dir}/${real_name}"
			deleted=$((deleted + 1))
		elif [[ -f "${path}" ]]; then
			if [[ -f "${project}/${rel}" ]]; then
				echo "  MODIFY   ${rel}"
				modified=$((modified + 1))
			else
				echo "  ADD      ${rel}"
				added=$((added + 1))
			fi
		fi
	done < <(find "${upper}" -mindepth 1 -not -type d 2>/dev/null | sort)

	echo ""
	echo "Summary: ${added} added, ${modified} modified, ${deleted} deleted"
	echo ""

	if [[ "${FORCE}" != true ]]; then
		read -rp "Apply these changes? [y/N] " confirm
		if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
			echo "Aborted."
			return 0
		fi
	fi

	# Apply changes
	# Process opaque whiteouts first (directory-level), then file whiteouts, then copies.
	# This ordering prevents copying into a directory that's about to be replaced.

	# Pass 1: opaque dirs
	# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
	while IFS= read -r path; do
		rel="${path#"${upper}"/}"
		dir="$(dirname "${rel}")"
		base="$(basename "${path}")"
		if [[ "${base}" == ".wh..wh..opq" ]]; then
			rm -rf "${project:?}/${dir:?}"
			mkdir -p "${project}/${dir}"
		fi
	done < <(find "${upper}" -name ".wh..wh..opq" 2>/dev/null)

	# Pass 2: file whiteouts
	# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
	while IFS= read -r path; do
		rel="${path#"${upper}"/}"
		dir="$(dirname "${rel}")"
		base="$(basename "${path}")"
		if [[ "${base}" == .wh.* ]] && [[ "${base}" != ".wh..wh..opq" ]]; then
			real_name="${base#.wh.}"
			rm -rf "${project:?}/${dir:?}/${real_name:?}"
		fi
	done < <(find "${upper}" -name ".wh.*" 2>/dev/null)

	# Pass 3: copy new/modified files and directories
	# shellcheck disable=SC2312 # find failure means no files; loop just won't execute
	while IFS= read -r path; do
		rel="${path#"${upper}"/}"
		base="$(basename "${path}")"
		[[ "${base}" == .wh.* ]] && continue
		if [[ -d "${path}" ]]; then
			mkdir -p "${project}/${rel}"
		else
			dir="$(dirname "${rel}")"
			mkdir -p "${project}/${dir}"
			# `cp -a` preserves context+xattr via fsetxattr, which (a) the kernel
			# denies under SELinux when the project bind mount has a different
			# label class, and (b) would smear container_t-derived labels onto
			# host files. Drop both; mode/timestamps/links are still preserved.
			cp -a --no-preserve=context,xattr "${path}" "${project}/${rel}"
		fi
	done < <(find "${upper}" -mindepth 1 2>/dev/null | sort)

	# Clean up overlay data
	rm -rf "${upper}" "${work}"
	mkdir -p "${upper}" "${work}"

	echo "Applied. Overlay data cleaned."
}

# ─── overlay reject ────────────────────────────────────────────────────────
# Discard overlay changes.
# Usage: overlay_reject [--force] [project-path]
overlay_reject() {
	local FORCE=false
	local PROJECT_ARG=""
	local arg
	for arg in "$@"; do
		case "${arg}" in
		--force | -f) FORCE=true ;;
		*) PROJECT_ARG="${arg}" ;;
		esac
	done

	# shellcheck disable=SC2310 # resolve_overlay is designed to be tested with ||
	resolve_overlay "${PROJECT_ARG}" || return $?

	# shellcheck disable=SC2310 # overlay_has_changes is designed to be tested in if-conditions
	if ! overlay_has_changes "${OVERLAY_DIR}"; then
		echo "No overlay changes to discard for ${OVERLAY_PROJECT_DIR}."
		return 0
	fi

	echo "Discarding overlay changes for: ${OVERLAY_PROJECT_DIR}"

	local confirm
	if [[ "${FORCE}" != true ]]; then
		read -rp "Discard all changes? This cannot be undone. [y/N] " confirm
		if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
			echo "Aborted."
			return 0
		fi
	fi

	rm -rf "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"
	mkdir -p "${OVERLAY_DIR}/upper" "${OVERLAY_DIR}/work"
	echo "Overlay data discarded."
}

# ─── dispatch ──────────────────────────────────────────────────────────────
_overlay_usage() {
	cat <<'EOF'
Usage: overlay.sh <subcommand> [args...]

Subcommands:
  list                       List sessions with pending overlay data.
  diff [project]             Show overlay changes vs host project.
  accept [--force] [project] Apply overlay changes to host project.
  reject [--force] [project] Discard overlay changes.
  help                       Show this message.
EOF
}

overlay_main() {
	local cmd="${1:-}"
	if [[ -z "${cmd}" ]]; then
		_overlay_usage >&2
		return 2
	fi
	shift
	case "${cmd}" in
	list) overlay_list "$@" ;;
	diff) overlay_diff "$@" ;;
	accept) overlay_accept "$@" ;;
	reject) overlay_reject "$@" ;;
	-h | --help | help) _overlay_usage ;;
	*)
		echo "overlay: unknown subcommand '${cmd}'" >&2
		_overlay_usage >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
	overlay_main "$@"
fi
