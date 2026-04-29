#!/usr/bin/env bash
# opencode-setup.sh — Runtime setup for opencode inside the riotbox.
#
# Sourced by entrypoint.sh. Provides:
#   opencode_setup — place AGENTS.md (from template, or from RIOTBOX_PROMPT
#                    override) and write a baseline opencode.json when none
#                    was synced from the host.
#
# Idempotent: safe to run on every container start. Never overwrites an
# existing opencode.json — that would clobber the user's host config.

opencode_setup() {
    local opencode_dir="${HOME}/.config/opencode"
    local agents_md="${opencode_dir}/AGENTS.md"
    local opencode_json="${opencode_dir}/opencode.json"
    local template="${HOME}/.riotbox/AGENTS.md.template"

    mkdir -p "${opencode_dir}"

    # ── AGENTS.md: render from RIOTBOX_PROMPT override, or copy from template
    # Build-time render under ${HOME}/.config/opencode/ is shadowed by the
    # session-dir bind mount, so runtime placement is required on every start.
    if [ -n "${RIOTBOX_PROMPT:-}" ] && [ -f "${RIOTBOX_PROMPT}" ]; then
        local os_pretty="Linux"
        if [ -f /etc/os-release ]; then
            # Subshell isolates the source so /etc/os-release variables
            # (NAME, PRETTY_NAME, ID, …) do not leak into the caller's env.
            # shellcheck disable=SC1091
            os_pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")"
        fi
        awk -v os="${os_pretty}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
            "${RIOTBOX_PROMPT}" > "${agents_md}"
    elif [ ! -f "${agents_md}" ] && [ -f "${template}" ]; then
        cp "${template}" "${agents_md}"
    fi

    # ── opencode.json: write baseline only if absent (host config wins)
    if [ ! -f "${opencode_json}" ]; then
        cat > "${opencode_json}" <<'BASELINE'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow",
  "autoupdate": false,
  "share": "disabled",
  "instructions": ["~/.config/opencode/AGENTS.md"]
}
BASELINE
    fi
}
