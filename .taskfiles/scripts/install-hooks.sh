#!/usr/bin/env bash
set -euo pipefail
# Install git pre-push hook (blocks pushes with riotbox container-identity commits).
# Required env: ROOT_DIR
# Arguments: [global] (default: local repo)

scope="${1:-}"
hook_src="${ROOT_DIR}/hooks/pre-push"

if [ "${scope}" = "global" ]; then
    # Use existing core.hooksPath or default to ~/.config/git/hooks
    hooks_dir="$(git config --global core.hooksPath 2>/dev/null || true)"
    if [ -z "${hooks_dir}" ]; then
        hooks_dir="${HOME}/.config/git/hooks"
        git config --global core.hooksPath "${hooks_dir}"
        echo "Set core.hooksPath to ${hooks_dir}"
    fi
    # Expand ~ if present
    hooks_dir="${hooks_dir/#\~/$HOME}"
    mkdir -p "${hooks_dir}"
    hook_dst="${hooks_dir}/pre-push"
    global=true
else
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || { echo "ERROR: not a git repository" >&2; exit 1; }
    hook_dst="${git_dir}/hooks/pre-push"
    global=false
fi

if [ -f "${hook_dst}" ]; then
    if grep -q 'RIOTBOX-HOOK' "${hook_dst}"; then
        echo "Updating existing riotbox pre-push hook."
    else
        echo "ERROR: ${hook_dst} already exists and was not installed by riotbox." >&2
        echo "To install manually, add the contents of:" >&2
        echo "  ${ROOT_DIR}/hooks/pre-push" >&2
        echo "to your existing hook." >&2
        exit 1
    fi
fi

cp "${hook_src}" "${hook_dst}"
chmod +x "${hook_dst}"
echo "Installed pre-push hook to ${hook_dst}"
if [ "${global}" = true ]; then
    echo "Note: core.hooksPath overrides per-repo .git/hooks/ directories."
fi
