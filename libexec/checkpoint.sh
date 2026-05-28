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
