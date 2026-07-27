#!/usr/bin/env bash
# overlay-setup.sh — fuse-overlayfs setup/teardown inside the container.
#
# Sourced by entrypoint.sh. Provides:
#   overlay_setup    — mount fuse-overlayfs at /workspace
#   overlay_teardown — print exit summary with change stats

overlay_setup() {
	# Only activate if the lower mount exists (overlay mode)
	[[ -d /mnt/lower ]] || return 0

	# Disable session branches — overlay IS the isolation
	export SESSION_BRANCH=0

	if [[ -d /mnt/overlay/upper ]]; then
		# Single project mode (upper/ exists directly under /mnt/overlay)
		fuse-overlayfs \
			-o lowerdir=/mnt/lower \
			-o upperdir=/mnt/overlay/upper \
			-o workdir=/mnt/overlay/work \
			/workspace
		echo "  [overlay] Project mounted with overlay protection."
		echo "  [overlay] Host project is read-only. All writes go to the overlay."
	else
		# Multi-project mode: overlay each subdirectory
		for lower_dir in /mnt/lower/*/; do
			[[ -d "${lower_dir}" ]] || continue
			local name
			name="$(basename "${lower_dir}")"
			mkdir -p "/workspace/${name}"
			fuse-overlayfs \
				-o "lowerdir=${lower_dir}" \
				-o "upperdir=/mnt/overlay/${name}/upper" \
				-o "workdir=/mnt/overlay/${name}/work" \
				"/workspace/${name}"
			echo "  [overlay] ${name} mounted with overlay protection."
		done
	fi
}

# Count changes in one overlay upper dir against its lower dir.
# Prints "<modified> <added> <deleted>" on one line. Derived caches are not
# counted — see scripts/lib/overlay-ignore.sh, sourced by entrypoint.sh.
overlay_count_changes() {
	local upper="$1" lower="$2"
	local added=0 modified=0 deleted=0
	local rel base
	# shellcheck disable=SC2312  # walker failure means no entries; loop just won't run
	while IFS= read -r rel; do
		base="${rel##*/}"
		if [[ "${base}" == .wh.* ]]; then
			deleted=$((deleted + 1))
		elif [[ -f "${lower}/${rel}" ]]; then
			modified=$((modified + 1))
		else
			added=$((added + 1))
		fi
	done < <(overlay_upper_changes "${upper}")
	printf '%s %s %s\n' "${modified}" "${added}" "${deleted}"
}

overlay_teardown() {
	[[ -d /mnt/lower ]] || return 0

	echo ""
	echo "  [overlay] Session complete. Changes preserved in overlay."

	# Collect stats from upper dir(s)
	local upper_dirs=()
	if [[ -d /mnt/overlay/upper ]]; then
		upper_dirs=(/mnt/overlay/upper)
	else
		for d in /mnt/overlay/*/upper; do
			[[ -d "${d}" ]] && upper_dirs+=("${d}")
		done
	fi

	local added=0 modified=0 deleted=0
	local upper lower name counts
	for upper in "${upper_dirs[@]}"; do
		if [[ "${upper}" = "/mnt/overlay/upper" ]]; then
			lower="/mnt/lower"
		else
			name="$(basename "$(dirname "${upper}")")"
			lower="/mnt/lower/${name}"
		fi
		counts="$(overlay_count_changes "${upper}" "${lower}")"
		modified=$((modified + $(printf '%s' "${counts}" | cut -d' ' -f1)))
		added=$((added + $(printf '%s' "${counts}" | cut -d' ' -f2)))
		deleted=$((deleted + $(printf '%s' "${counts}" | cut -d' ' -f3)))
	done

	if [[ $((added + modified + deleted)) -gt 0 ]]; then
		echo "    ${modified} modified, ${added} added, ${deleted} deleted"
	else
		echo "    No changes detected."
	fi

	echo ""
	echo "  Next steps (run from your host):"
	echo "    riotbox overlay-diff      Review changes"
	echo "    riotbox overlay-accept     Apply to project"
	echo "    riotbox overlay-reject     Discard changes"
}
