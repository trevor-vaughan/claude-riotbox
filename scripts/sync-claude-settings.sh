#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-claude-settings.sh — Copy host Claude config files into a riotbox session dir.
#
# Usage: sync-claude-settings.sh <host-claude-dir> <session-dir>
#
# Copies (or bind-mounts via -v flags printed to stdout) the following from the
# host ~/.claude directory into the container's session directory:
#
#   .credentials.json  — RW bind mount (token refresh writes back to host)
#   .claude.json       — copied (account metadata; container may write oauthAccount)
#   skills/            — copied with symlink dereferencing (may be plugin symlinks)
#   statusline-command.sh — copied if present (custom status bar command)
#
# Bind-mount flags (for credentials) are printed to stdout so the caller can
# capture and append them to its volume flag string.
#
# Exit codes:
#   0 — success
#   1 — wrong number of arguments
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <host-claude-dir> <session-dir>" >&2
    exit 1
fi

HOST_CLAUDE_DIR="$1"
SESSION_DIR="$2"

# Container home — must match the image's user home (see detect-mounts.sh)
CONTAINER_HOME="/home/claude"

# ── Credentials (RW bind mount) ───────────────────────────────────────────────
# Bind-mounted RW as a nested mount inside the session dir so that token
# refresh writes go directly to the host file. OAuth uses rotating refresh
# tokens, so keeping the host file current is essential for subsequent runs.
if [ -f "${HOST_CLAUDE_DIR}/.credentials.json" ]; then
    echo "-v ${HOST_CLAUDE_DIR}/.credentials.json:${CONTAINER_HOME}/.claude/.credentials.json:z"
fi

# ── Config copy (.claude.json) ────────────────────────────────────────────────
# Note: .claude.json lives at ~/.claude.json (next to ~/.claude/, not inside it).
# Contains account metadata needed for auth, plus host-specific UI state that
# the container shouldn't permanently modify. Copied writable so Claude Code
# can update oauthAccount fields during token refresh without error.
if [ -f "${HOME}/.claude.json" ]; then
    dest="${SESSION_DIR}/.claude.json"
    cp "${HOME}/.claude.json" "${dest}"
    chmod 600 "${dest}"
fi

# ── Skills ────────────────────────────────────────────────────────────────────
# Skills may be symlinks to locations outside ~/.claude/ (e.g. plugin dirs or
# dev checkouts), so copy with -L to dereference them. Remove and re-copy on
# each launch so renamed/removed skills don't linger.
if [ -d "${HOST_CLAUDE_DIR}/skills" ]; then
    rm -rf "${SESSION_DIR}/skills"
    cp -rL "${HOST_CLAUDE_DIR}/skills" "${SESSION_DIR}/"
fi

# ── Statusline command ────────────────────────────────────────────────────────
# Optional user script that customises the Claude Code status bar.
# Copied (not mounted) so the container gets a clean read-only snapshot.
# chmod +x is explicit: cp preserves bits from the source, but the source may
# not be executable (e.g. created without chmod +x), so we enforce it here.
# If the source has been removed, delete any stale copy from the session dir.
if [ -f "${HOST_CLAUDE_DIR}/statusline-command.sh" ]; then
    cp "${HOST_CLAUDE_DIR}/statusline-command.sh" "${SESSION_DIR}/statusline-command.sh"
    chmod +x "${SESSION_DIR}/statusline-command.sh"
else
    rm -f "${SESSION_DIR}/statusline-command.sh"
fi

# ── Host plugins (read-only mount) ───────────────────────────────────────────
# Mounted at /home/claude/.host-plugins inside the container. plugin-setup.sh
# copies contents into ~/.claude/plugins/ at startup, with host plugins taking
# highest precedence (overwriting pre-staged defaults on conflict).
if [ -d "${HOST_CLAUDE_DIR}/plugins" ]; then
    echo "-v ${HOST_CLAUDE_DIR}/plugins:${CONTAINER_HOME}/.host-plugins:ro,z"
else
    echo "Notice: ~/.claude/plugins not found on host — host plugin copy will be skipped." >&2
fi
