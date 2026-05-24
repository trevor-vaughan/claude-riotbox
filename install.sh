#!/usr/bin/env bash
# install.sh — Install RiotBox for the current user (rootless, XDG layout).
# Lays the app tree into $XDG_DATA_HOME/riotbox and symlinks the entrypoint
# into ~/.local/bin. Re-runnable; never overwrites user config.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${SRC_DIR}/VERSION" 2>/dev/null || echo "unknown")"

DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/riotbox"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/riotbox"
BIN_DIR="${HOME}/.local/bin"

# Runtime app tree shipped to the data dir. Dev-only material (Taskfile,
# .taskfiles, tests, docs, nfpm.yaml, .github) is intentionally excluded.
APP_PATHS=(bin libexec scripts agents container configs Dockerfile .dockerignore VERSION)

echo "Installing RiotBox ${VERSION} → ${DATA_DIR}"
rm -rf "${DATA_DIR}"
mkdir -p "${DATA_DIR}" "${BIN_DIR}" "${CONFIG_DIR}"
for p in "${APP_PATHS[@]}"; do
    [ -e "${SRC_DIR}/${p}" ] || continue
    cp -a "${SRC_DIR}/${p}" "${DATA_DIR}/"
done
chmod +x "${DATA_DIR}/bin/riotbox"

ln -sfn "${DATA_DIR}/bin/riotbox" "${BIN_DIR}/riotbox"
echo "  Entrypoint: ${BIN_DIR}/riotbox -> ${DATA_DIR}/bin/riotbox"

# ── Config stubs ─────────────────────────────────────────────────────────
# Seed commented stubs into the user's XDG config. Never overwrite existing
# files. Warn if a newer riotbox-config-version ships than is installed.
STUBS_DIR="${SRC_DIR}/scripts/configs"
for stub in config mounts.conf plugins.conf; do
    src="${STUBS_DIR}/${stub}"
    dst="${CONFIG_DIR}/${stub}"
    [ -f "${src}" ] || continue
    if [ ! -f "${dst}" ]; then
        cp "${src}" "${dst}"
        echo "  Config: ${dst} (created)"
    else
        shipped_ver="$(grep -m1 '^# riotbox-config-version:' "${src}" 2>/dev/null | awk '{print $NF}' || true)"
        installed_ver="$(grep -m1 '^# riotbox-config-version:' "${dst}" 2>/dev/null | awk '{print $NF}' || true)"
        if [ -n "${shipped_ver}" ] && [ -n "${installed_ver}" ] \
                && [ "${shipped_ver}" -gt "${installed_ver}" ] 2>/dev/null; then
            echo "  Config: ${dst} (exists, v${installed_ver} — v${shipped_ver} available; review ${src})"
        else
            echo "  Config: ${dst} (exists, up to date)"
        fi
    fi
done

if ! echo "${PATH}" | tr ':' '\n' | grep -qx "${BIN_DIR}"; then
    echo "Note: ${BIN_DIR} is not in your PATH. Add it:"
    echo "  export PATH=\"${BIN_DIR}:\${PATH}\""
fi
