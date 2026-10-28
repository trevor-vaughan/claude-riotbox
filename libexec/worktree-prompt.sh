#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# worktree-prompt.sh — Warn when a project is a linked git worktree.
#
# Sourced (not executed) by launch.sh BEFORE any project resolution. Provides:
#   worktree_prompt — for each project (RIOTBOX_PROJECTS, else the current
#                     directory) that sits inside a linked `git worktree`,
#                     explain the problem and, on a TTY, ask
#                     "Continue in the current directory? [y/N]".
#                     Anything but y/yes exits 1 so the launch stops.
#                     Without a TTY it prints the notice and continues: a
#                     script cannot answer, and nothing here is unsafe, only
#                     broken-looking.
#
# Why: a linked worktree's `.git` is a FILE holding the absolute host path of
# the main repository's `.git/worktrees/<name>`. Only the worktree is mounted,
# so inside the container that path does not exist and every git command (and
# every checkpoint) fails. Starting from the main checkout works.
#
# A submodule is not a linked worktree: its git dir and common dir are the
# same, which is what the check below keys on.
# ─────────────────────────────────────────────────────────────────────────────

# _worktree_main_root <dir>
#   Print the main checkout's top-level directory when <dir> is inside a linked
#   worktree; print nothing and return 1 otherwise (plain repo, submodule,
#   bare repo, or not a repo at all).
_worktree_main_root() {
	local out git_dir common_dir
	out="$(git -C "$1" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)" || return 1
	{
		IFS= read -r git_dir
		IFS= read -r common_dir
	} <<<"${out}"
	[[ -n "${git_dir}" && -n "${common_dir}" && "${git_dir}" != "${common_dir}" ]] || return 1
	# The common dir is <main>/.git for a normal repo. A bare main repo has no
	# checkout to point at, so name the common dir itself.
	if [[ "$(basename "${common_dir}")" = ".git" ]]; then
		dirname "${common_dir}"
	else
		printf '%s\n' "${common_dir}"
	fi
}

worktree_prompt() {
	local raw="${RIOTBOX_PROJECTS:-}"
	[[ -n "${raw}" ]] || raw="$(pwd)"

	local -a found=()
	local p main
	# Same splitting as resolve_projects: space-separated, no globbing.
	local _old_glob
	_old_glob="$(shopt -po noglob 2>/dev/null || true)"
	set -f
	for p in ${raw}; do
		main="$(_worktree_main_root "${p}")" || continue
		found+=("${p} (worktree of ${main})")
	done
	eval "${_old_glob}"
	[[ ${#found[@]} -gt 0 ]] || return 0

	{
		echo ""
		echo "riotbox: starting inside a git worktree:"
		printf '  %s\n' "${found[@]}"
		echo "A worktree's .git file points at the main repository, which is not"
		echo "mounted into the container, so git will not work there. Run riotbox"
		echo "from the main checkout instead."
	} >&2

	if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
		echo "Notice: stdin/stdout is not a TTY — continuing in the current directory." >&2
		return 0
	fi

	printf "Continue in the current directory? [y/N] " >&2
	local answer
	read -r answer || answer=""
	case "${answer}" in
	[Yy] | [Yy][Ee][Ss]) ;;
	*)
		echo "Aborted." >&2
		return 1
		;;
	esac
}
