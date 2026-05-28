#!/usr/bin/env bash
set -euo pipefail
# Install the RiotBox git pre-push hook (blocks pushes containing commits
# authored by any riotbox container identity).
#
# Required env: ROOT_DIR
# Arguments: [global] [--force]
#   global   install to the user-global core.hooksPath instead of the
#            current repo's .git/hooks/.
#   --force  overwrite an existing hook that wasn't installed by RiotBox.

scope=""
force=0
for arg in "$@"; do
	case "${arg}" in
	global) scope="global" ;;
	--force | -f) force=1 ;;
	-h | --help)
		cat <<'EOF'
Usage: riotbox install-hooks [global] [--force]

Install the RiotBox pre-push hook that blocks pushes containing
container-identity commits (llm@riotbox, etc.) the user hasn't reowned.

  global    Install at the user-global core.hooksPath. Applies to every
            repo that doesn't have its own hooksPath override.
  --force   Overwrite a pre-existing pre-push that was not installed by
            RiotBox (the hook content is replaced). Use only if you do
            not need the existing hook's behavior.

Detection:
  - lefthook / pre-commit / husky managers are detected by their config
    files. RiotBox does not auto-merge with these; the script prints
    inline contents you can paste, plus a manager-specific snippet.

See README "Reclaiming authorship" for context.
EOF
		exit 0
		;;
	esac
done

# shellcheck disable=SC2154  # ROOT_DIR is exported by the caller (bin/riotbox)
hook_src="${ROOT_DIR}/hooks/pre-push"

if [[ "${scope}" = "global" ]]; then
	# Use existing core.hooksPath or default to ~/.config/git/hooks
	hooks_dir="$(git config --global core.hooksPath 2>/dev/null || true)"
	if [[ -z "${hooks_dir}" ]]; then
		hooks_dir="${HOME}/.config/git/hooks"
		git config --global core.hooksPath "${hooks_dir}"
		echo "Set core.hooksPath to ${hooks_dir}"
	fi
	# Expand ~ if present
	hooks_dir="${hooks_dir/#\~/$HOME}"
	mkdir -p "${hooks_dir}"
	hook_dst="${hooks_dir}/pre-push"
	global=true
	repo_root="${HOME}"
else
	git_dir="$(git rev-parse --git-dir 2>/dev/null)" || {
		echo "ERROR: not a git repository" >&2
		exit 1
	}
	hook_dst="${git_dir}/hooks/pre-push"
	global=false
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ── Detect known hook managers ──────────────────────────────────────────
# Auto-merging into a managed hook tree (lefthook.yml, .husky/, etc.) is
# tricky and tool-specific — getting it wrong can silently break the
# user's existing hooks. Instead, print an inline snippet the user can
# add to their existing manager config, and explain the riotbox path.
detected_manager=""
manager_hint=""
if [[ -f "${repo_root}/lefthook.yml" ]] || [[ -f "${repo_root}/lefthook.yaml" ]] || [[ -f "${repo_root}/.lefthook.yml" ]]; then
	detected_manager="lefthook"
	manager_hint=$(
		cat <<EOF
Add this stanza to your lefthook.yml under \`pre-push\`:

  pre-push:
    commands:
      riotbox-identity-guard:
        run: ${hook_src} {push_ref}

Or symlink/copy the hook directly and disable lefthook for pre-push.
EOF
	)
fi
if [[ -d "${repo_root}/.husky" ]]; then
	detected_manager="husky"
	manager_hint=$(
		cat <<EOF
Append this line to your .husky/pre-push:

  ${hook_src} "\$@"

(Husky runs the hook directly — the line above just chains to ours.)
EOF
	)
fi
if [[ -f "${repo_root}/.pre-commit-config.yaml" ]] && [[ -z "${detected_manager}" ]]; then
	# pre-commit does not manage pre-push by default but might
	detected_manager="pre-commit"
	manager_hint=$(
		cat <<EOF
pre-commit doesn't manage pre-push hooks by default. Either:
  - Install ours directly (re-run with --force if appropriate), or
  - Add 'default_install_hook_types: [pre-commit, pre-push]' to your
    .pre-commit-config.yaml and define a local pre-push hook that calls
    ${hook_src}.
EOF
	)
fi

if [[ -f "${hook_dst}" ]]; then
	if grep -q 'RIOTBOX-HOOK' "${hook_dst}"; then
		echo "Updating existing RiotBox pre-push hook."
	elif [[ "${force}" = "1" ]]; then
		echo "Overwriting existing pre-push hook at ${hook_dst} (--force)."
	else
		echo "ERROR: ${hook_dst} already exists and was not installed by RiotBox." >&2
		echo "" >&2
		if [[ -n "${detected_manager}" ]]; then
			echo "Detected hook manager: ${detected_manager}" >&2
			echo "" >&2
			printf '%s\n\n' "${manager_hint}" >&2
		fi
		echo "Options:" >&2
		echo "  - Re-run with --force to replace the existing hook (destructive)." >&2
		echo "  - Or paste the RiotBox hook contents into your existing one:" >&2
		echo "      cat ${hook_src} >> ${hook_dst}" >&2
		echo "  - Or invoke it from inside your manager (see snippet above when present)." >&2
		exit 1
	fi
fi

cp "${hook_src}" "${hook_dst}"
chmod +x "${hook_dst}"
echo "Installed pre-push hook to ${hook_dst}"
if [[ "${global}" = true ]]; then
	echo "Note: core.hooksPath overrides per-repo .git/hooks/ directories."
fi
if [[ -n "${detected_manager}" ]]; then
	echo ""
	echo "Notice: detected ${detected_manager} in ${repo_root}. Your manager's"
	echo "pre-push (if any) may shadow the RiotBox hook depending on which"
	echo "config wins on your install. Verify with: git push --dry-run."
fi
