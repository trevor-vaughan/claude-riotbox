#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/preflight.sh — host-environment preflight checks for riotbox.
#
# Verifies every prerequisite that has historically caused opaque mid-run
# failures: container runtime, FUSE driver, task runner, image build, and
# credential readability. Each check has a short label, an exit code, and a
# fix hint. The same helpers are reused by `riotbox doctor` (the
# user-facing entry point), `setup.sh` (post-install verification), and
# anywhere else the engine wants to fail-fast with a clear diagnosis.
#
# Modes:
#   - Executed directly: prints human-readable status to stdout and exits
#     with an exit code per the table below. Strict mode (set -uo pipefail)
#     is applied to the script process only.
#   - Sourced (any `BASH_SOURCE[0]` ≠ `$0`): functions are defined but no
#     checks run, and the caller's shell options are NOT modified. Callers
#     compose checks via preflight_run or call individual preflight_check_*
#     helpers.
#
# Environment knobs:
#   RIOTBOX_DOCTOR_QUIET=1   Print only failures (still prints the failure's
#                            fix hint).
#   RIOTBOX_DOCTOR_JSON=1    Emit one JSON line per check via log_emit.
#                            Mutually exclusive with QUIET (JSON wins).
#   RIOTBOX_DOCTOR_ALL=1     Run every check even after a failure. Exit code
#                            reflects the FIRST failure (0 if all pass).
#   IMAGE_NAME               RiotBox image tag to look for (default
#                            `riotbox`, matches scripts/build.sh).
#                            Read at call time inside preflight_check_image,
#                            so sourced callers can override per-call.
#
# Exit codes:
#   0   all checks pass
#   12  podman missing or `podman info` failed
#   13  fuse-overlayfs missing
#   14  task missing
#   15  git missing
#   16  jq missing
#   17  RiotBox image not built
#   18  no readable credentials (ANTHROPIC_API_KEY unset and no creds file)
#   19  ~/.claude/plugins exists but is not readable
#   20  ~/.claude/skills exists but is not readable
# ─────────────────────────────────────────────────────────────────────────────

# Strict mode applies only when this file is run as a script. When sourced as
# a library, the caller's shell options (set -u, pipefail) are preserved —
# enabling them globally would silently change the calling shell's behavior
# and break callers that haven't opted in.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -uo pipefail
fi

PREFLIGHT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${PREFLIGHT_SCRIPT_DIR}/lib/log.sh"

# ── Output helpers ──────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    PREFLIGHT_GREEN=$'\033[0;32m'
    PREFLIGHT_RED=$'\033[0;31m'
    PREFLIGHT_RESET=$'\033[0m'
else
    PREFLIGHT_GREEN='' PREFLIGHT_RED='' PREFLIGHT_RESET=''
fi

# _preflight_report <check-id> <result: ok|fail> <label> [<exit-code>] [<hint>]
#
# Emits one report line in whichever mode the env vars selected. JSON wins
# over QUIET; default mode prints `[ok] <label>` or `[XX] <label>` plus the
# fix hint on the next line for failures.
_preflight_report() {
    local check="$1" result="$2" label="$3" code="${4:-0}" hint="${5:-}"

    if [ -n "${RIOTBOX_DOCTOR_JSON:-}" ]; then
        local extras='{}'
        if [ "${result}" = "fail" ]; then
            extras="$(jq -cn --arg hint "${hint}" --argjson code "${code}" \
                '{hint:$hint, code:$code}')"
        fi
        log_emit \
            "$([ "${result}" = "ok" ] && echo "info" || echo "error")" \
            "doctor.${check}" \
            "${label}" \
            "$(jq -cn --arg check "${check}" --arg result "${result}" \
                --argjson extras "${extras}" \
                '{check:$check, result:$result} + $extras')"
        return
    fi

    if [ "${result}" = "ok" ]; then
        if [ -z "${RIOTBOX_DOCTOR_QUIET:-}" ]; then
            printf '%s[ok]%s %s\n' "${PREFLIGHT_GREEN}" "${PREFLIGHT_RESET}" "${label}"
        fi
    else
        printf '%s[%02d]%s %s\n' "${PREFLIGHT_RED}" "${code}" "${PREFLIGHT_RESET}" "${label}"
        printf '      → %s\n' "${hint}"
    fi
}

# ── Individual checks ───────────────────────────────────────────────────────
# Each preflight_check_* function returns its specific exit code on failure
# (0 on success) and emits exactly one report line via _preflight_report.

preflight_check_podman() {
    local label="podman available and responsive"
    if ! command -v podman >/dev/null 2>&1; then
        _preflight_report podman fail "${label}" 12 \
            "Install podman, then re-run setup.sh"
        return 12
    fi
    if ! podman info >/dev/null 2>&1; then
        _preflight_report podman fail "${label}" 12 \
            "Install podman, then re-run setup.sh"
        return 12
    fi
    _preflight_report podman ok "${label}"
    return 0
}

