#!/usr/bin/env bash

# Source .bashrc for nvm/cargo/rvm, then exec the command directly.
# Unlike "bash -lc", this preserves TTY allocation for interactive programs
# like claude (which needs a TTY for its UI).
#
# Static config (git identity, gpgsign, dnf assumeyes, git guardrails, etc.)
# is baked into the image. Only runtime-dependent setup belongs here.
source ~/.bashrc 2>/dev/null

# Easy environment reference for the underlying host
if [ -f /etc/hosts ]; then
  PARENT_HOST=$( sed -n '/host\..*\.internal/{s/[[:space:]]\+/ /g; s/^ //; s/[^ ]* \([^ ]*\).*/\1/p; q}' /etc/hosts 2>/dev/null )
  if [ -n "$PARENT_HOST" ]; then
    export PARENT_HOST
  fi
fi

# Disable Claude Code telemetry and update checks — the container is
# air-gapped from these services and they cause hangs on startup.
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1
export CLAUDE_CODE_SKIP_UPDATE_CHECK=1

# Point Claude Code's config dir at the bind-mounted session directory.
# This ensures ALL reads and writes (config, credentials, lock files) happen
# on the persistent bind mount instead of the ephemeral overlay filesystem.
# Without this, ~/.claude.json lives on the overlay and token refresh can
# fail when Claude Code's saveConfigWithLock detects a mismatch between the
# in-memory cache and the on-disk file (GH #3117 protection).
export CLAUDE_CONFIG_DIR="${HOME}/.claude"

# Mark multi-project mount subdirectories as safe for git
for d in /workspace/*/; do
    [ -d "${d}.git" ] && git config --global --add safe.directory "${d%/}"
done

# Ensure Claude Code directories exist
mkdir -p ~/.claude/debug ~/.claude/plugins/cache

# Inject riotbox system prompt as ~/.claude/CLAUDE.md so it persists through
# context compression (re-injected as system reminders throughout the conversation).
RIOTBOX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RIOTBOX_SCRIPT_DIR}/inject-claude-md.sh"
source "${RIOTBOX_SCRIPT_DIR}/session-branch.sh"
source "${RIOTBOX_SCRIPT_DIR}/overlay-setup.sh"
source "${RIOTBOX_SCRIPT_DIR}/plugin-setup.sh"

# Plugin setup: seed settings, copy staged + host plugins, install marketplace
# plugins from config/env, wire statusline, sync enabledPlugins.
plugin_setup

# Overlay: mount fuse-overlayfs at /workspace (sets SESSION_BRANCH=0 if active)
overlay_setup

# Session branch: create a dedicated branch for this session (if repo detected
# and not suppressed). Must run after all setup is complete, before the main
# command, so Claude starts on the right branch.
session_branch_setup

# Run the main command without exec so this shell survives to run teardown.
# exec was originally used to avoid bash -lc semantics — sourcing .bashrc above
# already handles that. Foreground child processes inherit the TTY regardless.
if [ $# -eq 0 ]; then
    bash
else
    "$@"
fi
_exit_code=$?

# Overlay: print exit summary with change stats
overlay_teardown

# Session branch: fast-forward merge back to the original branch on clean exit.
# On hard kill (SIGKILL) this won't run — the session branch persists on disk
# and can be merged manually.
session_branch_teardown

exit $_exit_code
