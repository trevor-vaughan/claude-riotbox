#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# detect-mounts.sh — Auto-detect home directory paths to mount into the riotbox.
#
# Output formats (--format=<podman|triple>, default podman):
#   podman  one `-v host:container[:flag]` line per mount (current behavior)
#   triple  one `host:container:mode` line per mount, where mode is `rw` or
#           `ro`. Intended for downstream config generators / tests that need
#           a structured mount table without regex-parsing podman flags.
#
# Separates mounts into:
#   1. Functional dirs (settings, scripts) — bind mounts with :z (rw or ro)
#   2. Package caches — named volumes (rw, no SELinux relabeling needed)
#   3. User-defined mounts from mounts.conf — bind mounts, always ro
#
# Sensitive directories (.ssh, .gnupg, .kube, .aws, etc.) are NEVER mounted
# by the auto-detection. Users can explicitly mount files via mounts.conf.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTAINER_HOME="/home/claude"
RIOTBOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/riotbox"

# ── Output format ───────────────────────────────────────────────────────────
OUTPUT_FORMAT="podman"
for arg in "$@"; do
    case "${arg}" in
        --format=podman) OUTPUT_FORMAT="podman" ;;
        --format=triple) OUTPUT_FORMAT="triple" ;;
        --format=*)
            echo "ERROR: unknown --format value: ${arg#--format=}" >&2
            echo "       allowed: podman, triple" >&2
            exit 2
            ;;
        *)
            echo "ERROR: unknown argument: ${arg}" >&2
            exit 2
            ;;
    esac
done

# Emit one mount in the active format.
#   $1 host path
#   $2 container path
#   $3 mode: rw (default) or ro
# In podman mode we preserve the existing flag shape: rw mounts get bare ":z"
# (or no suffix for named volumes), ro mounts get ":ro,z". Whether to add :z
# is controlled by the optional 4th arg (selinux=z|none, default z).
emit_mount() {
    local host="$1" container="$2" mode="${3:-rw}" selinux="${4:-z}"
    case "${OUTPUT_FORMAT}" in
        triple)
            printf '%s:%s:%s\n' "${host}" "${container}" "${mode}"
            ;;
        podman)
            local suffix=""
            case "${mode}:${selinux}" in
                rw:z)    suffix=":z" ;;
                rw:none) suffix="" ;;
                ro:z)    suffix=":ro,z" ;;
                ro:none) suffix=":ro" ;;
            esac
            printf -- '-v %s:%s%s\n' "${host}" "${container}" "${suffix}"
            ;;
    esac
}

# ── Functional mounts ────────────────────────────────────────────────────────
# These are directories the container needs for correct operation.
# Bind-mounted with :z because they're small and need SELinux relabeling.
FUNCTIONAL_MOUNTS=(
    # User scripts and tools
    "bin"
    # Riotbox config (plugins.conf, etc.)
    ".config/riotbox"
)

# ── Auth tokens ───────────────────────────────────────────────────────────────
# Credentials (~/.claude/.credentials.json) are bind-mounted RW by
# mount-projects.sh as a nested mount inside the session dir. This lets
# Claude Code refresh OAuth tokens in-session with writes going directly
# to the host file (no copy/writeback needed).
# Config (~/.claude.json) is copied into the session dir for account metadata.
# CLAUDE_CONFIG_DIR is set in the entrypoint so Claude Code finds both files
# inside the bind-mounted session dir.

# ── Riotbox session data ─────────────────────────────────────────────────────
# Session isolation is handled by mount-projects.sh, which mounts a
# project-specific subdirectory of $XDG_DATA_HOME/riotbox/ as ~/.claude.
# The real ~/.claude is NEVER mounted — this prevents an autonomous
# container from reading your host conversation history.