preflight_check_fuse_overlayfs() {
    local label="fuse-overlayfs available"
    if ! command -v fuse-overlayfs >/dev/null 2>&1; then
        _preflight_report fuse_overlayfs fail "${label}" 13 \
            "Install fuse-overlayfs (apt: fuse-overlayfs; dnf: fuse-overlayfs)"
        return 13
    fi
    _preflight_report fuse_overlayfs ok "${label}"
    return 0
}

preflight_check_task() {
    local label="task runner available"
    if ! command -v task >/dev/null 2>&1; then
        _preflight_report task fail "${label}" 14 \
            "Install task from https://taskfile.dev"
        return 14
    fi
    _preflight_report task ok "${label}"
    return 0
}

preflight_check_git() {
    local label="git available"
    if ! command -v git >/dev/null 2>&1; then
        _preflight_report git fail "${label}" 15 "Install git"
        return 15
    fi
    _preflight_report git ok "${label}"
    return 0
}

preflight_check_jq() {
    local label="jq available"
    if ! command -v jq >/dev/null 2>&1; then
        _preflight_report jq fail "${label}" 16 "Install jq"
        return 16
    fi
    _preflight_report jq ok "${label}"
    return 0
}

preflight_check_image() {
    # Read IMAGE_NAME at call time, not at source time — that way a sourced
    # caller can do `IMAGE_NAME=my-tag preflight_check_image` and the
    # override actually takes effect. Default matches scripts/build.sh.
    local image="${IMAGE_NAME:-riotbox}"
    local label="riotbox image present (${image})"
    # podman image exists is the cheap check; if podman itself is broken
    # the earlier preflight_check_podman has already failed. We still guard
    # here in case this function is called standalone.
    if ! command -v podman >/dev/null 2>&1; then
        _preflight_report image fail "${label}" 17 \
            "Run riotbox build (image '${image}' not found)"
        return 17
    fi
    if ! podman image exists "${image}" 2>/dev/null; then
        _preflight_report image fail "${label}" 17 \
            "Run riotbox build (image '${image}' not found)"
        return 17
    fi
    _preflight_report image ok "${label}"
    return 0
}

preflight_check_creds() {
    local label="claude credentials readable"
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        _preflight_report creds ok "${label}"
        return 0
    fi
    if [ -r "${HOME}/.claude/.credentials.json" ]; then
        _preflight_report creds ok "${label}"
        return 0
    fi
    if [ -r "${HOME}/.claude.json" ]; then
        _preflight_report creds ok "${label}"
        return 0
    fi
    _preflight_report creds fail "${label}" 18 \
        "Set ANTHROPIC_API_KEY or run \`claude\` once on the host to complete OAuth"
    return 18
}

preflight_check_plugins_dir() {
    local label="host plugin dir readable (if present)"
    local dir="${HOME}/.claude/plugins"
    if [ ! -d "${dir}" ]; then
        _preflight_report plugins_dir ok "${label}"
        return 0
    fi
    if [ ! -r "${dir}" ]; then
        _preflight_report plugins_dir fail "${label}" 19 \
            "Make ~/.claude/plugins readable, or remove it if you don't use host plugins"
        return 19
    fi
    _preflight_report plugins_dir ok "${label}"
    return 0
}

preflight_check_skills_dir() {
    local label="host skill dir readable (if present)"
    local dir="${HOME}/.claude/skills"
    if [ ! -d "${dir}" ]; then
        _preflight_report skills_dir ok "${label}"
        return 0
    fi
    if [ ! -r "${dir}" ]; then
        _preflight_report skills_dir fail "${label}" 20 \
            "Make ~/.claude/skills readable, or remove it"
        return 20
    fi
    _preflight_report skills_dir ok "${label}"
    return 0
}

# ── Composition ─────────────────────────────────────────────────────────────

# preflight_run: invokes every check in order. By default returns at the
# first failure with that check's exit code. With RIOTBOX_DOCTOR_ALL=1 it
# runs every check; the return code is the FIRST failure encountered (or 0
# if all checks passed).
preflight_run() {
    local first_rc=0 rc
    local checks=(
        preflight_check_podman
        preflight_check_fuse_overlayfs
        preflight_check_task
        preflight_check_git
        preflight_check_jq
        preflight_check_image
        preflight_check_creds
        preflight_check_plugins_dir
        preflight_check_skills_dir
    )
    for fn in "${checks[@]}"; do
        rc=0
        "${fn}" || rc=$?
        if [ "${rc}" -ne 0 ]; then
            if [ "${first_rc}" -eq 0 ]; then
                first_rc="${rc}"
            fi
            if [ -z "${RIOTBOX_DOCTOR_ALL:-}" ]; then
                return "${first_rc}"
            fi
        fi
    done
    return "${first_rc}"
}

# ── Entry point ─────────────────────────────────────────────────────────────
# Run only when executed directly. Sourcing leaves the functions defined
# without side effects, which is what library callers want.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    preflight_run
    exit $?
fi
