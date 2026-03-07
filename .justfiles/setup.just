#!/usr/bin/env just --justfile
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

# --- Variables ---
root := source_directory() / ".."
caller_dir := invocation_directory()

# --- Recipes ---

# List recipes in this module
_default:
    @just --list --unsorted

# Install claude-riotbox CLI wrapper to ~/bin (or specify dir)
# target_dir - installation directory (default: ~/bin)
install target_dir="~/bin":
    #!/usr/bin/env bash
    set -euo pipefail
    target_dir="{{target_dir}}"
    # Expand ~ manually since just doesn't do shell expansion on defaults
    target_dir="${target_dir/#\~/$HOME}"
    "{{root}}/install.sh" "${target_dir}"

# Install git pre-push hook (blocks pushes with claude@riotbox commits)
# scope - use "global" to install as global git hook (default: local repo)
install-hooks scope="":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{caller_dir}}"
    hook_src="{{root}}/hooks/pre-push"
    if [ "{{scope}}" = "global" ]; then
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
            echo "  {{root}}/hooks/pre-push" >&2
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

# Show what would be mounted from your home directory
mounts:
    #!/usr/bin/env bash
    cd "{{caller_dir}}"
    echo "Auto-detected mounts:"
    {{root}}/scripts/detect-mounts.sh | while read -r flag path; do echo "  ${path}"; done

# Rewrite Claude's commits to use your git identity
# ref - git ref or --all (default: interactive)
reown ref="":
    #!/usr/bin/env bash
    cd "{{caller_dir}}"
    exec "{{root}}/scripts/reown-commits.sh" {{ref}}
