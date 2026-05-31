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

if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
	# shellcheck disable=SC1090,SC1091
	source "${NVM_DIR}/nvm.sh" --no-use

	# nvm version
	NVM_INSTALLER_VERSION="$(nvm --version 2>/dev/null || echo "0.39.7")"

	# All installed Node versions (strip the 'v' prefix)
	ALL_NODE_VERSIONS="$(
		nvm ls --no-colors 2>/dev/null |
			grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
			sed 's/^v//' |
			sort -V |
			uniq |
			tr '\n' ' ' |
			xargs
	)"

	# Default/current version
	NODE_DEFAULT="$(
		nvm version default 2>/dev/null | sed 's/^v//' ||
			nvm version current 2>/dev/null | sed 's/^v//' ||
			echo "20"
	)"

	# Cap the set baked into the image. Each installed Node version is a
	# fresh ~80 MB layer plus npm cache; a user with a decade of legacy
	# projects can easily have 16 versions on their host, and including
	# them all blows the image past 11 GB and the build past an hour.
	# Default: keep the N latest distinct majors plus the default. The
	# user opts in to the full list with NODE_VERSIONS_MAX=all.
	NODE_VERSIONS_MAX="${NODE_VERSIONS_MAX:-3}"
	if [[ "${NODE_VERSIONS_MAX}" = "all" ]]; then
		NODE_VERSIONS="${ALL_NODE_VERSIONS}"
	else
		# Group by major version, keep the latest patch in each, take the
		# newest N majors plus the default. Awk handles the grouping in a
		# single pass over the sorted list to avoid spawning more shells.
		NODE_VERSIONS="$(
			printf '%s\n' "${ALL_NODE_VERSIONS}" | tr ' ' '\n' |
				awk -F. '
					NF >= 1 && $1 != "" {
						# Track the latest version per major (input is
						# already sort -V ascending, so the last seen
						# entry for each major is the winner).
						by_major[$1] = $0
					}
					END {
						# Emit majors descending, take top N.
						n = 0
						for (m in by_major) majors[++n] = m+0
						# Simple descending sort on majors[].
						for (i = 1; i <= n; i++) {
							for (j = i+1; j <= n; j++) {
								if (majors[j] > majors[i]) {
									t = majors[i]; majors[i] = majors[j]; majors[j] = t
								}
							}
						}
						limit = (n < '"${NODE_VERSIONS_MAX}"') ? n : '"${NODE_VERSIONS_MAX}"'
						for (i = 1; i <= limit; i++) print by_major[majors[i]]
					}
				' | tr '\n' ' ' | xargs
		)"
		# Always include the default version (it may be in an older major
		# the cap dropped — keep it so `node` without nvm switching works).
		if [[ -n "${NODE_DEFAULT}" ]] && [[ " ${NODE_VERSIONS} " != *" ${NODE_DEFAULT} "* ]]; then
			NODE_VERSIONS="${NODE_VERSIONS} ${NODE_DEFAULT}"
		fi
	fi

	echo "→ nvm installer:        ${NVM_INSTALLER_VERSION}"
	echo "→ Node versions (host): ${ALL_NODE_VERSIONS}"
	if [[ "${NODE_VERSIONS}" != "${ALL_NODE_VERSIONS}" ]]; then
		echo "→ Node versions (image, capped at ${NODE_VERSIONS_MAX}): ${NODE_VERSIONS}"
		echo "  (set NODE_VERSIONS_MAX=all to include every host version)"
	else
		echo "→ Node versions (image): ${NODE_VERSIONS}"
	fi
	echo "→ Node default:         ${NODE_DEFAULT}"
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
		rustup toolchain list |
			sed 's/-.*//' |
			sort -V |
			uniq |
			tr '\n' ' ' |
			xargs
	)"
	echo "→ Rust toolchains: ${RUST_TOOLCHAINS}"
else
	RUST_TOOLCHAINS=""
	echo "⚠️  rustup not found locally — skipping Rust in container (set RUST_TOOLCHAINS to override)"
fi

# ── 6. Ruby / RVM ─────────────────────────────────────────────────────────
if [[ -s "${HOME}/.rvm/scripts/rvm" ]]; then
	# RVM scripts reference unbound variables and return non-zero exit codes
	# during normal operation; disable -e and -u for all rvm interactions
	set +eu
	# shellcheck disable=SC1091
	source "${HOME}/.rvm/scripts/rvm" 2>/dev/null

	RUBY_VERSIONS="$(
		rvm list strings 2>/dev/null |
			sed 's/^ruby-//' |
			sort -V |
			uniq |
			tr '\n' ' ' |
			xargs
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
if [[ -w "${PROJECT_DIR}" ]]; then
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
	if [[ -f "${src}" ]]; then
		mkdir -p "${CONFIGS_DIR}/$(dirname "${dst_name}")"
		cp "${src}" "${CONFIGS_DIR}/${dst_name}"
		echo "  ✓ ${src} → configs/${dst_name}"
	fi
}

