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

# Seed Claude Code settings on first run.
# Only written if not already present — preserves per-session changes.
if [ ! -f ~/.claude/settings.json ]; then
    jq -n '{
        promptSuggestionEnabled: false,
        skipDangerousModePermissionPrompt: true,
        autoCompact: true
    }' > ~/.claude/settings.json
fi

# Install plugins via the CLI on first run. Uses the official marketplace
# so Claude Code resolves LSP servers, skills, etc. correctly.
# Plugin list is read from ~/.riotbox/plugins.json (edit container/plugins.json
# in the repo to customize, then rebuild).
PLUGINS_FILE="${HOME}/.riotbox/plugins.json"
if [ -f "${PLUGINS_FILE}" ] && command -v jq &>/dev/null; then
    # Check if plugins are already installed (idempotent across restarts)
    if [ ! -f ~/.claude/plugins/installed_plugins.json ] || \
       [ "$(jq '.plugins | length' ~/.claude/plugins/installed_plugins.json 2>/dev/null)" = "0" ]; then
        echo "Installing plugins..."
        # Use the real claude binary — the .riotbox wrapper adds session
        # flags that aren't valid for subcommands like "plugin install".
        REAL_CLAUDE=""
        IFS=: read -ra _path_entries <<< "${PATH}"
        for _dir in "${_path_entries[@]}"; do
            [[ "${_dir}" == */.riotbox/* ]] && continue
            [ -x "${_dir}/claude" ] && REAL_CLAUDE="${_dir}/claude" && break
        done
        # Add the official marketplace if not already registered
        "${REAL_CLAUDE}" plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
        # Install each plugin from the list
        for plugin in $(jq -r 'keys[]' "${PLUGINS_FILE}"); do
            echo "  ${plugin}"
            "${REAL_CLAUDE}" plugin install "${plugin}" 2>/dev/null || true
        done
    fi
fi

if [ $# -eq 0 ]; then
    exec bash
else
    exec "$@"
fi