# ── Cache mounts ─────────────────────────────────────────────────────────────
# Named volumes for package caches. These avoid the SELinux relabeling
# penalty of bind mounts with :z — named volumes get the correct label
# (container_file_t) automatically. The tradeoff is that caches are not
# shared with the host, but this avoids relabeling gigabytes of small
# files on every container start.
CACHE_MOUNTS=(
    # volume-name              container-path
    "riotbox-cache-npm          .npm"
    "riotbox-cache-cargo        .cargo/registry"
    "riotbox-cache-go           go/pkg"
    "riotbox-cache-pip          .cache/pip"
    "riotbox-cache-uv           .cache/uv"
    "riotbox-cache-bundler      .bundle/cache"
    "riotbox-cache-m2           .m2/repository"
    "riotbox-cache-gradle       .gradle/caches"
    "riotbox-cache-bun          .bun/install"
    # opencode installs its configured plugins (npm + git) here via `bun
    # install` at startup. Persisting it across sessions means the ~15s
    # cold install happens once; later sessions resolve plugins from the
    # warm cache in ~2s, offline. Built inside the container, so the native
    # deps match the container platform regardless of the host OS.
    "riotbox-cache-opencode     .cache/opencode"
)

# ── Sensitive directories — NEVER mount these ────────────────────────────────
# Listed here for documentation; the script uses an allowlist (above),
# not a blocklist, so these are excluded by default:
#   .ssh  .gnupg  .kube  .aws  .config/gcloud  .docker/config.json
#   .azure  .oci  .vault-token  .netrc

# ── Generate mount flags ────────────────────────────────────────────────────
for rel in "${FUNCTIONAL_MOUNTS[@]}"; do
    src="${HOME}/${rel}"
    if [ -e "${src}" ]; then
        emit_mount "${src}" "${CONTAINER_HOME}/${rel}" ro z
    fi
done

for entry in "${CACHE_MOUNTS[@]}"; do
    read -r vol_name rel_path <<< "${entry}"
    # Named volumes get container_file_t labelling automatically; no :z.
    emit_mount "${vol_name}" "${CONTAINER_HOME}/${rel_path}" rw none
done

# ── User-defined mounts from mounts.conf ─────────────────────────────────────
# Users can specify additional files/directories to mount into the container
# by listing them in ~/.config/riotbox/mounts.conf (one per line).
#
# Format:
#   - Lines starting with # are comments; blank lines are ignored
#   - Paths starting with / or ~ are absolute
#   - Other paths are relative to $HOME
#   - All user mounts are read-only (:ro,z)
#   - Mounted to the same path under /home/claude
#
# Example mounts.conf:
#   # Private npm registry auth (needed for npm install of private packages)
#   .npmrc
#   # Yarn config
#   .yarnrc.yml
#   # Maven settings
#   .m2/settings.xml
#
MOUNTS_CONF="${RIOTBOX_CONFIG_DIR}/mounts.conf"
if [ -f "${MOUNTS_CONF}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
        # Skip comments and blank lines
        line="${line%%#*}"
        line="$(echo "${line}" | xargs)" # trim whitespace
        [ -z "${line}" ] && continue

        # Resolve host and container paths. Use [[ == "~/"* ]] (quoted
        # tilde) rather than a `case ~/*` glob: bash tilde-expands an
        # unquoted ~ in case patterns, so `~/*` matches paths starting
        # with $HOME instead of paths starting with the literal "~/".
        # That bug silently dropped every tilde-prefixed mounts.conf
        # entry by routing it to the relative branch with a non-existent
        # ${HOME}/~/... source.
        # shellcheck disable=SC2088  # matching the literal "~/" prefix in user config, not expanding it
        if [[ "${line}" == "~/"* ]]; then
            src="${HOME}/${line:2}"
            dst="${CONTAINER_HOME}/${line:2}"
        elif [[ "${line}" == "/"* ]]; then
            src="${line}"
            dst="${line}"
        else
            src="${HOME}/${line}"
            dst="${CONTAINER_HOME}/${line}"
        fi

        if [ -e "${src}" ]; then
            emit_mount "${src}" "${dst}" ro z
        fi
    done < "${MOUNTS_CONF}"
fi