# Copy a config file, stripping lines matching a credential pattern.
# Usage: strip_and_copy <src> <dst_name> <grep-extended-pattern>
strip_and_copy() {
	local src="$1" dst_name="$2" pattern="$3"
	if [[ -f "${src}" ]]; then
		mkdir -p "${CONFIGS_DIR}/$(dirname "${dst_name}")"
		grep -vE "${pattern}" "${src}" >"${CONFIGS_DIR}/${dst_name}" 2>/dev/null || true
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
copy_if_exists "${HOME}/.gitignore_global" ".gitignore_global"
copy_if_exists "${HOME}/.editorconfig" ".editorconfig"
copy_if_exists "${HOME}/.ripgreprc" ".ripgreprc"
# cargo config: strip registry tokens
strip_and_copy "${HOME}/.cargo/config.toml" ".cargo/config.toml" '^\s*token\s*='

# uv config
if [[ -f "${HOME}/.config/uv/uv.toml" ]]; then
	mkdir -p "${CONFIGS_DIR}/.config/uv"
	cp "${HOME}/.config/uv/uv.toml" "${CONFIGS_DIR}/.config/uv/uv.toml"
	echo "  ✓ ~/.config/uv/uv.toml → configs/.config/uv/uv.toml"
fi

# Ensure COPY in Containerfile never fails on an empty dir
touch "${CONFIGS_DIR}/.keep"

# ── 8. Pre-build summary ──────────────────────────────────────────────────────
# The build can run for an hour and produce an 11 GB image when the host has
# a long nvm history + Rust + Ruby. Print a one-screen summary so a fresh
# user can see what's going to be installed and bail out (^C) before the
# long step kicks off. Skipped under RIOTBOX_NONINTERACTIVE_BUILD=1, used by
# CI and the rpm/deb post-install path.
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Build plan — review before continuing"
echo "══════════════════════════════════════════════════════"
echo "  Image:           ${IMAGE_NAME}"
echo "  Runtime:         ${CONTAINER_CMD}"
echo "  Node versions:   ${NODE_VERSIONS:-(none)}"
echo "  Node default:    ${NODE_DEFAULT:-(none)}"
echo "  uv:              ${UV_VERSION}"
echo "  Go:              ${GO_VERSION:-(skipped — not on host)}"
echo "  Rust toolchains: ${RUST_TOOLCHAINS:-(skipped — not on host)}"
echo "  Ruby versions:   ${RUBY_VERSIONS:-(skipped — set RUBY_VERSIONS or install RVM to enable)}"
echo "  Diagram tools:   $([ "${RIOTBOX_DIAGRAMS:-0}" = "1" ] && echo "chromium + mmdc (opt-in)" || echo "(skipped — set RIOTBOX_DIAGRAMS=1 to include)")"
echo ""
echo "  Expected runtime: 15–60 min on a clean host. Heavier with many"
echo "  Node versions, full Rust toolchains, or RVM Ruby builds (compiled"
echo "  from source). Expected image size: 4–11 GB depending on toolchain"
echo "  selection. Subsequent builds reuse layer cache and are much faster."
echo ""

if [[ -z "${RIOTBOX_NONINTERACTIVE_BUILD:-}" ]] && [[ -t 0 ]]; then
	printf "  Proceed with build? [Y/n] "
	read -r _proceed || _proceed=""
	if [[ "${_proceed}" =~ ^[Nn] ]]; then
		echo "  Aborted by user." >&2
		exit 1
	fi
fi

# ── 9. Container build ────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Building image: ${IMAGE_NAME}"
echo "══════════════════════════════════════════════════════"

# Image format defaults to whatever the runtime picks (podman: OCI,
# docker: docker v2s2). The Containerfile achieves pipefail via explicit
# `bash -o pipefail -c` in each RUN that uses pipes, not via the
# Dockerfile-only SHELL directive — that way nothing has to override the
# format to silence "SHELL is not supported for OCI image format".

# shellcheck disable=SC2086  # intentional word splitting for extra args
${CONTAINER_CMD} build \
	${CONTAINER_EXTRA_ARGS:-} \
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
	--build-arg "RIOTBOX_DIAGRAMS=${RIOTBOX_DIAGRAMS:-0}" \
	--build-arg "LLM_TOOL_UPDATE=${LLM_TOOL_UPDATE:-0}" \
	--progress=plain \
	-t "${IMAGE_NAME}" \
	-f "${BUILD_CONTEXT}/Containerfile" \
	"${BUILD_CONTEXT}"

echo ""
echo "✅  Done. Image '${IMAGE_NAME}' is ready."
echo ""
echo "Quick start:"
echo "  riotbox run \"implement the feature in SPEC.md\""
echo "  riotbox shell"
