#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# vertex-adc-prompt.sh — Offer to mount gcloud ADC when Vertex routing is on.
#
# Sourced (not executed) by launch.sh BEFORE credfile-vars.sh. Provides:
#   vertex_adc_prompt — when CLAUDE_CODE_USE_VERTEX is set on the host,
#                       GOOGLE_APPLICATION_CREDENTIALS is NOT already set,
#                       and ~/.config/gcloud/application_default_credentials.json
#                       exists, prompt the user (TTY only) to mount the file.
#                       On 'y', exports GOOGLE_APPLICATION_CREDENTIALS so that
#                       credfile-vars.sh bind-mounts it RO at the standard
#                       /run/secrets/gcp-creds.json path. On 'n' or non-TTY,
#                       no change — user must arrange the credential
#                       themselves (set GOOGLE_APPLICATION_CREDENTIALS on the
#                       host or copy the file into the container).
#
# Why prompt instead of auto-mounting: auto-mounting host credentials without
# explicit consent each session changes the container's auth surface silently.
# A single `[y/N]` keeps the user in the loop and matches the project's
# preference for explicit credential plumbing.
# ─────────────────────────────────────────────────────────────────────────────

vertex_adc_prompt() {
    [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ] || return 0
    [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] || return 0

    local adc_file="${HOME}/.config/gcloud/application_default_credentials.json"
    [ -f "${adc_file}" ] || return 0

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "Notice: CLAUDE_CODE_USE_VERTEX is set but GOOGLE_APPLICATION_CREDENTIALS is not." >&2
        echo "        Found ${adc_file} but stdin/stdout is not a TTY — not prompting." >&2
        echo "        Set GOOGLE_APPLICATION_CREDENTIALS on the host to mount a credential file." >&2
        return 0
    fi

    echo "" >&2
    echo "CLAUDE_CODE_USE_VERTEX is set, but GOOGLE_APPLICATION_CREDENTIALS is not." >&2
    printf "Mount %s read-only into the container? [y/N] " "${adc_file}" >&2
    local answer
    read -r answer
    case "${answer}" in
        [Yy]|[Yy][Ee][Ss])
            export GOOGLE_APPLICATION_CREDENTIALS="${adc_file}"
            echo "Will bind-mount ${adc_file} into the container." >&2
            ;;
        *)
            echo "Skipping. To use Vertex, set GOOGLE_APPLICATION_CREDENTIALS on the host before launching, or copy a credential file into the container yourself." >&2
            ;;
    esac
}
