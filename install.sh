#!/usr/bin/env bash
# install.sh — Install the claude-riotbox CLI wrapper.
# Usage: ./install.sh [target_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"
TARGET_DIR="${1:-${HOME}/.local/bin}"

mkdir -p "${TARGET_DIR}"

cat > "${TARGET_DIR}/claude-riotbox" <<'WRAPPER'
#!/usr/bin/env bash
# claude-riotbox — CLI wrapper for Claude Riotbox
RIOTBOX_DIR="@@RIOTBOX_DIR@@"
RIOTBOX_VERSION="@@RIOTBOX_VERSION@@"

run_task() { exec task --taskfile "${RIOTBOX_DIR}/Taskfile.yml" "$@"; }

all_paths() {
    [ $# -ge 1 ] || return 1
    for arg in "$@"; do [ -e "$arg" ] || return 1; done
}

usage() {
    cat <<EOF
Usage: claude-riotbox [command] [args...]

Session commands:
  .                            Open shell in current directory
  . ../other                   Open shell with multiple projects
  shell [projects...]          Open a shell (explicit)
  run "prompt" [projects...]   Run Claude with a prompt
  resume [projects...]         Resume the last Claude session
  reown [flags...]             Rewrite Claude's commits to your git identity
  session-list                 List all riotbox sessions
  session-remove [key/path]    Remove a session by key or project path (or --all)
  session-reset [all] [force]  Reset session cache (forces fresh skill/config copy)

Overlay commands (podman-only):
  overlays                     List sessions with pending overlay data
  overlay-diff [project]       Show overlay changes vs host project
  overlay-accept [project]     Apply overlay changes to host project
  overlay-reject [project]     Discard overlay changes

Info:
  version                      Show the current version

Task runner:
  task <task> [args...]        Pass a command through to the task runner
                               e.g. task build, task test, task docker:clean

Any unrecognized command is passed through to task automatically.
EOF
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

if [[ -z "$cmd" ]]; then
    usage
    exit 0
fi

case "${cmd}" in
    help|-h|--help)
        usage
        ;;
    version|--version|-V)
        echo "claude-riotbox ${RIOTBOX_VERSION}"
        ;;
    run)
        run_task run -- "$@"
        ;;
    shell)
        run_task shell -- "${@:-.}"
        ;;
    resume)
        run_task resume -- "${@:-.}"
        ;;
    reown)
        run_task reown -- "$@"
        ;;
    session-list)
        run_task session-list
        ;;
    session-remove)
        run_task session-remove -- "$@"
        ;;
    session-reset)
        run_task session-reset -- "$@"
        ;;
    overlays)
        run_task overlays
        ;;
    overlay-diff)
        run_task overlay-diff -- "$@"
        ;;
    overlay-accept)
        run_task overlay-accept -- "$@"
        ;;
    overlay-reject)
        run_task overlay-reject -- "$@"
        ;;
    task)
        run_task "$@"
        ;;
    *)
        # If cmd + remaining args are all paths → shell shortcut
        if all_paths "${cmd}" "$@"; then
            run_task shell -- "${cmd}" "$@"
        else
            run_task "${cmd}" "$@"
        fi
        ;;
esac
WRAPPER

# Inject the actual riotbox directory path (awk avoids sed delimiter issues
# if SCRIPT_DIR contains |, /, or other sed metacharacters)
awk -v dir="${SCRIPT_DIR}" -v ver="${VERSION}" \
    '{gsub(/@@RIOTBOX_DIR@@/, dir); gsub(/@@RIOTBOX_VERSION@@/, ver); print}' \
    "${TARGET_DIR}/claude-riotbox" > "${TARGET_DIR}/claude-riotbox.tmp" \
    && mv "${TARGET_DIR}/claude-riotbox.tmp" "${TARGET_DIR}/claude-riotbox"

chmod +x "${TARGET_DIR}/claude-riotbox"
echo "Installed: ${TARGET_DIR}/claude-riotbox"

# ── Stub configuration files ─────────────────────────────────────────────
# Place commented-out config stubs in the user's XDG config directory so
# they can discover and customise settings. Never overwrite existing files.
# Each stub has a riotbox-config-version header; if the shipped version is
# newer, warn the user that new options may be available.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-riotbox"
STUBS_DIR="${SCRIPT_DIR}/scripts/configs"
mkdir -p "${CONFIG_DIR}"

for stub in config mounts.conf plugins.conf; do
    src="${STUBS_DIR}/${stub}"
    dst="${CONFIG_DIR}/${stub}"

    if [ ! -f "${src}" ]; then
        continue
    fi

    if [ ! -f "${dst}" ]; then
        cp "${src}" "${dst}"
        echo "  Config: ${dst} (created)"
    else
        # Compare riotbox-config-version between shipped stub and installed file
        shipped_ver="$(grep -m1 '^# riotbox-config-version:' "${src}" 2>/dev/null | awk '{print $NF}' || true)"
        installed_ver="$(grep -m1 '^# riotbox-config-version:' "${dst}" 2>/dev/null | awk '{print $NF}' || true)"
        if [ -n "${shipped_ver}" ] && [ -n "${installed_ver}" ] \
                && [ "${shipped_ver}" -gt "${installed_ver}" ] 2>/dev/null; then
            echo "  Config: ${dst} (exists, v${installed_ver} — v${shipped_ver} available)"
            echo "          Review ${src} for new options."
        else
            echo "  Config: ${dst} (exists, up to date)"
        fi
    fi
done

if ! echo "${PATH}" | tr ':' '\n' | grep -qx "${TARGET_DIR}"; then
    echo "Note: ${TARGET_DIR} is not in your PATH. Add it:"
    echo "  export PATH=\"${TARGET_DIR}:\${PATH}\""
fi
