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

# Source the agent registry at runtime (not install time) so newly added
# agents are picked up without re-running install.sh. The registry is a
# pure-bash file that auto-discovers agents/<name>/manifest.sh.
# shellcheck disable=SC1091
source "${RIOTBOX_DIR}/agents/registry.sh"

run_task() { exec task --taskfile "${RIOTBOX_DIR}/Taskfile.yml" "$@"; }

all_paths() {
    [ $# -ge 1 ] || return 1
    for arg in "$@"; do [ -e "$arg" ] || return 1; done
}

usage() {
    cat <<EOF
Usage: claude-riotbox [command] [args...]

Global flags:
  --agent=<claude|opencode>    Select the AI agent (default: claude).
                               May also be set via RIOTBOX_AGENT env var.

Session commands:
  .                            Open shell in current directory
  . ../other                   Open shell with multiple projects
  shell [projects...]          Open a shell (explicit)
  run "prompt" [projects...]   Run agent with a prompt
  resume [projects...]         Resume the last session
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
  agents                       List registered agents (riotbox name + binary)
  version                      Show the current version

Task runner:
  task <task> [args...]        Pass a command through to the task runner
                               e.g. task build, task test, task docker:clean

Any unrecognized command is passed through to task automatically.
EOF
}

# Parse --agent=<name> flag (consumed before dispatch to task).
# Validates against the allowed agents and re-exports as RIOTBOX_AGENT.
RIOTBOX_AGENT="${RIOTBOX_AGENT:-claude}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent=*)
            RIOTBOX_AGENT="${1#--agent=}"
            shift
            ;;
        --agent)
            RIOTBOX_AGENT="${2:-}"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done
if ! agent_is_registered "${RIOTBOX_AGENT}"; then
    echo "Error: --agent must be one of: $(agent_registry_csv) (got: ${RIOTBOX_AGENT})" >&2
    exit 2
fi
export RIOTBOX_AGENT

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
    agents)
        # List registered agents with their real binary name. Two columns
        # so future agents whose riotbox name differs from the binary
        # (e.g. cursor-agent → cursor) read clearly. Column width is
        # computed from the longest agent name so a long-named agent does
        # not break alignment.
        agents_max_width=0
        for agent in "${AGENT_REGISTRY[@]}"; do
            [ "${#agent}" -gt "${agents_max_width}" ] && agents_max_width="${#agent}"
        done
        for agent in "${AGENT_REGISTRY[@]}"; do
            binary="$(agent_call "${agent}" real_binary)"
            printf "%-${agents_max_width}s  %s\n" "${agent}" "${binary}"
        done
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
# if SCRIPT_DIR contains |, /, or other sed metacharacters). The agent list
# is no longer baked here — the wrapper sources agents/registry.sh at
# runtime so newly added agents are picked up without re-installing.
awk -v dir="${SCRIPT_DIR}" -v ver="${VERSION}" \
    '{gsub(/@@RIOTBOX_DIR@@/, dir); \
      gsub(/@@RIOTBOX_VERSION@@/, ver); \
      print}' \
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
