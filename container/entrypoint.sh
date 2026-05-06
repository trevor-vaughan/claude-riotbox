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

# Disable all non-essential network traffic — the container runs a fixed
# Claude Code version and should not phone home for telemetry, updates,
# error reporting, or feedback surveys.
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DO_NOT_TRACK=1
export DISABLE_AUTOUPDATER=1

# opencode equivalents: disable auto-update and LSP download. The container
# runs a fixed image; outbound requests for updates or LSP servers should
# never happen in a session.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1

# Keep marketplace cache when git pull fails (container may lack network).
export CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1

# Point Claude Code at the pre-staged plugin directory as a seed source.
# This is a belt-and-suspenders addition to the manual copy in plugin-setup.sh
# — newer Claude Code versions may use this natively on first startup.
export CLAUDE_CODE_PLUGIN_SEED_DIR="${HOME}/.riotbox/plugins-staging/.claude/plugins"

# Point Claude Code's config dir at the bind-mounted session directory.
# This ensures ALL reads and writes (config, credentials, lock files) happen
# on the persistent bind mount instead of the ephemeral overlay filesystem.
# Without this, ~/.claude.json lives on the overlay and token refresh can
# fail when Claude Code's saveConfigWithLock detects a mismatch between the
# in-memory cache and the on-disk file (GH #3117 protection).
export CLAUDE_CONFIG_DIR="${HOME}/.claude"

# Pin opencode's config dir to the session-mounted location so reads and
# writes hit persistent storage instead of the overlay filesystem.
export OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"

# Mark multi-project mount subdirectories as safe for git
for d in /workspace/*/; do
    [ -d "${d}.git" ] && git config --global --add safe.directory "${d%/}"
done

# Ensure Claude Code directories exist
mkdir -p ~/.claude/debug ~/.claude/plugins/cache

# Managed policy (/etc/claude-code/CLAUDE.md) is pre-rendered at build time.
# inject-claude-md.sh is a no-op unless RIOTBOX_PROMPT overrides the template
# or the build-time render is missing (backward compat with older images).
RIOTBOX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RIOTBOX_SCRIPT_DIR}/session-branch.sh"
source "${RIOTBOX_SCRIPT_DIR}/overlay-setup.sh"
source "${RIOTBOX_SCRIPT_DIR}/plugin-setup.sh"

# Nested podman setup: file caps on newuidmap/newgidmap and /etc/sub{u,g}id
# alignment with the outer keep-id user namespace. Only run when nested mode
# is requested — otherwise SELinux confinement (still in effect) blocks setcap
# and there is no inner podman to satisfy. Older images may not have shipped
# this script; tolerate its absence gracefully.
#
# Executed as a subprocess (not sourced) so its `set -euo pipefail` stays
# inside the script. Sourcing leaked nounset into this shell, which tripped
# RVM's `cd` override (loaded by ~/.bashrc above) on a later `cd` in
# plugin_setup — RVM's environment script references rvm_bash_nounset
# without a default and dies under set -u, breaking the plugin copy pipeline.
if [ "${RIOTBOX_NESTED:-}" = "1" ] && \
   [ -x "${RIOTBOX_SCRIPT_DIR}/nested-podman-setup.sh" ]; then
    "${RIOTBOX_SCRIPT_DIR}/nested-podman-setup.sh"
fi

# Plugin setup: seed settings, copy staged + host plugins, install marketplace
# plugins from config/env, wire statusline, sync enabledPlugins.
plugin_setup

# Per-agent runtime setup. The agent registry drives this — every manifest
# defines container_setup. claude renders the system prompt (a no-op when
# the build-time render is current); opencode places AGENTS.md and the
# baseline opencode.json. Adding a new agent extends this loop with no
# edit to entrypoint.sh.
# shellcheck source=./agents/registry.sh
source "${RIOTBOX_SCRIPT_DIR}/agents/registry.sh"
for _agent in "${AGENT_REGISTRY[@]}"; do
    agent_call "${_agent}" container_setup
done
unset _agent

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
