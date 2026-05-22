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
#   CLAUDE.md          — copied if present (user-level instructions)
#   rules/             — copied if present (user-level rules, path-scoped)
#   skills/            — copied with symlink dereferencing (may be plugin symlinks)
#   agents/            — copied with symlink dereferencing (user-level subagents)
#   commands/          — copied with symlink dereferencing (user-level slash commands)
#   output-styles/     — copied with symlink dereferencing (custom output styles)
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
CONTAINER_HOME="/home/llm"

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

# ── User CLAUDE.md ───────────────────────────────────────────────────────────
# The riotbox system prompt lives at the managed policy path
# (/etc/claude-code/CLAUDE.md) inside the container, so ~/.claude/CLAUDE.md is
# free for the user's personal instructions. Copy from host if present; remove
# stale copies if the host file was deleted.
if [ -f "${HOST_CLAUDE_DIR}/CLAUDE.md" ]; then
    cp "${HOST_CLAUDE_DIR}/CLAUDE.md" "${SESSION_DIR}/CLAUDE.md"
else
    rm -f "${SESSION_DIR}/CLAUDE.md"
fi

# ── User rules ───────────────────────────────────────────────────────────────
# Personal rules in ~/.claude/rules/ apply to every project. Path-scoped rules
# use glob frontmatter and load on demand. Re-copy each launch so
# added/removed rules don't linger.
if [ -d "${HOST_CLAUDE_DIR}/rules" ]; then
    rm -rf "${SESSION_DIR}/rules"
    cp -rL "${HOST_CLAUDE_DIR}/rules" "${SESSION_DIR}/"
else
    rm -rf "${SESSION_DIR}/rules"
fi

# ── User extension directories ────────────────────────────────────────────────
# Claude Code loads user-level resources from several sibling directories under
# ~/.claude/. All follow the same loading model — a directory of files scanned
# at startup — so they share one copy routine:
#
#   skills/        — reusable instruction bundles
#   agents/        — user-defined subagents
#   commands/      — user-defined slash commands
#   output-styles/ — custom output style definitions
#
# Each may contain symlinks pointing into plugin checkouts or dev sources, so
# we dereference during copy. `cp -rL` aborts on the first dangling symlink
# (e.g. a plugin checkout the user removed). Pre-filter with `find -L … !
# -type l` — under -L, valid symlinks report their target's type, so only
# broken symlinks retain `-type l` — then stream paths through `tar -h` to
# dereference and copy. This mirrors the host-plugin copy pattern in
# container/plugin-setup.sh.
#
# Re-copy each launch so renamed/removed files don't linger; clean up the
# destination when the source has been removed so it does not outlive the
# host.
for _user_dir in skills agents commands output-styles; do
    rm -rf "${SESSION_DIR:?}/${_user_dir}"
    if [ -d "${HOST_CLAUDE_DIR}/${_user_dir}" ]; then
        ( cd "${HOST_CLAUDE_DIR}" \
            && find -L "${_user_dir}" ! -type l -print0 \
            | tar -ch --null --no-recursion --files-from=- -f - \
        ) | tar -xf - -C "${SESSION_DIR}/" --no-same-owner
    fi
done
unset _user_dir

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
# Mounted at /home/llm/.host-plugins inside the container. plugin-setup.sh
# copies contents into ~/.claude/plugins/ at startup, with host plugins taking
# highest precedence (overwriting pre-staged defaults on conflict).
if [ -d "${HOST_CLAUDE_DIR}/plugins" ]; then
    echo "-v ${HOST_CLAUDE_DIR}/plugins:${CONTAINER_HOME}/.host-plugins:ro,z"
else
    echo "Notice: ~/.claude/plugins not found on host — host plugin copy will be skipped." >&2
fi
