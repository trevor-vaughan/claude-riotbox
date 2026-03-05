#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — Guided setup for Claude Riotbox.
# Checks prerequisites, configures podman, installs the CLI, and builds the
# image. Idempotent — safe to re-run; skips what's already done.
#
# Options:
#   --yes       Accept all defaults non-interactively
#   --no-build  Skip the image build step
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_YES="${RIOTBOX_SETUP_YES:-}"
SKIP_BUILD="${RIOTBOX_SETUP_NO_BUILD:-}"

for arg in "$@"; do
    case "${arg}" in
        --yes)      AUTO_YES=1 ;;
        --no-build) SKIP_BUILD=1 ;;
    esac
done

# ── Colors and symbols ───────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${AUTO_YES}" ]; then
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN='' YELLOW='' RED='' BOLD='' RESET=''
fi

ok()   { echo -e "  ${GREEN}[ok]${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}[!!]${RESET}  $*"; }
fail() { echo -e "  ${RED}[XX]${RESET}  $*"; }
step() { echo -e "\n${BOLD}$*${RESET}"; }

ask_yn() {
    local prompt="$1" default="${2:-n}"
    if [ -n "${AUTO_YES}" ]; then
        return 0
    fi
    if [ "${default}" = "y" ]; then
        printf "  %s [Y/n] " "${prompt}"
    else
        printf "  %s [y/N] " "${prompt}"
    fi
    read -r answer
    answer="${answer:-${default}}"
    [[ "${answer}" =~ ^[Yy] ]]
}

ERRORS=0
WARNINGS=0

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}Claude Riotbox Setup${RESET}"
echo "This will check prerequisites and configure your system."
echo ""

# ── 1. Container runtime ────────────────────────────────────────────────────
step "1. Container runtime"

CONTAINER_CMD=""
if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
    ok "podman $(podman --version | awk '{print $NF}')"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
    ok "docker $(docker --version | awk '{print $3}' | tr -d ',')"
    warn "Docker detected. Podman is recommended for rootless operation."
    WARNINGS=$((WARNINGS + 1))
else
    fail "Neither podman nor docker found."
    if command -v dnf &>/dev/null; then
        if ask_yn "Install podman via dnf?"; then
            sudo dnf install -y podman
            CONTAINER_CMD="podman"
            ok "podman installed"
        else
            fail "A container runtime is required. Install podman or docker and re-run."
            ERRORS=$((ERRORS + 1))
        fi
    elif command -v apt-get &>/dev/null; then
        if ask_yn "Install podman via apt?"; then
            sudo apt-get update && sudo apt-get install -y podman
            CONTAINER_CMD="podman"
            ok "podman installed"
        else
            fail "A container runtime is required. Install podman or docker and re-run."
            ERRORS=$((ERRORS + 1))
        fi
    else
        fail "A container runtime is required. Install podman or docker and re-run."
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── 2. just ──────────────────────────────────────────────────────────────────
step "2. Command runner (just)"

if command -v just &>/dev/null; then
    ok "just $(just --version | awk '{print $NF}')"
else
    fail "just not found."
    echo "  Install from: https://github.com/casey/just#installation"
    if command -v cargo &>/dev/null; then
        if ask_yn "Install just via cargo?"; then
            cargo install just
            ok "just installed via cargo"
        else
            ERRORS=$((ERRORS + 1))
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── 3. Podman-specific setup ────────────────────────────────────────────────
if [ "${CONTAINER_CMD}" = "podman" ]; then
    step "3. Podman configuration"

    # ── 3a. fuse-overlayfs ───────────────────────────────────────────────────
    if command -v fuse-overlayfs &>/dev/null; then
        ok "fuse-overlayfs found"
    else
        fail "fuse-overlayfs not found (required for --userns=keep-id without hangs)."
        if command -v dnf &>/dev/null; then
            if ask_yn "Install fuse-overlayfs via dnf?"; then
                sudo dnf install -y fuse-overlayfs
                ok "fuse-overlayfs installed"
            else
                ERRORS=$((ERRORS + 1))
            fi
        elif command -v apt-get &>/dev/null; then
            if ask_yn "Install fuse-overlayfs via apt?"; then
                sudo apt-get update && sudo apt-get install -y fuse-overlayfs
                ok "fuse-overlayfs installed"
            else
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo "  Install fuse-overlayfs for your distribution and re-run."
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # ── 3b. storage.conf ─────────────────────────────────────────────────────
    STORAGE_CONF="${HOME}/.config/containers/storage.conf"
    STORAGE_OK=false

    if [ -f "${STORAGE_CONF}" ]; then
        if grep -q 'fuse-overlayfs' "${STORAGE_CONF}" 2>/dev/null; then
            ok "storage.conf already configured for fuse-overlayfs"
            STORAGE_OK=true
        else
            warn "storage.conf exists but doesn't reference fuse-overlayfs."
            echo "  Current contents of ${STORAGE_CONF}:"
            sed 's/^/    /' "${STORAGE_CONF}"
            echo ""
            echo "  Recommended contents:"
            echo '    [storage]'
            echo '    driver = "overlay"'
            echo '    [storage.options.overlay]'
            echo '    mount_program = "/usr/bin/fuse-overlayfs"'
            echo '    mountopt = "metacopy=on"'
            echo ""
            if ask_yn "Overwrite with recommended config?"; then
                cat > "${STORAGE_CONF}" <<'TOML'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "metacopy=on"
