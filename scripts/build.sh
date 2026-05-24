#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Introspects your local environment and builds the RiotBox image.
# Can be run from anywhere; resolves paths relative to the project root.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-riotbox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="$(cat "${PROJECT_DIR}/VERSION" 2>/dev/null || echo "unknown")"

# Container runtime: prefer podman, fall back to docker
if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
else
    echo "ERROR: neither podman nor docker found in PATH" >&2
    exit 1
fi
echo "→ Container runtime: ${CONTAINER_CMD}"

echo "══════════════════════════════════════════════════════"
echo "  RiotBox v${VERSION} — environment introspection + build"
echo "══════════════════════════════════════════════════════"

# ── 1. Host UID/GID (so volume-mounted files have correct ownership) ──────────
# HOST_GID is captured separately from HOST_UID: on hosts where the user's
# primary GID differs from their UID (e.g., a manually-configured account
# whose primary group was created at a different gid), the image must be
# built with both, or podman keep-id's /etc/passwd rewrite races against
# nested-mode's userns setup and inner podman fails with EPERM on newgidmap.
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
echo "→ HOST_UID: ${HOST_UID}"
echo "→ HOST_GID: ${HOST_GID}"

# ── 2. nvm ────────────────────────────────────────────────────────────────────
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [ -s "${NVM_DIR}/nvm.sh" ]; then
    # shellcheck disable=SC1090
    source "${NVM_DIR}/nvm.sh" --no-use

    # nvm version
    NVM_INSTALLER_VERSION="$(nvm --version 2>/dev/null || echo "0.39.7")"

    # All installed Node versions (strip the 'v' prefix)
    NODE_VERSIONS="$(
        nvm ls --no-colors 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sed 's/^v//' \
        | sort -V \
        | uniq \
        | tr '\n' ' ' \
        | xargs
    )"

    # Default/current version
    NODE_DEFAULT="$(
        nvm version default 2>/dev/null | sed 's/^v//' || \
        nvm version current 2>/dev/null | sed 's/^v//' || \
        echo "20"
    )"

    echo "→ nvm installer: ${NVM_INSTALLER_VERSION}"
    echo "→ Node versions: ${NODE_VERSIONS}"
    echo "→ Node default:  ${NODE_DEFAULT}"
else
    echo "⚠️  nvm not found at ${NVM_DIR} — using Node 20 LTS as default"
    NVM_INSTALLER_VERSION="0.39.7"
    NODE_VERSIONS="20"
    NODE_DEFAULT="20"
fi

# ── 3. uv ─────────────────────────────────────────────────────────────────────
if command -v uv &>/dev/null; then
    UV_VERSION="$(uv --version 2>/dev/null | awk '{print $2}')"
    echo "→ uv version: ${UV_VERSION}"
else
    UV_VERSION="latest"
    echo "⚠️  uv not found locally — will install latest in container"
fi

# ── 4. Go ──────────────────────────────────────────────────────────────────
if command -v go &>/dev/null; then
    GO_VERSION="$(go version | awk '{print $3}' | sed 's/^go//')"
    echo "→ Go version: ${GO_VERSION}"
else
    GO_VERSION=""
    echo "⚠️  Go not found locally — skipping in container"
fi

# ── 5. Rust ────────────────────────────────────────────────────────────────
if command -v rustup &>/dev/null; then
    RUST_TOOLCHAINS="$(
        rustup toolchain list \
        | sed 's/-.*//' \
        | sort -V \
        | uniq \
        | tr '\n' ' ' \
        | xargs
    )"
    echo "→ Rust toolchains: ${RUST_TOOLCHAINS}"
else
    RUST_TOOLCHAINS=""
    echo "⚠️  rustup not found locally — skipping Rust in container (set RUST_TOOLCHAINS to override)"
fi

# ── 6. Ruby / RVM ─────────────────────────────────────────────────────────
if [ -s "${HOME}/.rvm/scripts/rvm" ]; then
    # shellcheck disable=SC1091
    # RVM scripts reference unbound variables and return non-zero exit codes
    # during normal operation; disable -e and -u for all rvm interactions
    set +eu
    source "${HOME}/.rvm/scripts/rvm" 2>/dev/null

    RUBY_VERSIONS="$(
        rvm list strings 2>/dev/null \
        | sed 's/^ruby-//' \
        | sort -V \
        | uniq \
        | tr '\n' ' ' \
        | xargs
    )"
    RUBY_DEFAULT="$(
        rvm alias show default 2>/dev/null | sed 's/^ruby-//' || echo "${RUBY_VERSIONS%% *}"
    )"
    set -eu
    echo "→ Ruby versions: ${RUBY_VERSIONS}"
    echo "→ Ruby default:  ${RUBY_DEFAULT}"
else
    RUBY_VERSIONS=""
    RUBY_DEFAULT=""
    echo "⚠️  RVM not found — skipping Ruby in container"
fi

# ── Writable build context ───────────────────────────────────────────────────
# build.sh must write configs/ into the Docker build context and pass that
# context to `${CONTAINER_CMD} build`. When RiotBox is installed system-wide
# (rpm/deb → /opt/riotbox, root-owned) the install tree is read-only for the
# user, so we stage a throwaway copy of the app tree in a writable temp dir and
# build from there. When PROJECT_DIR is writable (rootless install or the dev
# repo) we build in place exactly as before.
if [ -w "${PROJECT_DIR}" ]; then
    BUILD_CONTEXT="${PROJECT_DIR}"
