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

# Resolve prompt file: explicit RIOTBOX_PROMPT override > system default.
# Only /etc/riotbox/CLAUDE.md (root-owned, baked into the image) is used as
# the default — user-writable paths like ~/.riotbox/ are excluded to prevent
# a prompt-injected LLM from overriding the system prompt.
if [ -z "${RIOTBOX_PROMPT}" ]; then
    if [ -f /etc/riotbox/CLAUDE.md ]; then
        RIOTBOX_PROMPT="/etc/riotbox/CLAUDE.md"
    fi
fi

CLAUDE_MD="${CLAUDE_CONFIG_DIR}/CLAUDE.md"
if [ -n "${RIOTBOX_PROMPT}" ]; then
    BEGIN_MARKER="<!-- BEGIN RIOTBOX -->"
    END_MARKER="<!-- END RIOTBOX -->"
    # Detect OS from /etc/os-release (available on all modern distros)
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_PRETTY_NAME="${PRETTY_NAME:-Linux}"
    else
        OS_PRETTY_NAME="Linux"
    fi
    # Replace the OS placeholder in the prompt template
    # Use awk to avoid sed delimiter conflicts with special chars in OS names
    PROMPT_CONTENT="$(awk -v os="${OS_PRETTY_NAME}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' "${RIOTBOX_PROMPT}")"
    RIOTBOX_BLOCK="${BEGIN_MARKER}
${PROMPT_CONTENT}
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