TOML
                ok "storage.conf updated"
                STORAGE_OK=true
            else
                warn "Skipped. You may need to configure this manually."
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "  No storage.conf found. This file tells podman to use fuse-overlayfs."
        if ask_yn "Create ${STORAGE_CONF}?" "y"; then
            mkdir -p "$(dirname "${STORAGE_CONF}")"
            cat > "${STORAGE_CONF}" <<'TOML'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "metacopy=on"
TOML
            ok "storage.conf created"
            STORAGE_OK=true
        else
            warn "Skipped. Without this, container startup will hang."
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    # ── 3c. containers.conf ──────────────────────────────────────────────────
    CONTAINERS_CONF="${HOME}/.config/containers/containers.conf"

    if [ -f "${CONTAINERS_CONF}" ]; then
        if grep -q 'init = false' "${CONTAINERS_CONF}" 2>/dev/null; then
            ok "containers.conf already disables catatonit"
        else
            warn "containers.conf exists but doesn't disable catatonit."
            echo "  On EL10, catatonit segfaults. Recommended: add 'init = false'."
            echo ""
            if ask_yn "Append [containers] init = false?"; then
                if ! grep -q '^\[containers\]' "${CONTAINERS_CONF}" 2>/dev/null; then
                    printf '\n[containers]\ninit = false\n' >> "${CONTAINERS_CONF}"
                else
                    sed -i '/^\[containers\]/a init = false' "${CONTAINERS_CONF}"
                fi
                ok "containers.conf updated"
            else
                warn "Skipped. If you see catatonit crashes, add this manually."
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        echo "  No containers.conf found. On EL10, catatonit (podman's init) segfaults."
        if ask_yn "Create ${CONTAINERS_CONF}?" "y"; then
            mkdir -p "$(dirname "${CONTAINERS_CONF}")"
            cat > "${CONTAINERS_CONF}" <<'TOML'
[containers]
init = false
TOML
            ok "containers.conf created"
        else
            warn "Skipped. If you see catatonit crashes, create this manually."
            WARNINGS=$((WARNINGS + 1))
        fi
    fi

    # ── 3d. podman system reset (if storage config changed) ──────────────────
    if [ "${STORAGE_OK}" = true ]; then
        # Check if the current storage driver matches the config
        CURRENT_DRIVER="$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "")"
        if [ -z "${CURRENT_DRIVER}" ]; then
            warn "Could not query podman storage driver (podman not fully functional)."
            echo "  After setup completes, verify with: podman info --format '{{.Store.GraphDriverName}}'"
            WARNINGS=$((WARNINGS + 1))
        elif [ "${CURRENT_DRIVER}" != "overlay" ]; then
            warn "Podman storage driver is '${CURRENT_DRIVER}', but config says 'overlay'."
            echo "  A storage reset is needed for the new config to take effect."
            echo "  This will remove all local podman images, containers, and volumes."
            echo ""
            if [ -n "${AUTO_YES}" ]; then
                warn "Skipped (--yes does not auto-approve destructive operations)."
                echo "  Run manually: podman system reset --force"
                WARNINGS=$((WARNINGS + 1))
            elif ask_yn "Run 'podman system reset --force'?"; then
                podman system reset --force
                ok "Podman storage reset complete"
            else
                warn "Skipped. You may need to run 'podman system reset --force' manually."
                WARNINGS=$((WARNINGS + 1))
            fi
        else
            ok "Podman storage driver is already 'overlay'"
        fi
    fi

    # ── 3e. Kernel metacopy (optional) ───────────────────────────────────────
    METACOPY_PATH="/sys/module/overlay/parameters/metacopy"
    if [ -f "${METACOPY_PATH}" ]; then
        METACOPY_CURRENT="$(cat "${METACOPY_PATH}" 2>/dev/null || echo "N")"
        if [ "${METACOPY_CURRENT}" = "Y" ]; then
            ok "Kernel overlay metacopy is enabled"
        else
            echo "  Kernel overlay metacopy is disabled. Enabling it improves overlay performance."
            if [ -n "${AUTO_YES}" ]; then
                ok "Skipped (--yes does not auto-approve sudo operations)"
            elif ask_yn "Enable kernel metacopy (requires sudo)?"; then
                echo "Y" | sudo tee "${METACOPY_PATH}" >/dev/null
                ok "Kernel metacopy enabled for this session"
                # Persist
                MODPROBE_CONF="/etc/modprobe.d/overlay.conf"
                if [ ! -f "${MODPROBE_CONF}" ] || ! grep -q 'metacopy=on' "${MODPROBE_CONF}" 2>/dev/null; then
                    if ask_yn "Persist across reboots (writes to ${MODPROBE_CONF})?"; then
                        echo "options overlay metacopy=on" | sudo tee "${MODPROBE_CONF}" >/dev/null
                        ok "Kernel metacopy persisted"
                    fi
                fi
            else
                ok "Skipped (optional optimization)"
            fi
        fi
    fi
