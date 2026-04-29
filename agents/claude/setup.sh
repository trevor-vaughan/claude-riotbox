#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/claude/setup.sh — Container-side runtime setup for Claude Code.
#
# Sourced by the claude manifest's agent_claude_container_setup function.
# The default managed policy at /etc/claude-code/CLAUDE.md is pre-rendered
# at build time in the Dockerfile, so this is a no-op in the common case.
# It only does work when RIOTBOX_PROMPT is set (runtime override) or when
# the build-time render is missing (older image fallback).
#
# Optional environment:
#   RIOTBOX_PROMPT — custom system prompt template (triggers runtime render)
#   RIOTBOX_MANAGED_POLICY_DIR — override target directory (testing only)
# ─────────────────────────────────────────────────────────────────────────────

claude_setup() {
    local managed_policy_dir="${RIOTBOX_MANAGED_POLICY_DIR:-/etc/claude-code}"
    local os_pretty="Linux"

    _claude_setup_read_os_pretty() {
        if [ -f /etc/os-release ]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            os_pretty="${PRETTY_NAME:-Linux}"
        fi
    }

    if [ -n "${RIOTBOX_PROMPT:-}" ]; then
        # Explicit override — render custom template at runtime. May produce
        # a SELinux AVC denial when writing to /etc/ in enforcing mode; in
        # permissive mode the denial is harmless.
        _claude_setup_read_os_pretty
        awk -v os="${os_pretty}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
            "${RIOTBOX_PROMPT}" > "${managed_policy_dir}/CLAUDE.md"
    elif [ ! -f "${managed_policy_dir}/CLAUDE.md" ] && [ -f /etc/riotbox/CLAUDE.md ]; then
        # Fallback: build-time render missing (older image without the
        # Dockerfile RUN step). Render from the default template.
        _claude_setup_read_os_pretty
        awk -v os="${os_pretty}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
            /etc/riotbox/CLAUDE.md > "${managed_policy_dir}/CLAUDE.md"
    fi

    unset -f _claude_setup_read_os_pretty
}