else
    BUILD_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/riotbox-build.XXXXXX")"
    trap 'chmod -R u+w "${BUILD_CONTEXT}" 2>/dev/null; rm -rf "${BUILD_CONTEXT}"' EXIT
    cp -a "${PROJECT_DIR}/." "${BUILD_CONTEXT}/"
    # cp -a propagates the (read-only) source mode onto the staging copy; force
    # it writable so configs/ regeneration and cleanup work regardless of the
    # install tree's permissions.
    chmod -R u+w "${BUILD_CONTEXT}"
    echo "→ Install tree is read-only; staging build context at ${BUILD_CONTEXT}"
fi

# ── 7. Collect tool configs into configs/ (never secrets) ─────────────────────
CONFIGS_DIR="${BUILD_CONTEXT}/configs"
rm -rf "${CONFIGS_DIR}"
mkdir -p "${CONFIGS_DIR}"

copy_if_exists() {
    local src="$1" dst_name="$2"
    if [ -f "${src}" ]; then
        mkdir -p "${CONFIGS_DIR}/$(dirname "${dst_name}")"
        cp "${src}" "${CONFIGS_DIR}/${dst_name}"
        echo "  ✓ ${src} → configs/${dst_name}"
    fi
}

# Copy a config file, stripping lines matching a credential pattern.
# Usage: strip_and_copy <src> <dst_name> <grep-extended-pattern>
strip_and_copy() {
    local src="$1" dst_name="$2" pattern="$3"
    if [ -f "${src}" ]; then
        mkdir -p "${CONFIGS_DIR}/$(dirname "${dst_name}")"
        grep -vE "${pattern}" "${src}" > "${CONFIGS_DIR}/${dst_name}" 2>/dev/null || true
        echo "  ✓ ${src} → configs/${dst_name} (credentials stripped)"
    fi
}

echo "→ Collecting tool configs..."
# .npmrc: strip auth tokens — never bake registry credentials into the image
strip_and_copy "${HOME}/.npmrc" ".npmrc" '(_authToken|_auth|_password)='
# pip.conf: strip passwords and client certs
strip_and_copy "${HOME}/.pip/pip.conf" ".pip/pip.conf" '^\s*(password|client.cert)\s*='
strip_and_copy "${HOME}/.config/pip/pip.conf" ".config/pip/pip.conf" '^\s*(password|client.cert)\s*='
# .gitconfig is intentionally NOT copied — it often contains GPG signing,
# credential helpers, and user identity that don't belong in the riotbox.
# Git settings are configured in container/entrypoint.sh instead.
copy_if_exists "${HOME}/.gitignore_global"   ".gitignore_global"
copy_if_exists "${HOME}/.editorconfig"       ".editorconfig"
copy_if_exists "${HOME}/.ripgreprc"          ".ripgreprc"
# cargo config: strip registry tokens
strip_and_copy "${HOME}/.cargo/config.toml" ".cargo/config.toml" '^\s*token\s*='

# uv config
if [ -f "${HOME}/.config/uv/uv.toml" ]; then
    mkdir -p "${CONFIGS_DIR}/.config/uv"
    cp "${HOME}/.config/uv/uv.toml" "${CONFIGS_DIR}/.config/uv/uv.toml"
    echo "  ✓ ~/.config/uv/uv.toml → configs/.config/uv/uv.toml"
fi

# Ensure COPY in Dockerfile never fails on an empty dir
touch "${CONFIGS_DIR}/.keep"

# ── 8. Docker build ───────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Building image: ${IMAGE_NAME}"
echo "══════════════════════════════════════════════════════"

# shellcheck disable=SC2086  # intentional word splitting for extra args
${CONTAINER_CMD} build \
    ${DOCKER_EXTRA_ARGS:-} \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.title=riotbox" \
    --build-arg "HOST_UID=${HOST_UID}" \
    --build-arg "HOST_GID=${HOST_GID}" \
    --build-arg "NVM_INSTALLER_VERSION=${NVM_INSTALLER_VERSION}" \
    --build-arg "NODE_VERSIONS=${NODE_VERSIONS}" \
    --build-arg "NODE_DEFAULT=${NODE_DEFAULT}" \
    --build-arg "UV_VERSION=${UV_VERSION}" \
    --build-arg "GO_VERSION=${GO_VERSION}" \
    --build-arg "RUST_TOOLCHAINS=${RUST_TOOLCHAINS}" \
    --build-arg "RUBY_VERSIONS=${RUBY_VERSIONS}" \
    --build-arg "RUBY_DEFAULT=${RUBY_DEFAULT}" \
    --progress=plain \
    -t "${IMAGE_NAME}" \
    "${BUILD_CONTEXT}"

echo ""
echo "✅  Done. Image '${IMAGE_NAME}' is ready."
echo ""
echo "Quick start:"
echo "  riotbox run \"implement the feature in SPEC.md\""
echo "  riotbox shell"
