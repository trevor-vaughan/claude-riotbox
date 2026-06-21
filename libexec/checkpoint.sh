#!/usr/bin/env bash
set -euo pipefail
# ─────────────────────────────────────────────────────────────────────────────
# checkpoint.sh — Create pre-session backup of all project git repos.
#
# Creates a checkpoint commit, tags it, and pushes to a local bare backup repo
# under $XDG_DATA_HOME/riotbox/backups/. The backup is outside the
# container mount tree so Claude cannot access or modify it.
#
# A directory that is not yet a git repo can be initialized on the spot (see
# RIOTBOX_GIT_INIT below); an empty repo with no commits is skipped gracefully.
#
# Required env: ROOT_DIR
# Optional env: RIOTBOX_PROJECTS (space-separated project paths; defaults to CWD)
#               RIOTBOX_GIT_INIT (1=init non-git dirs, 0=never, unset=prompt on
#                                 an interactive terminal, default Yes)
# ─────────────────────────────────────────────────────────────────────────────

source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_projects "${RIOTBOX_PROJECTS:-}"

# Managed exclude block — exact content; markers are the stable identity.
_MANAGED_BLOCK='# >>> riotbox managed excludes (do not edit between markers) >>>
.headroom/
.claude/settings.local.json
CLAUDE.local.md
venom.log
venom.*.log
# <<< riotbox managed excludes <<<'

