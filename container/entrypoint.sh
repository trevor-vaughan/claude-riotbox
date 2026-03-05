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

# Mark multi-project mount subdirectories as safe for git
for d in /workspace/*/; do
    [ -d "${d}.git" ] && git config --global --add safe.directory "${d%/}"
done

# Ensure Claude Code directories exist
mkdir -p ~/.claude/debug ~/.claude/plugins/cache

# Auth token: copied into the session directory on the host side by
# mount-projects.sh. Copy (not symlink) to where Claude Code expects it —
# symlinks break because Claude does atomic rename() which fails across
# mount boundaries.
if [ -f ~/.claude/.claude.json ] && [ ! -f ~/.claude.json ]; then
    cp ~/.claude/.claude.json ~/.claude.json
fi

# Seed Claude Code settings (plugins, auto-compact, etc.) on first run.
# Only written if not already present — preserves per-session changes.
# Plugin list is read from ~/.riotbox/plugins.json (edit container/plugins.json
# in the repo to customize, then rebuild).
if [ ! -f ~/.claude/settings.json ]; then
    PLUGINS_FILE="${HOME}/.riotbox/plugins.json"
    if [ -f "${PLUGINS_FILE}" ] && command -v jq &>/dev/null; then
        PLUGINS="$(cat "${PLUGINS_FILE}")"
    else
        PLUGINS='{}'
    fi
    jq -n --argjson plugins "${PLUGINS}" '{
        enabledPlugins: $plugins,
        promptSuggestionEnabled: false,
        skipDangerousModePermissionPrompt: true,
        autoCompact: true
    }' > ~/.claude/settings.json
fi

if [ $# -eq 0 ]; then
    exec bash
else
    exec "$@"
fi
