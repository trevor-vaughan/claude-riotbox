#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — Install the claude-riotbox CLI wrapper.
# Usage: ./install.sh [target_dir]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-${HOME}/bin}"

mkdir -p "${TARGET_DIR}"

cat > "${TARGET_DIR}/claude-riotbox" <<'WRAPPER'
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# claude-riotbox — CLI wrapper for Claude Riotbox
#
# Primary commands (no -- separator needed):
#   claude-riotbox                       → shell in CWD
#   claude-riotbox .                     → shell in .
#   claude-riotbox . ../other            → shell with multiple projects
#   claude-riotbox run "prompt" . ../o   → run with prompt + projects
#   claude-riotbox shell . ../other      → explicit shell
#   claude-riotbox resume .              → resume last session
#   claude-riotbox reown [flags]         → rewrite Claude's commits
#
# Everything else passes through to task:
#   claude-riotbox build                 → task build
#   claude-riotbox test                  → task test
#   claude-riotbox session:audit -- ...  → task session:audit -- ...
# ─────────────────────────────────────────────────────────────────────────────
RIOTBOX_DIR="@@RIOTBOX_DIR@@"

# Resolve the Taskfile for pass-through commands
run_task() { exec task --taskfile "${RIOTBOX_DIR}/Taskfile.yml" "$@"; }

# Check if ALL arguments are existing paths
all_paths() {
    [ $# -ge 1 ] || return 1
    for arg in "$@"; do
        [ -e "$arg" ] || return 1
    done
}

# No arguments → shell in CWD
if [ $# -eq 0 ]; then
    run_task shell -- .
fi

cmd="$1"
shift

case "${cmd}" in
    run)
        # run <prompt> [projects...]
        # First arg is the prompt, rest are project paths
        run_task run -- "$@"
        ;;
    shell)
        # shell [projects...]
        if [ $# -eq 0 ]; then
            run_task shell -- .
        else
            run_task shell -- "$@"
        fi
        ;;
    resume)
        # resume [projects...]
        if [ $# -eq 0 ]; then
            run_task resume -- .
        else
            run_task resume -- "$@"
        fi
        ;;
    reown)
        # reown [flags...] — runs from CWD
        run_task reown -- "$@"
        ;;
    *)
        # If cmd + remaining args are all paths → shell shortcut
        if all_paths "${cmd}" "$@"; then
            run_task shell -- "${cmd}" "$@"
        else
            # Pass through to task (build, test, clean, etc.)
            run_task "${cmd}" "$@"
        fi
        ;;
esac
WRAPPER

# Inject the actual riotbox directory path
sed -i "s|@@RIOTBOX_DIR@@|${SCRIPT_DIR}|g" "${TARGET_DIR}/claude-riotbox"

chmod +x "${TARGET_DIR}/claude-riotbox"
echo "Installed: ${TARGET_DIR}/claude-riotbox"

if ! echo "${PATH}" | tr ':' '\n' | grep -qx "${TARGET_DIR}"; then
    echo "Note: ${TARGET_DIR} is not in your PATH. Add it:"
    echo "  export PATH=\"${TARGET_DIR}:\${PATH}\""
fi