# Ensure the project repo's .git/info/exclude contains the current managed
# block. Called for every git project before the checkpoint commit.
#
# Behaviour:
#   - Resolves the exclude path via `git -C <dir> rev-parse --git-path
#     info/exclude` to handle worktrees and submodule gitdirs correctly.
#   - Creates the parent directory if it doesn't exist yet.
#   - If the markers are already present, replaces everything between them
#     (including the markers themselves) so that list updates propagate.
#   - If no markers exist, appends the block (with a separating newline).
#   - Never modifies content outside the markers.
#   - Non-git directory → silent no-op.
#   - Any other failure → one-line warning to stderr; does NOT abort.
ensure_managed_excludes() {
	local dir="$1"

	# Resolve exclude path. rev-parse may return a relative path; canonicalise.
	local raw_path
	raw_path="$(git -C "${dir}" rev-parse --git-path info/exclude 2>/dev/null)" || return 0

	local exclude_path
	if [[ "${raw_path}" = /* ]]; then
		exclude_path="${raw_path}"
	else
		exclude_path="${dir}/${raw_path}"
	fi

	# Create parent directory if needed (bare repos / worktrees may not have it).
	local exclude_dir
	exclude_dir="$(dirname "${exclude_path}")"
	mkdir -p "${exclude_dir}" 2>/dev/null || {
		echo "  WARNING: cannot create ${exclude_dir} — skipping managed excludes" >&2
		return 0
	}

	# Touch the file if it doesn't exist so all paths below can treat it uniformly.
	[[ -f "${exclude_path}" ]] || touch "${exclude_path}" 2>/dev/null || {
		echo "  WARNING: cannot write ${exclude_path} — skipping managed excludes" >&2
		return 0
	}

	# Derive markers from _MANAGED_BLOCK so there is only one source of truth.
	local open_marker close_marker
	open_marker="$(printf '%s\n' "${_MANAGED_BLOCK}" | head -1)"
	close_marker="$(printf '%s\n' "${_MANAGED_BLOCK}" | tail -1)"

	# Classify the marker structure in one pass. The replace path is only safe
	# when there is exactly one open marker with a close marker somewhere after
	# it — any other shape (duplicate opens, an open that never closes, a close
	# preceding an unclosed open) would make the rewrite below eat user content
	# to EOF. Stray close markers OUTSIDE a block are user content and are
	# preserved. Exact-line matching ($0 ==) is consistent with the rewrite awk.
	local marker_state
	marker_state="$(awk \
		-v open_marker="${open_marker}" \
		-v close_marker="${close_marker}" \
		'
		BEGIN { opens=0; inside=0; closed=0 }
		$0 == open_marker  { opens++; inside=1; next }
		inside && $0 == close_marker { inside=0; closed=1 }
		END {
			if (opens == 0)                print "absent"
			else if (opens == 1 && closed) print "valid"
			else                           print "corrupt"
		}
		' "${exclude_path}" 2>/dev/null)" || marker_state="corrupt"

	if [[ "${marker_state}" == "valid" ]]; then
		# Both markers present — replace the entire block (open marker through close
		# marker) so that list updates propagate. Awk uses exact-line matching
		# ($0 == marker) which is consistent with the grep -xF probes above.
		local new_content
		new_content="$(awk \
			-v block="${_MANAGED_BLOCK}" \
			-v open_marker="${open_marker}" \
			-v close_marker="${close_marker}" \
			'
			BEGIN { inside=0; printed_block=0 }
			$0 == open_marker {
				if (!printed_block) { print block; printed_block=1 }
				inside=1
				next
			}
			inside && $0 == close_marker { inside=0; next }
			inside { next }
			{ print }
			' "${exclude_path}")" || {
			echo "  WARNING: awk failed updating ${exclude_path} — skipping managed excludes" >&2
			return 0
		}
		printf '%s\n' "${new_content}" > "${exclude_path}" 2>/dev/null || {
			echo "  WARNING: cannot write ${exclude_path} — skipping managed excludes" >&2
		}
	elif [[ "${marker_state}" == "corrupt" ]]; then
		# Duplicate or unclosed markers — corrupt/hand-edited state. Refuse to
		# rewrite (would eat user content to EOF) and warn loudly.
		echo "  WARNING: ${exclude_path} has a malformed managed block (duplicate or unclosed markers) — skipping managed excludes" >&2
	else
		# No markers yet — append with a separating newline if the file is
		# non-empty (so we don't create a blank leading line). Read the size
		# before opening the file for writing to satisfy shellcheck SC2094.
		local needs_separator=false
		[[ -s "${exclude_path}" ]] && needs_separator=true
		{
			"${needs_separator}" && printf '\n'
			printf '%s\n' "${_MANAGED_BLOCK}"
		} >> "${exclude_path}" 2>/dev/null || {
			echo "  WARNING: cannot append to ${exclude_path} — skipping managed excludes" >&2
		}
	fi
}

# Decide whether to create a git repo in a directory that has none, so the
# project still gets checkpoint protection. Behaviour is driven by
# RIOTBOX_GIT_INIT to keep automation predictable:
#   1     → always create
#   0     → never create
#   unset → ask on an interactive terminal (default Yes). Non-interactive
#           callers (riotbox run, CI, tests) fall through to "no" so a repo is
#           never created in the user's directory without consent and the
#           launcher never blocks on a prompt that nobody can answer.
# Returns 0 if a repo was created, 1 otherwise.
maybe_init_git_repo() {
	local dir="$1"
	local create=false
	case "${RIOTBOX_GIT_INIT:-}" in
	1) create=true ;;
	0) create=false ;;
	*)
		if [[ -t 0 ]]; then
			local answer
			printf "  %s is not a git repository.\n" "${dir}" >&2
			printf "  Create one so your work can be checkpointed? [Y/n] " >&2
			read -r answer || answer=""
			[[ "${answer}" =~ ^[Nn] ]] || create=true
		fi
		;;
	esac

	if [[ "${create}" = true ]] && git -C "${dir}" init >/dev/null 2>&1; then
		echo "  [git-init] Created git repository in ${dir}"
		return 0
	fi
	return 1
}

timestamp="$(date +%Y%m%d-%H%M%S)"
for dir in "${PROJECT_DIRS[@]}"; do
	project_name="$(basename "${dir}")"

	if ! git -C "${dir}" rev-parse --git-dir &>/dev/null; then
		# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
		if ! maybe_init_git_repo "${dir}"; then
			echo "  WARNING: ${dir} is not a git repo — no checkpoint protection!" >&2
			continue
		fi
	fi

	# Ensure .git/info/exclude has the managed block so runtime artifacts
	# (headroom DBs, venom logs, Claude Code local files) are never swept
	# into the checkpoint commit. This runs before `git add -A` so the
	# gitignore semantics take effect for this and all future checkpoints.
	ensure_managed_excludes "${dir}"

	# Commit any uncommitted work so it's safely captured before Claude runs.
	# Includes untracked files — the goal is a complete snapshot.
	#
	# commit.gpgsign=false / tag.gpgsign=false: checkpoints are local-only
	# safety snapshots that never reach a shared remote, and the container has
	# no signing key. Inheriting a host commit.gpgsign=true would abort the
	# commit. Signing happens later, on the host, via reown-commits.sh.
	_untracked="$(git -C "${dir}" ls-files --others --exclude-standard)"
	if ! git -C "${dir}" diff --quiet || ! git -C "${dir}" diff --cached --quiet ||
		[[ -n "${_untracked}" ]]; then
		# Warn if `git add -A` is about to sweep in a large untracked set
		# (e.g. a .test-output/ tree that should have been gitignored).
		# Without this, multi-hundred-MB checkpoint commits get pushed to
		# the bare backup on every run and the backup volume balloons
		# silently. Threshold tuned to "noticeable but not nagging":
		# anything over 100 files OR 50 MB triggers the warning.
		# RIOTBOX_CHECKPOINT_QUIET=1 silences (CI, scripted runs).
		if [[ -n "${_untracked}" ]] && [[ -z "${RIOTBOX_CHECKPOINT_QUIET:-}" ]]; then
			_untracked_count="$(printf '%s\n' "${_untracked}" | wc -l)"
			# Sum bytes of the untracked set. Use ls-files -z + du
			# --files0-from to handle paths with spaces/newlines safely.
			# shellcheck disable=SC2312 # awk on pipe stdout; failure → 0
			_untracked_bytes="$(
				cd "${dir}" 2>/dev/null &&
					git ls-files -z --others --exclude-standard |
					du -bc --files0-from=- 2>/dev/null |
					awk 'END {print $1+0}'
			)"
			_untracked_mb=$(((_untracked_bytes + 1048575) / 1048576))
			if [[ "${_untracked_count}" -gt 100 ]] || [[ "${_untracked_mb}" -gt 50 ]]; then
				echo "  WARNING: checkpoint will bundle ${_untracked_count} untracked file(s), ~${_untracked_mb} MB, into ${project_name}." >&2
				echo "           Add patterns to .gitignore if these shouldn't be in the checkpoint commit." >&2
				echo "           Suppress with RIOTBOX_CHECKPOINT_QUIET=1." >&2
			fi
			unset _untracked_count _untracked_bytes _untracked_mb
		fi
		git -C "${dir}" add -A
		git -C "${dir}" -c commit.gpgsign=false commit -m "checkpoint: pre-riotbox-${timestamp}"
	fi

	# A repo with no commits yet (unborn HEAD) has nothing to tag or back up.
	# This is reached for a freshly-initialised or empty repo with no
	# committable files; skip it gracefully instead of letting `git tag` abort
	# on the missing HEAD (which would take the whole launch down).
	if ! git -C "${dir}" rev-parse --verify HEAD &>/dev/null; then
		echo "  ${project_name}: empty git repo (no commits yet) — nothing to checkpoint."
		continue
	fi

	# Tag the current HEAD
	tag_name="riotbox-checkpoint/${timestamp}"
	git -C "${dir}" -c tag.gpgsign=false tag "${tag_name}"

	# Push everything to a local bare backup repo
	backup_dir="${RIOTBOX_DATA_DIR}/backups/${project_name}.git"
	if [[ ! -d "${backup_dir}" ]]; then
		git clone --bare "${dir}" "${backup_dir}" 2>/dev/null
	else
		# --no-verify: skip the pre-push hook (which blocks container-identity commits)
		# The backup is a local bare repo, not a shared remote, so the hook
		# intent (prevent publishing unowned commits) does not apply here.
		git -C "${dir}" push --no-verify --force "${backup_dir}" --all 2>/dev/null
		git -C "${dir}" push --no-verify --force "${backup_dir}" --tags 2>/dev/null
	fi
	echo "  checkpoint: ${project_name} → ${tag_name} (backed up)"
done