else
    step "3. Podman configuration"
    ok "Skipped (using ${CONTAINER_CMD:-docker})"
fi

# ── 4. Authentication ───────────────────────────────────────────────────────
step "4. Claude authentication"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "ANTHROPIC_API_KEY is set"
elif [ -f "${HOME}/.claude.json" ]; then
    ok "OAuth tokens found (~/.claude.json)"
else
    warn "No authentication found."
    echo "  Either set ANTHROPIC_API_KEY in your environment, or run 'claude' on the"
    echo "  host to complete the OAuth flow (creates ~/.claude.json)."
    WARNINGS=$((WARNINGS + 1))
fi

# ── 5. Install CLI wrapper ──────────────────────────────────────────────────
step "5. Install CLI"

INSTALL_DIR="${HOME}/bin"
WRAPPER="${INSTALL_DIR}/claude-riotbox"

if [ -x "${WRAPPER}" ]; then
    # Check if the wrapper points to this repo
    if grep -q "${SCRIPT_DIR}" "${WRAPPER}" 2>/dev/null; then
        ok "claude-riotbox already installed (${WRAPPER})"
    else
        warn "claude-riotbox exists but points to a different location."
        if ask_yn "Reinstall from ${SCRIPT_DIR}?"; then
            "${SCRIPT_DIR}/install.sh" "${INSTALL_DIR}"
            ok "claude-riotbox reinstalled"
        fi
    fi
else
    echo "  This installs the 'claude-riotbox' command to ${INSTALL_DIR}/."
    if ask_yn "Install?" "y"; then
        if [ -z "${AUTO_YES}" ]; then
            read -rp "  Install directory [${INSTALL_DIR}]: " custom_dir
            INSTALL_DIR="${custom_dir:-${INSTALL_DIR}}"
        fi
        "${SCRIPT_DIR}/install.sh" "${INSTALL_DIR}"
        ok "claude-riotbox installed to ${INSTALL_DIR}"
    else
        warn "Skipped. Run ./install.sh manually when ready."
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# ── 6. Build image ──────────────────────────────────────────────────────────
step "6. Build container image"

IMAGE_NAME="${IMAGE_NAME:-claude-riotbox}"

if [ -n "${SKIP_BUILD}" ]; then
    ok "Skipped (--no-build)"
elif [ -n "${CONTAINER_CMD}" ] && ${CONTAINER_CMD} inspect "${IMAGE_NAME}" &>/dev/null; then
    ok "Image '${IMAGE_NAME}' already exists"
    if ask_yn "Rebuild anyway?"; then
        "${SCRIPT_DIR}/scripts/build.sh"
    fi
else
    if [ ${ERRORS} -gt 0 ]; then
        fail "Skipping build due to ${ERRORS} error(s) above. Fix them and re-run."
    elif [ -n "${CONTAINER_CMD}" ]; then
        echo "  The image build takes a while (installs toolchains, security tools, etc.)."
        if ask_yn "Build now?" "y"; then
            "${SCRIPT_DIR}/scripts/build.sh"
        else
            ok "Skipped. Run 'claude-riotbox build' when ready."
        fi
    else
        fail "No container runtime available. Cannot build."
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
step "Setup complete"

if [ ${ERRORS} -gt 0 ]; then
    fail "${ERRORS} error(s) need to be resolved. Fix them and re-run ./setup.sh."
    exit 1
elif [ ${WARNINGS} -gt 0 ]; then
    warn "${WARNINGS} warning(s). Things may work, but review the notes above."
else
    ok "Everything looks good!"
fi

echo ""
echo "Quick start:"
echo "  claude-riotbox run \"add tests for the auth module\""
echo "  claude-riotbox shell"
echo ""
