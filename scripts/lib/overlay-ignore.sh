#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/overlay-ignore.sh — derived-cache filter for overlay bookkeeping.
#
# Sourced by the host overlay tooling (scripts/overlay.sh, libexec/launch.sh)
# and, inside the container, by container/entrypoint.sh so overlay-setup.sh's
# teardown stats use the same rules. One definition, four call sites.
#
# Bookkeeping (the pending-overlay launch guard, `riotbox overlays` counts and
# `riotbox overlay-diff`) answers "what did this session change that I need to
# review?". A rebuildable index is not an answer to that question, so it is
# filtered here. Application (`overlay-accept`, `overlay-reject`) is NOT
# filtered: when there is anything else to apply, accept copies the index
# through to the project so it survives the upper-directory wipe, and reject
# discards everything by definition. An upper holding ONLY an index reads as
# "no changes", so both verbs stop at their early-exit gate and the index
# simply stays in the overlay for the next session — nothing is wiped, so
# there is nothing for it to survive.
#
# Public:
#   overlay_path_ignored <relative-path>
#     Exit 0 when the FIRST component of the path is a derived-cache directory
#     (or its overlayfs whiteout form). Matching is by name alone and ignores
#     file type, so a regular file literally named `.codegraph` is filtered
#     too.
#
#     The match is anchored deliberately. CodeGraph indexes
#     <project-root>/.codegraph, and every overlay upper directory is rooted at
#     exactly one project root (container/overlay-setup.sh gives each project
#     in multi-project mode its own upper), so anchoring loses no index this
#     session actually wrote. Matching at any depth instead let a nested
#     `.codegraph` disappear from `riotbox overlay-diff`, the launch guard and
#     the exit summary while `overlay-accept` — unfiltered by design — still
#     copied it to the host: a write channel to the host that review never
#     showed. A deliberately-indexed subdirectory now shows up as a change,
#     which is the safe direction to be wrong in.
#
#   overlay_upper_changes <upper-dir>
#     Print one upper-relative path per non-ignored, non-directory entry.
#     Directories are excluded because overlayfs materializes a parent for
#     every write, so a bare directory carries no signal — the same basis
#     overlay_diff and the overlay_list counter already use.
#
#   overlay_upper_has_changes <upper-dir>
#     Exit 0 when overlay_upper_changes would print at least one line.
# ─────────────────────────────────────────────────────────────────────────────

# Directory names that hold derived caches rather than project content.
#   .codegraph — CodeGraph's per-project index. Rebuilt by `codegraph init`,
#                self-gitignored by CodeGraph itself. See README "CodeGraph
#                code intelligence".
OVERLAY_IGNORED_NAMES=(".codegraph")

overlay_path_ignored() {
	local rel="${1:-}"
	# Only the first component: everything below the project root belongs in
	# review. See the header for why this is anchored rather than recursive.
	local first="${rel%%/*}"
	local name
	for name in "${OVERLAY_IGNORED_NAMES[@]}"; do
		if [[ "${first}" = "${name}" ]] || [[ "${first}" = ".wh.${name}" ]]; then
			return 0
		fi
	done
	return 1
}

overlay_upper_changes() {
	local upper="${1:?overlay_upper_changes requires an upper directory}"
	[[ -d "${upper}" ]] || return 0
	# Strip a trailing slash so the prefix removal below yields upper-relative
	# paths; consumers join what we print onto a project directory.
	upper="${upper%/}"
	local path rel
	while IFS= read -r path; do
		rel="${path#"${upper}"/}"
		if overlay_path_ignored "${rel}"; then
			continue
		fi
		printf '%s\n' "${rel}"
	done < <(
		# find's own diagnostics (an unreadable subdirectory, say) stay on
		# stderr, and a non-zero status becomes an explicit warning: a partial
		# listing must never read as "nothing to review". Entries that were
		# reachable are still printed — a loud partial answer beats a silent
		# one. A signal death (>= 128) is a reader that stopped early, as
		# overlay_upper_has_changes does, not a traversal failure.
		find_status=0
		# shellcheck disable=SC2312  # find's status is not masked: the || below captures it
		find "${upper}" -mindepth 1 -not -type d || find_status=$?
		if ((find_status != 0 && find_status < 128)); then
			printf 'overlay_upper_changes: find exited %d under %s; listing may be incomplete\n' \
				"${find_status}" "${upper}" >&2
		fi
	)
}

overlay_upper_has_changes() {
	local upper="${1:?overlay_upper_has_changes requires an upper directory}"
	# The first line ends the walk: a large index-free upper needs no full
	# traversal. Process substitution rather than a pipeline into `head`, so
	# the walker's SIGPIPE death on early exit cannot surface as a non-zero
	# pipeline status and abort an errexit/pipefail caller.
	# shellcheck disable=SC2312  # the walker's status is dropped on purpose: this loop may stop it early
	while IFS= read -r _; do
		return 0
	done < <(overlay_upper_changes "${upper}")
	return 1
}
