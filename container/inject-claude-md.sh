#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# inject-claude-md — injects riotbox system prompt into CLAUDE.md
#
# Writes the contents of a system prompt file into a CLAUDE.md file using
# <!-- BEGIN RIOTBOX --> / <!-- END RIOTBOX --> markers. Idempotent: replaces
# any existing riotbox block, preserves all other content.
#
# Required environment:
#   CLAUDE_CONFIG_DIR — directory containing CLAUDE.md (e.g. ~/.claude)
#
# Optional environment:
#   RIOTBOX_PROMPT — path to system prompt file (auto-resolved if unset)
# ─────────────────────────────────────────────────────────────────────────────

# Resolve prompt file: explicit override > user override > system default
if [ -z "${RIOTBOX_PROMPT}" ]; then
    if [ -f "${HOME}/.riotbox/CLAUDE.md" ]; then
        RIOTBOX_PROMPT="${HOME}/.riotbox/CLAUDE.md"
    elif [ -f /etc/riotbox/CLAUDE.md ]; then
        RIOTBOX_PROMPT="/etc/riotbox/CLAUDE.md"
    fi
fi

CLAUDE_MD="${CLAUDE_CONFIG_DIR}/CLAUDE.md"
if [ -n "${RIOTBOX_PROMPT}" ]; then
    BEGIN_MARKER="<!-- BEGIN RIOTBOX -->"
    END_MARKER="<!-- END RIOTBOX -->"
    RIOTBOX_BLOCK="${BEGIN_MARKER}
$(cat "${RIOTBOX_PROMPT}")
${END_MARKER}"
    # Strip any existing riotbox block (no-op if absent), then append fresh block.
    if [ -f "${CLAUDE_MD}" ]; then
        awk -v bm="${BEGIN_MARKER}" -v em="${END_MARKER}" '
            $0 == bm { skip=1; next }
            $0 == em { skip=0; next }
            !skip { print }
        ' "${CLAUDE_MD}" > "${CLAUDE_MD}.tmp"
        mv "${CLAUDE_MD}.tmp" "${CLAUDE_MD}"
    fi
    # Separate from existing content with a blank line; skip if file is empty/new
    if [ -s "${CLAUDE_MD}" ]; then
        printf '\n%s\n' "${RIOTBOX_BLOCK}" >> "${CLAUDE_MD}"
    else
        printf '%s\n' "${RIOTBOX_BLOCK}" > "${CLAUDE_MD}"
    fi
fi
