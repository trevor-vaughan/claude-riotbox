#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# claude-wrapper — wraps the real claude binary with riotbox defaults.
#
# Installed to /home/claude/.riotbox/bin/claude, which is first in PATH, so it
# shadows the npm-installed claude from nvm. The wrapper adds:
#   --dangerously-skip-permissions  (safe: the container IS the riotbox)
#   --append-system-prompt          (commit discipline + install-anything policy)
#
# The real binary is found by walking PATH and skipping .riotbox/bin.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Find the real claude binary (skipping this wrapper)
source "${HOME}/.riotbox/find-real-claude.sh"
if [ -z "${REAL_CLAUDE}" ]; then
    echo "ERROR: could not find the real claude binary" >&2
    exit 1
fi

# Resolve system prompt: user override > system default
if [ -f "${HOME}/.riotbox/system-prompt.md" ]; then
    RIOTBOX_PROMPT_FILE="${HOME}/.riotbox/system-prompt.md"
elif [ -f /etc/riotbox/system-prompt.md ]; then
    RIOTBOX_PROMPT_FILE="/etc/riotbox/system-prompt.md"
else
    echo "ERROR: no system prompt found (checked ~/.riotbox/ and /etc/riotbox/)" >&2
    exit 1
fi
echo "riotbox: using prompt from ${RIOTBOX_PROMPT_FILE}" >&2
RIOTBOX_SYSTEM_PROMPT="$(cat "${RIOTBOX_PROMPT_FILE}")"

# CI=true makes many tools non-interactive/quieter, but also disables Claude's
# interactive UI. Only set it when running in non-interactive mode (-p).
for arg in "$@"; do
    if [ "$arg" = "-p" ] || [ "$arg" = "--prompt" ]; then
        export CI=true
        break
    fi
done

exec "${REAL_CLAUDE}" \
    --dangerously-skip-permissions \
    --append-system-prompt "${RIOTBOX_SYSTEM_PROMPT}" \
    "$@"
