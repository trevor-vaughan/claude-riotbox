#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# detect-mounts.sh — Auto-detect home directory paths to mount into the riotbox.
#
# Outputs docker/podman -v flags, one per line. Separates mounts into:
#   1. Functional dirs (settings, scripts) — bind mounts with :z
#   2. Package caches — named volumes (no SELinux relabeling needed)
#   3. User-defined mounts from mounts.conf — bind mounts (read-only :ro,z)
#
# Sensitive directories (.ssh, .gnupg, .kube, .aws, etc.) are NEVER mounted
# by the auto-detection. Users can explicitly mount files via mounts.conf.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTAINER_HOME="/home/claude"
RIOTBOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-riotbox"

# ── Functional mounts ────────────────────────────────────────────────────────
# These are directories the container needs for correct operation.
# Bind-mounted with :z because they're small and need SELinux relabeling.
FUNCTIONAL_MOUNTS=(
    # User scripts and tools
    "bin"
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
# project-specific subdirectory of $XDG_DATA_HOME/claude-riotbox/ as ~/.claude.
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
        echo "-v ${src}:${CONTAINER_HOME}/${rel}:ro,z"
    fi
done

for entry in "${CACHE_MOUNTS[@]}"; do
    read -r vol_name rel_path <<< "${entry}"
    echo "-v ${vol_name}:${CONTAINER_HOME}/${rel_path}"
done

# ── User-defined mounts from mounts.conf ─────────────────────────────────────
# Users can specify additional files/directories to mount into the container
# by listing them in ~/.config/claude-riotbox/mounts.conf (one per line).
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

        # Resolve host path
        case "${line}" in
            ~/*) src="${HOME}/${line#\~/}" ;;
            /*)  src="${line}" ;;
            *)   src="${HOME}/${line}" ;;
        esac

        # Resolve container destination
        case "${line}" in
            /*) dst="${line}" ;;
            ~/*) dst="${CONTAINER_HOME}/${line#\~/}" ;;
            *)  dst="${CONTAINER_HOME}/${line}" ;;
        esac

        if [ -e "${src}" ]; then
            echo "-v ${src}:${dst}:ro,z"
        fi
    done < "${MOUNTS_CONF}"
fi
