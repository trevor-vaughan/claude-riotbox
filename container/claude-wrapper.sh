#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# claude-wrapper — wraps the real claude binary with riotbox defaults.
#
# Installed to /home/claude/.riotbox/bin/claude, which is first in PATH, so it
# shadows the npm-installed claude from nvm. The wrapper adds:
#   --dangerously-skip-permissions  (safe: the container IS the riotbox)
#
# The riotbox system prompt is injected as ~/.claude/CLAUDE.md by the
# entrypoint (not --append-system-prompt) so it survives context compression.
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
    "$@"
