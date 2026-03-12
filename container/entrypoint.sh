#!/usr/bin/env bash
# Source .bashrc for nvm/cargo/rvm, then exec the command directly.
# Unlike "bash -lc", this preserves TTY allocation for interactive programs
# like claude (which needs a TTY for its UI).
#
# Static config (git identity, gpgsign, dnf assumeyes, git guardrails, etc.)
# is baked into the image. Only runtime-dependent setup belongs here.
source ~/.bashrc 2>/dev/null

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

# Seed Claude Code settings on first run, or migrate stale settings.
# Plugins are now installed via the CLI — remove any legacy enabledPlugins
# field so Claude Code doesn't try to resolve plugins it can't find.
if [ ! -f ~/.claude/settings.json ]; then
    jq -n '{
        promptSuggestionEnabled: false,
        skipDangerousModePermissionPrompt: true,
        autoCompact: true
    }' > ~/.claude/settings.json
elif jq -e '.enabledPlugins' ~/.claude/settings.json &>/dev/null; then
    jq 'del(.enabledPlugins)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
        && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
fi

# Plugins: copy pre-staged plugins into the session dir on first run.
# Plugins are pre-installed at build time into ~/.riotbox/plugins-staging/
# to avoid network access and Node.js spawns at startup.
STAGING_DIR="${HOME}/.riotbox/plugins-staging/.claude"

installed="$(jq -r '.plugins | length' ~/.claude/plugins/installed_plugins.json 2>/dev/null || echo 0)"
if [ "${installed}" = "0" ] && [ -d "${STAGING_DIR}/plugins" ]; then
    echo "Copying pre-staged plugins..."
    # Copy plugin cache and metadata from the build-time staging dir
    cp -a "${STAGING_DIR}/plugins/"* ~/.claude/plugins/
    # Fix paths — staging used a different HOME
    sed -i "s|${STAGING_DIR}|${HOME}/.claude|g" \
        ~/.claude/plugins/installed_plugins.json \
        ~/.claude/plugins/known_marketplaces.json 2>/dev/null || true
    # Merge marketplace registration into settings.json
    if [ -f "${STAGING_DIR}/settings.json" ]; then
        marketplaces="$(jq '.extraKnownMarketplaces // {}' "${STAGING_DIR}/settings.json")"
        jq --argjson m "${marketplaces}" '.extraKnownMarketplaces = ($m + (.extraKnownMarketplaces // {}))' \
            ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
    fi
fi

# Wire up statusline-command.sh if present.
# Claude Code reads settings.json key "statusLine" as an object:
#   { "type": "command", "command": "<path>" }
# A flat "statusCommand" string key is wrong and is silently ignored.
if [ -f ~/.claude/statusline-command.sh ]; then
    jq '.statusLine = {"type": "command", "command": "/home/claude/.claude/statusline-command.sh"}' \
        ~/.claude/settings.json > ~/.claude/settings.json.tmp \
        && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
else
    jq 'del(.statusLine)' \
        ~/.claude/settings.json > ~/.claude/settings.json.tmp \
        && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
fi

# Ensure all installed plugins are enabled in settings.json.
# Done via jq (pure JSON) instead of `claude plugin enable` to avoid
# spawning a Node.js process per plugin on every startup.
if [ -f ~/.claude/plugins/installed_plugins.json ]; then
    # Build enabledPlugins map from installed_plugins.json keys
    new_enabled="$(jq '.plugins | keys | map({(.): true}) | add // {}' \
        ~/.claude/plugins/installed_plugins.json)"
    jq --argjson p "${new_enabled}" '.enabledPlugins = ($p + (.enabledPlugins // {}))' \
        ~/.claude/settings.json > ~/.claude/settings.json.tmp \
        && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
fi

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

# Session branch: fast-forward merge back to the original branch on clean exit.
# On hard kill (SIGKILL) this won't run — the session branch persists on disk
# and can be merged manually.
session_branch_teardown

exit $_exit_code
