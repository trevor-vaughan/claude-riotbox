#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# inject-claude-md — ensures the riotbox system prompt is at the managed policy path
#
# The default managed policy (/etc/claude-code/CLAUDE.md) is pre-rendered at
# build time in the Dockerfile, so no runtime write is needed for the common
# case. This avoids SELinux AVC denials — the container process (container_t)
# cannot write to /etc/ paths (etc_t) in the overlay filesystem.
#
# Runtime rendering only occurs when RIOTBOX_PROMPT is explicitly set to a
# custom template path. This is an opt-in override that may produce a
# (harmless-in-permissive, blocked-in-enforcing) AVC denial.
#
# Optional environment:
#   RIOTBOX_PROMPT — path to custom system prompt template (triggers runtime render)
#   RIOTBOX_MANAGED_POLICY_DIR — override target directory (testing only)
# ─────────────────────────────────────────────────────────────────────────────

MANAGED_POLICY_DIR="${RIOTBOX_MANAGED_POLICY_DIR:-/etc/claude-code}"

if [ -n "${RIOTBOX_PROMPT:-}" ]; then
    # ── Explicit override: render custom template at runtime ─────────────
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_PRETTY_NAME="${PRETTY_NAME:-Linux}"
    else
        OS_PRETTY_NAME="Linux"
    fi
    awk -v os="${OS_PRETTY_NAME}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        "${RIOTBOX_PROMPT}" > "${MANAGED_POLICY_DIR}/CLAUDE.md"
elif [ ! -f "${MANAGED_POLICY_DIR}/CLAUDE.md" ]; then
    # ── Fallback: build-time render missing (older image without the
    #    Dockerfile RUN step). Render from the default template. ──────────
    if [ -f /etc/riotbox/CLAUDE.md ]; then
        if [ -f /etc/os-release ]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            OS_PRETTY_NAME="${PRETTY_NAME:-Linux}"
        else
            OS_PRETTY_NAME="Linux"
        fi
        awk -v os="${OS_PRETTY_NAME}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
            /etc/riotbox/CLAUDE.md > "${MANAGED_POLICY_DIR}/CLAUDE.md"
    fi
fi
