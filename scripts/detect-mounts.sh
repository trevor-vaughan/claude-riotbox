#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# detect-mounts.sh — Auto-detect home directory paths to mount into the riotbox.
#
# Outputs docker/podman -v flags, one per line. Separates mounts into:
#   1. Functional dirs (settings, scripts) — bind mounts with :z
#   2. Package caches — named volumes (no SELinux relabeling needed)
#
# Sensitive directories (.ssh, .gnupg, .kube, .aws, etc.) are NEVER mounted.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTAINER_HOME="/home/claude"

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
# project-specific subdirectory of ~/.claude-riotbox/ as ~/.claude.
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
