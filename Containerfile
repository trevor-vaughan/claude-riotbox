# ─────────────────────────────────────────────────────────────────────────────
# RiotBox — CentOS Stream 10
# Built to mirror your host dev environment (nvm, uv, Go, Rust, Ruby).
# Secrets (ANTHROPIC_API_KEY, ~/.claude) are NEVER baked in — mount at runtime.
#
# Multi-stage build:
#   tools   — downloads standalone binaries (trivy, grype, syft, task, venom)
#   runtime — final image with toolchains + copied binaries
# ─────────────────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# Stage 1: Download standalone tool binaries
# ═════════════════════════════════════════════════════════════════════════════
# Pinned for supply-chain integrity. To refresh:
#   podman pull quay.io/centos/centos:stream10
#   podman image inspect quay.io/centos/centos:stream10 \
#     --format '{{index .RepoDigests 0}}'
# Both `FROM` lines (tools + runtime) MUST reference the same digest so the
# binaries baked in the tools stage match the libc they will be COPYed onto
# in runtime.
FROM quay.io/centos/centos:stream10 AS tools

# Pipefail policy: RUN steps that pipe (`curl ... | sh`) explicitly invoke
# `bash -o pipefail -c '…'` rather than using a Dockerfile `SHELL` directive.
# SHELL only works for image-config formats that have a Shell field — OCI
# does not — and emits a "SHELL is not supported for OCI image format"
# warning at every step. Inline bash invocations keep the image OCI
# compliant, no manifest-format override needed.

# DL3041: Stream 10 is a rolling distribution — exact package versions shift
# between releases. Pinning every rpm to a specific EVR would break on the next
# compose. The FROM digest (set at the top of this file) pins the base layer.
# hadolint ignore=DL3041
RUN dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        curl tar gzip bash && \
    dnf clean all && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc

WORKDIR /tools

# trivy — vulnerability scanner
RUN bash -o pipefail -c '\
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
        | sh -s -- -b /tools/bin && \
    /tools/bin/trivy --version'

# grype — vulnerability scanner for SBOMs
RUN bash -o pipefail -c '\
    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh \
        | sh -s -- -b /tools/bin && \
    /tools/bin/grype version'

# syft — SBOM generator (pairs with grype)
RUN bash -o pipefail -c '\
    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
        | sh -s -- -b /tools/bin && \
    /tools/bin/syft version'

# task — task runner for Taskfiles (https://taskfile.dev)
RUN bash -o pipefail -c '\
    curl -sL https://taskfile.dev/install.sh | sh -s -- -b /tools/bin && \
    /tools/bin/task --version'

# venom — integration test framework (https://github.com/ovh/venom)
# Pinned per supply-chain review. Upstream publishes no checksums or
# signatures, so we self-compute and verify SHA256 per arch. To refresh:
#   1. Pick a new tag at https://github.com/ovh/venom/releases (stable only)
#   2. Compute SHA256 for amd64 + arm64. Download to a file and hash the file,
#      rather than piping curl into sha256sum: `curl -sL` without -f prints a
#      404 body to stdout and exits 0, so the pipe would happily hash GitHub's
#      error page and produce a digest that pins nothing. -f turns the HTTP
#      error into a non-zero exit and && stops before anything is hashed.
#        for a in amd64 arm64; do
#          curl -fsSLo "/tmp/venom.$a" \
#            "https://github.com/ovh/venom/releases/download/<TAG>/venom.linux-$a" &&
#            sha256sum "/tmp/venom.$a" | awk '{print $1}'
#        done
#   3. Update VENOM_VERSION + VENOM_SHA256_AMD64 + VENOM_SHA256_ARM64 below
ARG VENOM_VERSION=v1.3.0
ARG VENOM_SHA256_AMD64=89832ec25e820c605cf0d3c09122e60bad43d13c1724aa6d375ef7109fbfe201
ARG VENOM_SHA256_ARM64=aada8ac76cb642daecbc8e31e830c94c42bcdd78fecd3a9d9d1a73c37c60d946
RUN bash -o pipefail -c '\
    ARCH=$(uname -m | sed "s/x86_64/amd64/" | sed "s/aarch64/arm64/") && \
    case "${ARCH}" in \
        amd64) EXPECTED_SHA="${VENOM_SHA256_AMD64}" ;; \
        arm64) EXPECTED_SHA="${VENOM_SHA256_ARM64}" ;; \
        *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/venom "https://github.com/ovh/venom/releases/download/${VENOM_VERSION}/venom.linux-${ARCH}" && \
    echo "${EXPECTED_SHA}  /tmp/venom" | sha256sum -c - && \
    mv /tmp/venom /tools/bin/venom && \
    chmod +x /tools/bin/venom && \
    /tools/bin/venom version'

# ── git-ai (AI-authorship attribution via git notes) ─────────────────────────
# The release asset, not https://usegitai.com/install.sh: RIOTBOX-20260312-001
# asks every download in this image for download-then-verify against a pinned
# SHA256, which a piped installer cannot give. The installer would also drop the
# binary in ~/.git-ai/bin — the exact directory scripts/mount-projects.sh turns
# into a session bind mount, so the mount would shadow the binary at runtime.
# /tools/bin is where venom, task, trivy, grype and syft already land, and the
# COPY --from=tools below places the whole directory at ~/.local/bin, which is
# also where upstream's own installer symlinks git-ai.
#
# Upstream publishes SHA256SUMS per release, so the digests below are
# transcribed from it rather than self-computed. As with bun, they are
# transcribed at review time, not fetched beside the artifact at build time: a
# checksum pulled from the same place as the file it describes, in the same
# build, proves only that the two agree. What the pin buys is narrower than
# "verified" suggests — it catches the bytes behind a fixed tag changing after
# transcription. It cannot notice a release already compromised at the moment of
# transcription.
#
# Note the arch translation. The tools stage normalises uname -m to amd64/arm64
# for venom, but upstream names its assets git-ai-linux-x64 and
# git-ai-linux-arm64 — so amd64 has to be translated back or the URL 404s.
#
# To refresh:
#   1. Pick a new tag at https://github.com/git-ai-project/git-ai/releases
#   2. Read the digests for both assets out of upstream's checksum file:
#      curl -fsSL https://github.com/git-ai-project/git-ai/releases/download/v<VER>/SHA256SUMS \
#        | grep -E 'git-ai-linux-(x64|arm64)$'
#   3. Update GIT_AI_VERSION + GIT_AI_SHA256_AMD64 + GIT_AI_SHA256_ARM64 below
ARG GIT_AI_VERSION=v1.7.4
ARG GIT_AI_SHA256_AMD64=1f80c4affa44d9a21667e930b7aa6ac94f7c2f46bf216d7664bab84c7a8b62c2
ARG GIT_AI_SHA256_ARM64=d6972d11dda038ac5ba245ac91e0f6a1cbcbe5eec136f0578c91b81ec908a0ac
RUN bash -o pipefail -c '\
    ARCH=$(uname -m | sed "s/x86_64/amd64/" | sed "s/aarch64/arm64/") && \
    case "${ARCH}" in \
        amd64) EXPECTED_SHA="${GIT_AI_SHA256_AMD64}"; ASSET_ARCH="x64" ;; \
        arm64) EXPECTED_SHA="${GIT_AI_SHA256_ARM64}"; ASSET_ARCH="arm64" ;; \
        *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/git-ai "https://github.com/git-ai-project/git-ai/releases/download/${GIT_AI_VERSION}/git-ai-linux-${ASSET_ARCH}" && \
    echo "${EXPECTED_SHA}  /tmp/git-ai" | sha256sum -c - && \
    mv /tmp/git-ai /tools/bin/git-ai && \
    chmod +x /tools/bin/git-ai && \
    /tools/bin/git-ai --version'


# ═════════════════════════════════════════════════════════════════════════════
# Stage 2: Runtime image
# ═════════════════════════════════════════════════════════════════════════════
# Pinned to the same digest as the tools stage. See refresh procedure at the
# top of the tools stage; both `FROM` lines must move together.
FROM quay.io/centos/centos:stream10 AS runtime

# Pipefail policy: see the tools stage's comment. RUN steps that pipe
# wrap themselves in `bash -o pipefail -c '…'` instead of relying on a
# Dockerfile SHELL directive (which OCI image config doesn't support).

# ── Build args (populated by build.sh from host introspection) ────────────────
ARG NVM_INSTALLER_VERSION=0.40.7
ARG NODE_VERSIONS="20"
ARG NODE_DEFAULT="20"
ARG UV_VERSION="latest"
ARG GO_VERSION=""
# RUST_TOOLCHAINS=""  → skip Rust entirely (saves ~1.4 GB).
# RUST_TOOLCHAINS="stable 1.83.0 …" → install the listed toolchains; the first
# becomes default. build.sh detects what's installed on the host; if rustup
# isn't on the host, build.sh leaves this empty and Rust is not baked in.
ARG RUST_TOOLCHAINS=""
# Ruby is OFF by default: it has no stock dnf binary at the modern versions
# RVM ships (compiled from source, ~4 min of CPU time) and most users don't
# need it baked in. build.sh sets RUBY_VERSIONS from the host's RVM and
# leaves it empty when no RVM is installed, so "no Ruby on host" → "no
# Ruby in container" automatically. Set RUBY_VERSIONS="3.2.9" explicitly
# (e.g. `RIOTBOX_RUBY=3.2.9 task build`) to install without RVM on host.
ARG RUBY_VERSIONS=""
ARG RUBY_DEFAULT=""
ARG HOST_UID=1000
# Default HOST_GID to HOST_UID for the common case where the host user's
# primary GID matches their UID (useradd's stock behavior on most distros).
# Users whose primary GID differs from their UID — e.g., a host where
# groupadd allocated a separate user-private-group at a different gid — must
# pass HOST_GID=$(id -g) at build time. build.sh does this automatically;
# the default exists so direct `podman build` invocations still work.
ARG HOST_GID=${HOST_UID}

# ── System packages ───────────────────────────────────────────────────────────
# Combined into one layer to avoid intermediate bloat from dnf metadata.
#
# Size hygiene:
#   --setopt=install_weak_deps=False  skip Recommends/Suggests (fonts, X11 deps
#                                     pulled in by chromium, etc.)
#   --setopt=tsflags=nodocs           skip man pages, info files, locale data
#   rm -rf ...                        nuke dnf cache, logs, residual docs
# `dnf -y update` is deliberately omitted — stream10 is a rolling base, so the
# image digest is already current. Running update on top just shadows files
# from the base layer with newer copies, ballooning the image.
#
# Diagram tools (chromium + mermaid-cli) are off by default to keep the
# image lean. Chromium itself is ~400 MB plus 200+ multimedia codec
# dependencies pulled in transitively. Set RIOTBOX_DIAGRAMS=1 at build
# time to opt in (e.g. `RIOTBOX_DIAGRAMS=1 riotbox build`). The opt-in
# is read in two places: here (chromium rpm) and at the npm install
# block further down (mmdc).
ARG RIOTBOX_DIAGRAMS=0

# DL3041: Stream 10 is a rolling distribution — exact package versions shift
# between releases; pinning every rpm EVR would break on each compose.
# CKV2_DOCKER_1: sudo is intentional — this is a developer-environment image;
# the llm user is granted NOPASSWD sudo for dev workflows (see sudoers.d/llm).
#checkov:skip=CKV2_DOCKER_1:intentional: dev-environment image provisions NOPASSWD sudo for the llm developer user
# hadolint ignore=DL3041
RUN dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        bash \
        curl \
        wget \
        git \
        git-lfs \
        make \
        gcc \
        gcc-c++ \
        ncurses \
        python3 \
        python3-pip \
        python3-devel \
        openssl-devel \
        zlib-devel \
        bzip2-devel \
        readline-devel \
        sqlite-devel \
        libffi-devel \
        xz-devel \
        openssh-clients \
        tar \
        gzip \
        unzip \
        xz \
        which \
        procps-ng \
        findutils \
        diffutils \
        jq \
        libatomic \
        patch \
        sudo \
        dnf-plugins-core \
        gnupg2 \
    && dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
           epel-release \
    && dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
           ripgrep bats \
    && if [ "${RIOTBOX_DIAGRAMS}" = "1" ]; then \
           dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
               chromium; \
       fi \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info

# ── Common dev libraries (pre-installed to save Claude from installing them) ──
# Separated from base system packages for cache clarity.
# hadolint ignore=DL3041
RUN /usr/bin/crb enable && \
    dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        autoconf \
        automake \
        bison \
        bzip2 \
        cmake \
        file \
        libtool \
        pkgconf-pkg-config \
        ShellCheck \
        tree \
        bc \
        libcurl-devel \
        libxml2-devel \
        pcre2-devel \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info

# ── Ruby build dependencies (needed by RVM to compile Ruby from source) ──────
# hadolint ignore=DL3041
RUN if [ -n "${RUBY_VERSIONS}" ]; then \
        dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
            libyaml-devel ruby \
        && dnf clean all \
        && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info; \
    fi

# ── Go (system package, if version specified) ────────────────────────────────
# hadolint ignore=DL3041
RUN if [ -n "${GO_VERSION}" ]; then \
        dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
            golang \
        && dnf clean all \
        && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info \
        && go version; \
    fi

# ── Podman-in-podman (nested containers) ──────────────────────────────────────
# Pre-installed so RIOTBOX_NESTED=1 works without rebuilding the image.
# slirp4netns provides rootless networking; fuse-overlayfs for storage.
# hadolint ignore=DL3041
RUN dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        podman fuse-overlayfs slirp4netns \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info

# ── semgrep (Python package — must be installed in the runtime stage) ─────────
# DL3013: semgrep has a large dependency graph; pinning every transitive dep
# is impractical here. The image digest pins the base, and semgrep itself is
# tested at build time (semgrep --version). Use a requirements file for prod.
# hadolint ignore=DL3013
RUN pip3 install --no-cache-dir --break-system-packages semgrep pyyaml && \
    semgrep --version && \
    rm -rf /root/.cache/pip

# ── lola — AI Skills Package Manager (https://github.com/LobsterTrap/lola) ────
# `lola-ai` requires Python >=3.13, but the base ships Python 3.12. Install a
# parallel 3.13 interpreter from EPEL (enabled in the system-packages RUN
# block above) and use its pip. Entry points land in /usr/local/bin/lola,
# which is already on PATH for both root and the llm user. Pinned for
# supply-chain integrity; refresh by bumping LOLA_VERSION below after picking
# a new release at https://github.com/LobsterTrap/lola/releases.
ARG LOLA_VERSION=0.7.1
# hadolint ignore=DL3041
RUN dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        python3.13 python3.13-pip \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info \
    && pip3.13 install --no-cache-dir --break-system-packages \
        "lola-ai==${LOLA_VERSION}" \
    && lola --version \
    && rm -rf /root/.cache/pip

# ── Non-root user + root-phase config ─────────────────────────────────────────
# User creation, dnf config, and system prompt dir. The chown -R happens later
# (after COPY/pip that create root-owned dirs under /home/llm).
RUN (groupadd -g ${HOST_GID} llm && \
     useradd -l -m -u ${HOST_UID} -g llm -s /bin/bash llm) 2>/dev/null || \
    useradd -l -m -s /bin/bash llm && \
    mkdir -p /workspace && chown llm /workspace && \
    echo "llm ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/llm && \
    # /etc/subuid and /etc/subgid are rewritten at runtime by
    # container/nested-podman-setup.sh based on /proc/self/uid_map. Any
    # static range we bake here would point to outer UIDs that aren't
    # mapped into the --userns=keep-id namespace, and the kernel would
    # reject newuidmap with EPERM. Leave whatever useradd put there;
    # entrypoint will overwrite it when RIOTBOX_NESTED=1.
    # dnf non-interactive by default
    mkdir -p /etc/dnf/dnf.conf.d && \
    printf '[main]\nassumeyes=True\n' > /etc/dnf/dnf.conf.d/riotbox.conf && \
    # System prompt template in /etc/riotbox (root-owned, immutable at runtime).
    # Pre-rendered at build time into /etc/claude-code/ (the managed policy path
    # that Claude Code reads automatically and cannot be excluded).
    # Build-time rendering avoids runtime writes to /etc/ inside the container,
    # which would cause SELinux AVC denials (container_t writing to etc_t).
    mkdir -p /etc/riotbox /etc/claude-code && \
    chown llm:llm /etc/claude-code

COPY container/AGENTS.md /etc/riotbox/AGENTS.md
RUN . /etc/os-release && \
    awk -v os="${PRETTY_NAME:-Linux}" \
        '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        /etc/riotbox/AGENTS.md > /etc/claude-code/CLAUDE.md && \
    chown llm:llm /etc/claude-code/CLAUDE.md && \
    mkdir -p /home/llm/.riotbox && \
    awk -v os="${PRETTY_NAME:-Linux}" \
        '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        /etc/riotbox/AGENTS.md > /home/llm/.riotbox/AGENTS.md.template && \
    chown -R llm:llm /home/llm/.riotbox

# ── Strip non-English locale data ────────────────────────────────────────────
# This is a non-interactive automation container; we don't need locale data
# for 200 other languages. Keep en* (covers en_US, en_GB, etc.).
RUN find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' \
        -exec rm -rf {} + 2>/dev/null || true

# ── Security tools + task/venom from builder stage ───────────────────────────
COPY --from=tools --chown=llm:llm /tools/bin/ /home/llm/.local/bin/

# ── Fixed paths (set after useradd so HOME points to the real user dir) ──────
ENV HOME=/home/llm
ENV NVM_DIR=/home/llm/.nvm
ENV GOPATH=/home/llm/go
ENV PATH=/home/llm/.riotbox/bin:/home/llm/.local/bin:/home/llm/.cargo/bin:/home/llm/go/bin:/usr/lib/golang/bin:/home/llm/bin:${PATH}

# ── Workaround uv and SELinux issuees ──────────────────────────────────────────
ENV UV_LINK_MODE=hardlink

# ── Riotbox Detection  ─────────────────────────────────────────────────────────
ENV RIOTBOX=1

# ── Headroom telemetry opt-out ────────────────────────────────────────────────
# headroom's anonymous usage beacon defaults to ON (headroom/telemetry/
# beacon.py); permanent image-wide opt-out, in line with DO_NOT_TRACK and
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC set by the entrypoint.
ENV HEADROOM_TELEMETRY=off

# ── CodeGraph telemetry opt-out ───────────────────────────────────────────────
# CodeGraph's telemetry also defaults to ON. Its resolution order is
# DO_NOT_TRACK > CODEGRAPH_TELEMETRY > stored config > default on, and this is
# the middle of three layers: the entrypoint exports DO_NOT_TRACK=1 (which also
# disables its update check) and the install layer below persists the choice to
# ~/.codegraph/telemetry.json.
ENV CODEGRAPH_TELEMETRY=0

# Fix ownership after root-stage COPY that creates dirs under /home/llm.
RUN chown -R llm:llm /home/llm

USER llm
WORKDIR /home/llm

# ── nvm ───────────────────────────────────────────────────────────────────────
# bash -o pipefail: if curl fails or hits a 404 page that pipes through to
# bash, we want the install to error out, not silently succeed.
RUN bash -o pipefail -c '\
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_INSTALLER_VERSION}/install.sh" \
        | bash'

# Install every Node version detected on the host, then set the default
# hadolint ignore=SC2016
RUN set -e; echo '#!/usr/bin/env bash' > /tmp/install-node.sh; \
    echo 'set -e' >> /tmp/install-node.sh; \
    echo 'source ${NVM_DIR}/nvm.sh' >> /tmp/install-node.sh; \
    for v in ${NODE_VERSIONS}; do \
        echo "nvm install $v" >> /tmp/install-node.sh; \
    done; \
    echo "nvm alias default ${NODE_DEFAULT}" >> /tmp/install-node.sh; \
    echo 'nvm use default && node --version && npm --version' >> /tmp/install-node.sh; \
    bash /tmp/install-node.sh; rm /tmp/install-node.sh

# Add default node to PATH so npm/claude are available in non-interactive shells
ENV PATH=/home/llm/.nvm/versions/node/v${NODE_DEFAULT}/bin:${PATH}

# ── uv (pins to the version detected on the host) ────────────────────────────
RUN bash -o pipefail -c '\
    if [ "${UV_VERSION}" = "latest" ]; then \
        curl -LsSf https://astral.sh/uv/install.sh | bash; \
    else \
        curl -LsSf https://astral.sh/uv/install.sh | UV_TOOL_VERSION="${UV_VERSION}" bash; \
    fi && \
    /home/llm/.local/bin/uv --version'

# ── Rust (via rustup) + cargo-binstall for pre-built binaries ────────────────
# Conditional: when RUST_TOOLCHAINS is empty (the default), skip the whole
# rustup install. This saves ~1.4 GB for users who don't need Rust in-container.
# The first toolchain in the space-separated list becomes the rustup default.
# Wrapped in `bash -o pipefail -c` so both pipes (rustup-init | sh and the
# cargo-binstall curl | tar xz) abort on the upstream curl failing — without
# pipefail, a 4xx HTML page piped to sh/tar succeeds and we ship a broken bin.
RUN bash -o pipefail -c 'if [ -n "${RUST_TOOLCHAINS}" ]; then \
        set -- ${RUST_TOOLCHAINS}; \
        RUST_DEFAULT_TC="$1"; \
        curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain "${RUST_DEFAULT_TC}" && \
        source /home/llm/.cargo/env && \
        for tc in ${RUST_TOOLCHAINS}; do \
            echo "==> rustup install $tc" && \
            rustup toolchain install "$tc"; \
        done && \
        rustc --version && cargo --version && \
        ARCH=$(uname -m) && \
        curl -LSfs "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-${ARCH}-unknown-linux-musl.tgz" \
            | tar xz -C /home/llm/.cargo/bin && \
        cargo binstall --no-confirm ast-grep && sg --version; \
    fi'
# TODO(security): cargo-binstall publishes .sig files (minisign) but uses
#   ephemeral keys per release — no stable public key to verify against.

# ── Ruby (via RVM, if versions specified) ────────────────────────────────
# GPG keys must be imported before RVM's installer will pass signature checks.
# pipefail matters: `curl https://get.rvm.io | bash -s stable` must abort if
# curl fails — otherwise an empty body would pipe to bash and silently no-op.
RUN bash -o pipefail -c 'if [ -n "${RUBY_VERSIONS}" ]; then \
        gpg2 --keyserver hkps://keyserver.ubuntu.com \
             --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 \
                         7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
        curl -sSL https://get.rvm.io | bash -s stable && \
        source /home/llm/.rvm/scripts/rvm && \
        for v in ${RUBY_VERSIONS}; do \
            echo "==> rvm install $v" && \
            rvm install "$v"; \
        done && \
        rvm alias create default "${RUBY_DEFAULT}" && \
        ruby --version; \
    fi'

# ── Go tools (installed after user is set up) ───────────────────────────────
# DL3062: gopls is the official Go language server — @latest tracks the active
# Go toolchain version installed in the same build. Pinning a specific gopls
# semver here would diverge from the Go version and cause compatibility issues.
# hadolint ignore=DL3062
RUN if command -v go >/dev/null 2>&1; then \
        mkdir -p /home/llm/go /home/llm/.cache/go-build && \
        go install golang.org/x/tools/gopls@latest; \
    fi

# ── User-phase config (mount targets, podman, gem, git, shell) ───────────────
# All lightweight config writes combined into one layer.
RUN mkdir -p \
        /home/llm/.riotbox/bin \
        /home/llm/bin \
        /home/llm/.npm \
        /home/llm/.cargo/registry \
        /home/llm/go/pkg \
        /home/llm/.cache/pip \
        /home/llm/.cache/uv \
        /home/llm/.bundle/cache \
        /home/llm/.m2/repository \
        /home/llm/.gradle/caches \
        /home/llm/.bun/install \
        /home/llm/.config/containers && \
    # Inner podman config (for nested container support)
    printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' \
        > /home/llm/.config/containers/storage.conf && \
    printf '[containers]\ninit = false\n' \
        > /home/llm/.config/containers/containers.conf && \
    # Gem / Bundler — skip docs, parallel installs
    echo 'gem: --no-document' > /home/llm/.gemrc && \
    printf 'BUNDLE_JOBS: "4"\nBUNDLE_RETRY: "3"\n' > /home/llm/.bundle/config && \
    # Git config — generic LLM identity so reown-commits.sh can identify the
    # container's work regardless of which model (Claude, opencode, etc.) ran.
    git config --global user.name "LLM (riotbox)" && \
    git config --global user.email "llm@riotbox" && \
    git config --global commit.gpgsign false && \
    git config --global tag.gpgsign false && \
    git config --global core.pager "" && \
    git config --global advice.detachedHead false && \
    git config --global advice.addIgnoredFile false && \
    git config --global init.defaultBranch main && \
    # safe.directory covers both single-project (`/workspace`) and the
    # multi-project layout where each project is mounted at
    # `/workspace/<dirname>`. The wildcard is needed because:
    #   1. We do not know the project basenames at build time, so we
    #      cannot enumerate them.
    #   2. If --userns=keep-id has the host UID off by a subordinate
    #      mapping (e.g. a previous nested-mode session left dirs owned
    #      by a different inner uid), git inside the container would
    #      refuse every operation with "dubious ownership in repository".
    # The container is the safety boundary; treating every workspace path
    # as a safe directory is consistent with that boundary.
    git config --global --add safe.directory '*' && \
    git config --global receive.denyNonFastForwards true && \
    git config --global receive.denyDeletes true

# ── Shell config ──────────────────────────────────────────────────────────────
RUN cat >> /home/llm/.bashrc <<'BASHRC'

# ── Non-interactive / automation-friendly defaults ───────────────────────────

# Prevent locale warnings from tools that expect UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Suppress ANSI color codes in piped/redirected output — just noise for Claude
export NO_COLOR=1
export CLICOLOR_FORCE=0
export CARGO_TERM_COLOR=auto

# Python: don't nag about pip upgrades, allow global installs on 3.12+,
# suppress "running as root" warning, skip .pyc file generation
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_BREAK_SYSTEM_PACKAGES=1
export PIP_ROOT_USER_ACTION=ignore
export PYTHONDONTWRITEBYTECODE=1

# npm: suppress funding appeals, audit summaries, and update notifications
export NPM_CONFIG_FUND=false
export NPM_CONFIG_AUDIT=false
export NPM_CONFIG_UPDATE_NOTIFIER=false

# opencode: suppress auto-update checks and LSP downloads. The container
# runs a fixed image; outbound requests for tooling are a leak surface.
export OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1

# Not on Debian, but some scripts check this to skip interactive prompts
export DEBIAN_FRONTEND=noninteractive

# Bigger history — useful when Claude needs to review what it already ran
export HISTSIZE=10000
export HISTFILESIZE=10000

# Make it obvious we're in RiotBox
export PS1='[\[\e[36m\]riotbox\[\e[0m\]] \w \$ '

# ── nvm ──────────────────────────────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]            && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ]   && \. "$NVM_DIR/bash_completion"

# ── uv / local bins ───────────────────────────────────────────────────────────
export PATH="$HOME/.riotbox/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/bin:$PATH"

# ── Cargo/Rust ────────────────────────────────────────────────────────────
[ -f "$HOME/.cargo/env" ] && \. "$HOME/.cargo/env"

# ── RVM ───────────────────────────────────────────────────────────────────
[ -s "$HOME/.rvm/scripts/rvm" ] && \. "$HOME/.rvm/scripts/rvm"
export PATH="$PATH:$HOME/.rvm/bin"

# ── Go ────────────────────────────────────────────────────────────────────
export GOPATH="$HOME/go"
# Allow go install/get to auto-update go.mod instead of erroring
export GOFLAGS="-mod=mod"

# ── Build performance ────────────────────────────────────────────────────
# Parallel make by default — speeds up native compilations
export MAKEFLAGS="-j$(nproc)"
BASHRC

# ── Tool configs (.npmrc, pip.conf, etc.) copied from host by build.sh ────────
# configs/ is always created by build.sh (even if empty)
COPY --chown=llm:llm configs/ /home/llm/

# scripts/build.sh copies the installing user's ~/.npmrc into the build context
# and strips only credentials (_authToken/_auth/_password), so a host `cache=`
# survives into the .npmrc landed above and would move npm's cache off
# /home/llm/.npm. Every npm layer below empties that directory — see "Why every
# npm layer empties /home/llm/.npm" — and a moved cache would leave each strip
# deleting nothing from an empty-but-present directory: exit 0, build green,
# caches still committed. An env var outranks every npmrc in npm's config
# precedence (verified on npm 11.9.0 — `cache=` in ~/.npmrc loses to this), so
# pinning it here makes every strip correct whatever the host set, and keeps
# the runtime .npm volume mounted over the cache npm actually uses. Spelled
# uppercase to match the NPM_CONFIG_* exports the shell profile sets; npm reads
# either case.
ENV NPM_CONFIG_CACHE=/home/llm/.npm

# ── Diagram tools (for validating generated diagrams) ────────────────────────
# Off by default. Set RIOTBOX_DIAGRAMS=1 at build time to install Chromium
# and mermaid-cli (mmdc). The system Chromium rpm is installed earlier in
# the same conditional; puppeteer's bundled Chromium (~580 MB) is skipped
# either way so we don't accidentally double-install.
# The npm cache strip is the one "Why every npm layer empties /home/llm/.npm"
# explains; it sits inside the conditional because there is nothing to strip
# when it is off.
#
# DL3016: @mermaid-js/mermaid-cli is kept at latest to support current Mermaid
# diagram syntax; pinning a specific version risks stale diagram rendering.
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
# hadolint ignore=DL3016
RUN if [ "${RIOTBOX_DIAGRAMS}" = "1" ]; then \
        npm install -g @mermaid-js/mermaid-cli && mmdc --version && \
            find /home/llm/.npm -mindepth 1 -delete; \
    fi

# ── RiotBox scripts: agent registry + generic wrapper ───────────────────────
# The agent registry (agents/<name>.sh + agents/registry.sh) is the single
# source of truth for which CLI agents this image supports. The Containerfile
# stays agent-agnostic: agent-wrapper.sh is installed once, and per-agent
# entries in /home/llm/.riotbox/bin/ are symlinks created from the
# registry. Adding a new agent is a manifest edit, not a Containerfile edit.
COPY --chown=llm:llm agents/ /home/llm/.riotbox/agents/
COPY --chown=llm:llm container/find-real-bin.sh /home/llm/.riotbox/find-real-bin.sh
COPY --chown=llm:llm container/agent-wrapper.sh /home/llm/.riotbox/agent-wrapper.sh
RUN chmod +x /home/llm/.riotbox/agent-wrapper.sh \
              /home/llm/.riotbox/find-real-bin.sh && \
    # Install one symlink per registered agent. The wrapper detects the
    # agent from basename($0), so the symlink name doubles as the agent
    # name. Reading AGENT_REGISTRY directly keeps the Containerfile in sync
    # with agents/registry.sh — no second list to update.
    bash -c '\
        set -euo pipefail; \
        # shellcheck disable=SC1091  # path verified above \
        source /home/llm/.riotbox/agents/registry.sh; \
        for a in "${AGENT_REGISTRY[@]}"; do \
            ln -sf ../agent-wrapper.sh "/home/llm/.riotbox/bin/${a}"; \
        done'

WORKDIR /workspace

# ── Entrypoint ──────────────────────────────────────────────────────────────
# Agent setup scripts (claude/setup.sh, opencode/setup.sh) ride along with
# the manifests via the COPY agents/ above; the entrypoint reaches them
# through the registry, so they don't need separate COPY lines.
COPY --chown=llm:llm container/session-branch.sh /home/llm/.riotbox/session-branch.sh
COPY --chown=llm:llm container/overlay-setup.sh /home/llm/.riotbox/overlay-setup.sh
COPY --chown=llm:llm container/plugin-setup.sh /home/llm/.riotbox/plugin-setup.sh
COPY --chown=llm:llm container/startup-scripts.sh /home/llm/.riotbox/startup-scripts.sh
COPY --chown=llm:llm container/nested-podman-setup.sh /home/llm/.riotbox/nested-podman-setup.sh
COPY --chown=llm:llm container/headroom-summary.sh /home/llm/.riotbox/headroom-summary.sh
COPY --chown=llm:llm container/codegraph-setup.sh /home/llm/.riotbox/codegraph-setup.sh
COPY --chown=llm:llm container/context-mode-setup.sh /home/llm/.riotbox/context-mode-setup.sh
COPY --chown=llm:llm container/context-mode-summary.sh /home/llm/.riotbox/context-mode-summary.sh
COPY --chown=llm:llm container/git-ai-setup.sh /home/llm/.riotbox/git-ai-setup.sh
# The entrypoint sources lib/overlay-ignore.sh from this path, so the shared
# shell library has to exist inside the image as well as on the host. The
# directory is copied wholesale rather than file by file, so anything added
# under scripts/lib/ ships automatically — no second list to update here.
# The host-side copies (libexec/launch.sh, scripts/overlay.sh) read straight
# from the checkout, so a host edit is live on the next launch; the copy in
# the image only picks it up on the next image build.
COPY --chown=llm:llm scripts/lib/ /home/llm/.riotbox/lib/
COPY --chown=llm:llm container/entrypoint.sh /home/llm/.riotbox/entrypoint.sh
RUN chmod +x /home/llm/.riotbox/entrypoint.sh \
    /home/llm/.riotbox/session-branch.sh /home/llm/.riotbox/overlay-setup.sh \
    /home/llm/.riotbox/plugin-setup.sh /home/llm/.riotbox/startup-scripts.sh \
    /home/llm/.riotbox/nested-podman-setup.sh /home/llm/.riotbox/headroom-summary.sh \
    /home/llm/.riotbox/codegraph-setup.sh /home/llm/.riotbox/context-mode-setup.sh \
    /home/llm/.riotbox/context-mode-summary.sh /home/llm/.riotbox/git-ai-setup.sh
ENTRYPOINT ["/home/llm/.riotbox/entrypoint.sh"]
CMD ["bash"]

# ── Health check ──────────────────────────────────────────────────────────────
# This is a developer-shell image with no long-running daemon to probe. The
# check verifies that the core toolchain is intact (task is always present)
# without starting any service or network connection.
# DL3025: the probe needs a shell — `command` is a builtin and >/dev/null is
# shell redirection, so exec form would only re-wrap this in /bin/sh -c. The
# rule's rationale (signal delivery to PID 1) does not apply to a healthcheck.
# Suppressed here rather than globally so DL3025 still guards the real
# ENTRYPOINT/CMD above, which are exec form on purpose.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --retries=1 \
    CMD command -v task >/dev/null 2>&1

# ── LLM CLI tool cache-bust boundary ────────────────────────────────────────
# `task container:update` bumps LLM_TOOL_UPDATE to a fresh value, which makes
# this RUN a cache miss and forces every layer below it (headroom, opencode,
# Claude Code, CodeGraph, bun, Context Mode, the Context Mode plugin tree,
# plugins) to rebuild and re-pull latest — without rebuilding the whole image.
# A normal `task container:build` always passes the default (0), so the
# boundary stays cached and the tools are reused. Those tool RUNs are
# intentionally left unchanged; the boundary alone controls their freshness.
# The list above is the inventory — deliberately not a count, because the one
# this replaced went stale the moment a layer was added below the boundary.
#
# The remaining RUNs below the boundary are cheap or inert. Locking the Context
# Mode event-bridge directories only chmods and re-asserts local paths, so an
# update re-runs it for free. The gh/glab block does nothing unless
# RIOTBOX_GH_GLAB=1 selected that flavor — where an update also re-installs gh
# and glab from EPEL and re-downloads the pinned github-mcp-server tarball.
#
# headroom, CodeGraph, bun, Context Mode and its plugin tree are
# version-pinned, so an update re-installs them unchanged, re-fetching
# identical bytes:
#   * the same headroom wheels and ~350 MB of models
#   * the same CodeGraph npm package (no model download)
#   * the same ~34 MB bun release zip, re-downloaded and re-verified against
#     the pinned digest
#   * the same Context Mode npm package, which additionally re-runs
#     `nvm install` and re-downloads its pinned Node toolchain because that too
#     lives below the boundary
#   * a fresh `git clone` of mksglu/context-mode at the pinned ref — re-checked
#     against CONTEXT_MODE_PLUGIN_SHA, put back through the build assert and
#     the routing probe — plus a re-run `npm ci` of 139 packages against the
#     committed lockfile
# The cost is accepted so `riotbox update` can add all of them to images built
# before they existed and refresh headroom's unpinned transitive deps.
ARG LLM_TOOL_UPDATE=0
RUN echo "LLM CLI tools cache key: ${LLM_TOOL_UPDATE}"

# ── headroom (context compression — opt-in at runtime via RIOTBOX_HEADROOM) ──
# Lean extras: [proxy] carries Kompress as ONNX INT8 (no torch) plus
# sqlite-vec for --memory; [code] adds tree-sitter AST compression. The
# [ml]/[memory] extras are deliberately excluded — both drag in torch.
# Models are pre-warmed into ~/.cache/huggingface so enabled sessions run
# with HF_HUB_OFFLINE=1 (set by the entrypoint) and never touch the network;
# the final offline preload proves the cache is complete at build time.
# NOTE: preload() is internal headroom API — acceptable because the version
# is pinned; a pin bump that breaks it fails THIS layer, not a user session.
# Through 0.25.0 this layer carried a sed patch: `headroom wrap --memory`
# spawns `python -m headroom.memory.sync`, which built its backend config with
# the dataclass default embedder (torch sentence-transformers — excluded here)
# instead of the ONNX embedder the proxy auto-selects, with no flag or env var
# to steer it. Upstream fixed it (headroom #1092): _build_sync_backend now
# passes embedder_backend="onnx" itself, so the patch is gone. The grep stays
# as the tripwire in its place — a future pin that regresses the sync path to
# the torch default fails THIS layer instead of a user session, which is the
# only place the regression would otherwise surface.
# The smoke test then runs the exact sync command the wrap emits, offline,
# against a seeded memory file under a throwaway HOME — proving the ONNX
# embedder path AND the pre-warmed model cache end to end. PYTHONPATH is
# pinned to the user site because overriding HOME hides pip's --user dir.
# The hf-xet chunk cache is transfer-time scratch — the offline loads above
# prove the hub cache alone suffices, so it is removed.
#
# The MiniLM warm-up goes through headroom's own hf_hub_download_local_first
# rather than huggingface_hub's hf_hub_download, because since 0.36.5 headroom
# resolves model artifacts at immutable commit SHAs (_PINNED_REVISIONS in
# headroom/onnx_runtime.py) for supply-chain integrity. A bare hf_hub_download
# fetches the floating `main` ref instead, so the moment upstream pushes to
# that HuggingFace repo the build would warm one revision and every session
# would ask for another — a cache miss reached only at runtime, which is
# exactly what RIOTBOX_NETWORK=none forbids. Going through the same resolver
# the session uses makes the warmed revision and the requested one agree by
# construction, and allow_network=False is that resolver's own offline mode,
# so the verification pass proves the cache against the real read path.
#
# HEADROOM_KOMPRESS_CANARY_SECONDS=0 on both preload probes: since 0.36.5
# preload() starts a daemon thread that runs a canary inference and returns
# WITHOUT joining it, so the proxy can bind its port while the probe runs. A
# one-shot `python3 -c` has no port to bind and no next request — it exits the
# moment preload() returns, tearing the interpreter down while that thread is
# still inside native ONNX Runtime code. glibc aborts the process ("FATAL:
# exception not rethrown", exit 134) and fails this layer. Whether the canary
# finishes first is a race, so leaving it on fails the build only sometimes —
# worse than never. Upstream documents <=0 as the off switch. Deliberately NOT
# an image-wide ENV: in a session the canary is what catches a degraded ONNX
# runtime before live traffic depends on it, which is the whole reason it
# exists. tests/headroom.venom.yml pins both halves of that.
ARG HEADROOM_VERSION=0.36.5
RUN pip3 install --user --no-cache-dir --break-system-packages \
        "headroom-ai[proxy,code]==${HEADROOM_VERSION}" && \
    /home/llm/.local/bin/headroom --version && \
    SYNC="$(python3 -c 'import headroom.memory.sync as m; print(m.__file__)')" && \
    grep -qF 'embedder_backend="onnx"' "${SYNC}" && \
    HEADROOM_KOMPRESS_CANARY_SECONDS=0 python3 -c "from headroom.transforms.kompress_compressor import KompressCompressor; \
print('kompress backend:', KompressCompressor().preload(allow_download=True))" && \
    python3 -c "from headroom.onnx_runtime import hf_hub_download_local_first as d; \
[d('Qdrant/all-MiniLM-L6-v2-onnx', f) for f in ('model.onnx', 'tokenizer.json')]" && \
    HF_HUB_OFFLINE=1 HEADROOM_KOMPRESS_CANARY_SECONDS=0 python3 -c "from headroom.transforms.kompress_compressor import KompressCompressor; \
KompressCompressor().preload(allow_download=False)" && \
    HF_HUB_OFFLINE=1 python3 -c "from headroom.onnx_runtime import hf_hub_download_local_first as d; \
[d('Qdrant/all-MiniLM-L6-v2-onnx', f, allow_network=False) for f in ('model.onnx', 'tokenizer.json')]" && \
    USERSITE="$(python3 -m site --user-site)" && \
    SMOKE="$(mktemp -d)" && \
    MEMDIR="${SMOKE}/.claude/projects/$(python3 -c "import sys; from pathlib import Path; \
from headroom.memory.sync_adapters.claude_code import encode_claude_project_path; \
print(encode_claude_project_path(Path(sys.argv[1])))" "${SMOKE}/work")/memory" && \
    mkdir -p "${SMOKE}/work" "${MEMDIR}" && \
    printf -- '---\nname: smoke\ndescription: build-time sync smoke test\n---\n\nBuild-time smoke test fact.\n' \
        > "${MEMDIR}/smoke.md" && \
    env -C "${SMOKE}/work" HOME="${SMOKE}" HF_HUB_OFFLINE=1 \
        HF_HOME=/home/llm/.cache/huggingface \
        PYTHONPATH="${USERSITE}" python3 -m headroom.memory.sync \
        --db "${SMOKE}/memory.db" --user smoke --agent claude --force \
        | tee /dev/stderr | grep -q '"imported": 1' && \
    rm -rf "${SMOKE}" && \
    rm -rf /home/llm/.cache/huggingface/xet

# ── opencode (installed alongside Claude Code) ───────────────────────────────
# The official installer hardcodes the install target at $HOME/.opencode/bin
# and modifies .bashrc to extend PATH. Skip the .bashrc modification with
# --no-modify-path (we manage PATH explicitly in the image), then move the
# binary into the existing user-local bin dir so no extra PATH entry is
# needed. The .opencode/bin directory itself is left in place — empty after
# the move and harmless.
#
# Deliberately unpinned: the installer resolves the latest GitHub release, and
# we want opencode to track upstream. The 1.18.0 floor is the version that
# introduced --auto, the flag agents/opencode/manifest.sh injects for
# autonomous runs. opencode's parser is strict, so a build without --auto
# would fail loudly — but it would fail in the user's session, at the moment
# they tried to work. Assert it here instead, where the failure names what
# moved and costs a rebuild rather than a debugging session.
#
# sort -VC compares whole lines, so any --version output that is not a bare
# X.Y.Z (a `v` prefix, a banner) sorts above the floor and passes the check
# vacuously. Pull the bare version out first and fail the build when there
# isn't one, so a change in upstream's output format cannot silently retire
# the guard.
#
# The floor alone only catches a downgrade, and downgrades cannot happen while
# the install is unpinned — opencode only moves forward. The move that CAN
# happen is upstream renaming or dropping --auto in a release well above the
# floor, which sails past the version check. So also probe the installed
# binary for the flag itself. `--help` is written to STDERR, hence the 2>&1.
#
# Probe BOTH sites the wrapper injects into, because --auto is registered per
# command, not globally: `run` (every headless riotbox run/resume/audit) and
# the default [project] command (the TUI). Root help documents the default
# command, so it says nothing about `run` — a release that kept --auto on the
# TUI and dropped it from `run` would pass a root-only probe and then break
# every non-interactive session.
#
# Each probe captures its output first rather than piping straight into grep,
# so a crashing `--help` is reported as a crash instead of being misread as a
# missing flag, and the help text itself lands in the build log where whoever
# hits this can see what upstream actually renamed it to.
RUN bash -o pipefail -c '\
    set -e; \
    curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path; \
    mv /home/llm/.opencode/bin/opencode /home/llm/.local/bin/opencode; \
    v_raw="$(/home/llm/.local/bin/opencode --version)"; \
    echo "installed opencode ${v_raw}"; \
    v="$(printf "%s\n" "${v_raw}" | grep -xE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)" || true; \
    [ -n "${v}" ] || { \
        echo "cannot read a bare X.Y.Z version out of opencode --version: ${v_raw}" >&2; \
        exit 1; }; \
    printf "1.18.0\n%s\n" "${v}" | sort -VC || { \
        echo "opencode ${v} predates the --auto flag (need >= 1.18.0)" >&2; \
        exit 1; }; \
    for scope in "run" ""; do \
        h="$(/home/llm/.local/bin/opencode ${scope} --help 2>&1)" || { \
            echo "opencode ${scope} --help failed; cannot verify --auto" >&2; \
            printf "%s\n" "${h}" >&2; \
            exit 1; }; \
        printf "%s\n" "${h}" \
            | grep -qE "(^|[[:space:]])--auto([[:space:]]|$)" || { \
            echo "opencode ${v} does not register --auto on \"opencode ${scope}\"; the flag agents/opencode/manifest.sh injects would break every session" >&2; \
            printf "%s\n" "${h}" >&2; \
            exit 1; }; \
    done'

# ── Claude Code (LAST — changes most frequently, preserves layer cache) ─────
RUN bash -o pipefail -c 'curl -fsSL https://claude.ai/install.sh | bash && claude --version'

# ── CodeGraph (pre-indexed code knowledge graph, CLI only) ──────────────────
# The published npm package is a thin launcher: the payload ships as a
# per-platform optionalDependency (@colbymchenry/codegraph-linux-x64). When a
# registry or proxy silently skips that optional dep, the launcher falls back
# to downloading the bundle from GitHub Releases ON FIRST RUN — inside a user
# session, which breaks RIOTBOX_NETWORK=none and violates offline-after-build.
# `CODEGRAPH_NO_DOWNLOAD=1 codegraph version` fails this layer instead.
#
# `codegraph telemetry off` persists the opt-out to ~/.codegraph/telemetry.json
# (outside every session bind mount, so it survives into every container). The
# `env -u` re-check proves that stored layer stands on its own rather than
# reflecting the ENV set above. The machine_id the opt-out generates is baked
# into the image and shared by every container; it is never transmitted,
# because all three opt-out layers short-circuit before any send path.
#
# DL3016 does not apply: the version is pinned via the build ARG.
#
# ── Why every npm layer empties /home/llm/.npm ──────────────────────────────
# npm's cache is per-user, not per-install: every npm layer in this stage
# writes the tarballs it downloaded to /home/llm/.npm/_cacache, and
# better-sqlite3's prebuild-install drops its native binary in _prebuilds
# beside them. Measured on npm 11.9.0 against an empty cache: 61 MB here,
# 34 MB for the Context Mode package below, 8.3 MB for the plugin tree's
# `npm ci`. All of it is redundant with the resolved trees those installs just
# wrote, and /home/llm/.npm is a named-volume mount target at runtime, so no
# session ever reads the build's copy. Each npm layer therefore empties it in
# its OWN RUN, the way the pip and dnf layers do — a single strip at the bottom
# would only whiteout bytes the layers above had already committed, reclaiming
# nothing.
#
# `find -mindepth 1 -delete` rather than `npm cache clean --force`: measured,
# clean clears _cacache and leaves _prebuilds and _logs behind, and the
# directory itself has to survive because the runtime mount lands on it.
#
# Every strip hard-depends on /home/llm/.npm existing: `find` on a missing path
# exits 1. It is pre-created with the other mount targets by the "User-phase
# config" mkdir, and NPM_CONFIG_CACHE is pinned to it by the "Tool configs"
# block. Dropping it from that mkdir list fails the first npm layer instead of
# silently skipping the strip, which is the behaviour to keep.
ARG CODEGRAPH_VERSION=1.5.0
RUN npm install -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}" && \
    CODEGRAPH_NO_DOWNLOAD=1 codegraph version && \
    codegraph telemetry off && \
    env -u CODEGRAPH_TELEMETRY codegraph telemetry status | grep -q disabled && \
    find /home/llm/.npm -mindepth 1 -delete

# ── bun (JS/TS runtime for Context Mode's sandbox executor) ──────────────────
# Context Mode's ctx_execute reports `TypeScript: not available (install bun,
# tsx, or ts-node)` without it, so TS snippets cannot run at all. The Claude
# hook path does NOT use bun — those stanzas run the pinned Node from the
# Context Mode block below — so this layer buys the executor and nothing else.
#
# The release asset, not https://bun.sh/install: RIOTBOX-20260312-001 is open
# and asks every download in this image for download-then-verify against a
# pinned SHA256, which a piped installer cannot give. Same treatment venom and
# github-mcp-server get, and pinning costs nothing extra here — the version was
# already the only control over what lands, since nothing in this layer probes
# for a feature the way the opencode block probes for --auto.
#
# Unlike venom, upstream publishes SHASUMS256.txt per release, so the digests
# below are transcribed from it rather than self-computed. They are still
# transcribed at review time, not fetched beside the artifact at build time:
# a checksum pulled from the same place as the file it describes, in the same
# build, proves only that the two agree.
#
# Upstream also signs that file as SHASUMS256.txt.asc, and nothing here touches
# it: not the signature, not the key behind it, and not the refresh recipe
# below, which reads the plain checksum file and never fetches the .asc at all.
# So what the pin buys is narrower than "verified" suggests, and worth stating
# plainly. It catches the bytes behind a fixed tag changing after the digests
# were transcribed. It cannot notice a release that was already compromised at
# the moment of transcription, because the digests would have been read from
# the compromised release's own checksum file.
#
# The x64 BASELINE asset, not the plain x64 one, which requires AVX2. The image
# is built on one machine and run on whatever the user has, and an illegal
# instruction at ctx_execute time would surface as the executor dying with no
# obvious cause. Baseline gives that up for some throughput on a runtime that
# only ever executes short snippets. The musl variants are wrong here for the
# opposite reason — this image is glibc.
#
# To refresh:
#   1. Pick a new tag at https://github.com/oven-sh/bun/releases (stable only)
#   2. Read the digests for both assets out of upstream's checksum file:
#        curl -fsSL https://github.com/oven-sh/bun/releases/download/bun-v<VER>/SHASUMS256.txt \
#          | grep -E 'bun-linux-(x64-baseline|aarch64)\.zip$'
#   3. Update BUN_VERSION + BUN_SHA256_AMD64 + BUN_SHA256_ARM64 below
#
# Three naming divergences below, all deliberate. The ARG suffixes follow this
# file's _AMD64/_ARM64 convention. The case labels do not: they match
# `uname -m` untranslated (x86_64, aarch64) rather than venom's sed to
# amd64/arm64, and each arm sets upstream's asset name beside the digest
# that goes with it, so the two cannot drift apart. And BUN_VERSION is bare
# where VENOM_VERSION and GITHUB_MCP_SERVER_VERSION both carry a leading v —
# `bun --version` prints 1.3.14, so the bare form is what the check at the end
# can compare against, and the URL puts the v back as part of the
# bun-v${BUN_VERSION} tag.
ARG BUN_VERSION=1.3.14
ARG BUN_SHA256_AMD64=a063908ae08b7852ca10939bbdc6ceed3ddabce8fb9402dce83d65d73b36e6c7
ARG BUN_SHA256_ARM64=a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b
RUN bash -o pipefail -c '\
    set -e; \
    case "$(uname -m)" in \
        x86_64)  ASSET=bun-linux-x64-baseline; EXPECTED_SHA="${BUN_SHA256_AMD64}" ;; \
        aarch64) ASSET=bun-linux-aarch64; EXPECTED_SHA="${BUN_SHA256_ARM64}" ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/bun.zip \
        "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${ASSET}.zip"; \
    echo "${EXPECTED_SHA}  /tmp/bun.zip" | sha256sum -c -; \
    unzip -qj /tmp/bun.zip "${ASSET}/bun" -d /home/llm/.local/bin; \
    chmod +x /home/llm/.local/bin/bun; \
    rm -f /tmp/bun.zip; \
    v="$(/home/llm/.local/bin/bun --version)"; \
    echo "installed bun ${v}"; \
    [ "${v}" = "${BUN_VERSION}" ] || { \
        echo "bun reports ${v}, pinned ${BUN_VERSION}" >&2; exit 1; }'

# ── Context Mode (opt-in at runtime via RIOTBOX_CONTEXT_MODE) ────────────────
# Installed under its own pinned Node, not the image default. Context Mode
# hard-fails installation on Linux below Node 22.5 — scripts/postinstall.mjs
# calls process.exit(1), deliberately, because engines.node is cosmetic under
# npm's default engine-strict=false. Below 22.5 there is no node:sqlite, so it
# falls back to better-sqlite3's native addon, which SIGSEGVs under a V8
# madvise bug (nodejs/node#62515). NODE_DEFAULT above is whatever nvm versions
# scripts/build.sh found on the host — often 20 — so this pin is what keeps
# the build working on a Node 20 host instead of failing for the user and not
# for the maintainer.
#
# The shim is what makes the pin stick at runtime. npm's own global bin shim
# starts `#!/usr/bin/env node`, which resolves to the session default, and
# Context Mode bakes process.execPath into every hook command it emits
# (src/runtime.ts upstream). Exec'ing the pinned interpreter explicitly means
# the CLI, the MCP server, and every hook run on 22.x whatever the agent's
# default Node is.
#
# The install paths come from `nvm which` rather than from the ARG. nvm
# accepts a partial version — `nvm install 22` succeeds and lands whatever
# 22.x it resolved — so building the path as v${CONTEXT_MODE_NODE} by hand
# would leave anyone who passed the arg in the major-only form NODE_VERSIONS
# and NODE_DEFAULT above use staring at "No such file or directory" for a
# .../v22/bin path, with nothing in it to suggest that the format of the arg,
# rather than a broken install, was the cause.
#
# Build-time guards on the shim template in container/context-mode-setup.sh,
# the per-agent wiring in agents/*/context-mode.sh, and the exit report in
# container/context-mode-summary.sh, all of which fail THIS layer rather than
# letting a user session discover the drift. All three are sourced here — the
# agent wiring through agents/registry.sh — so the guards assert the constants
# and the paths a session will actually use and cannot fall out of step with
# them. The ${VAR:?} lines are what keep that honest: the RUN is not `set -u`,
# and cannot be because nvm.sh is not clean under it, so a renamed or emptied
# constant would otherwise expand to nothing and let the checks below pass
# having checked nothing at all:
#
#   * CONTEXT_MODE_BIN, which is where the shim is written, in place of a
#     literal repeated across this RUN. context_mode_setup skips the wiring and
#     leaves the session running with the feature off when that path is not
#     executable, and it reads the path from this constant — so relocating the
#     shim here and leaving the template alone would silently disable the
#     feature in every session while every check in this layer still passed,
#     each one invoking the shim by its new path, and `riotbox doctor` still
#     passed too, because scripts/preflight.sh resolves it through PATH.
#     Generating into the constant makes the two agree by construction, and the
#     `-x` test after the chmod is the predicate the session itself evaluates,
#     so an edit that puts the file anywhere else fails here instead. HOME is
#     ENV-set to /home/llm and the image runs as llm well above this layer, so
#     build and session expand the constant to the same path.
#   * Every registered agent's context_mode_build_assert verb, one call per
#     entry in AGENT_REGISTRY, each handed the installed package root. The
#     contract an agent depends on is declared in agents/<name>/context-mode.sh
#     beside the constants that encode it: a guard kept here instead would stop
#     guarding the day either one moved, and a third agent's guard would be a
#     Containerfile edit rather than a manifest one. An agent with no such verb
#     is skipped: the Context Mode verbs are optional, and an agent that never
#     reaches Context Mode has no upstream contract to assert. A failure here
#     always names the agent whose contract broke.
#
#     claude asserts exactly one thing now: that CONTEXT_MODE_MCP_NAME still
#     appears in hooks/core/tool-naming.mjs, the routing table naming the tools
#     a redirect points the agent at. That table hardcodes
#     mcp__plugin_context-mode_context-mode__<tool> under its claude-code key
#     with nothing to steer it, so the MCP server has to be registered under
#     that name; a pin bump that changed the prefix would leave every redirect
#     pointing at a tool the session does not have. The grep includes the
#     backtick that opens the template literal, so the identical string in the
#     file's own doc table cannot satisfy it while the code drifts. Both this
#     and the path itself are upstream internals that could be relocated
#     without any change in behaviour; that would fail this layer too, which is
#     the intent — the drift then gets read by a maintainer instead of by a
#     session.
#
#     This call covers the npm package root installed above and nothing else.
#     It stays because that package is what the `context-mode` CLI and the
#     opencode adapter run from; the staged plugin tree a Claude session runs
#     is asserted separately, in the staging layer below.
#
#     What is NOT asserted any more: the hook event set and the PreToolUse and
#     PostToolUse matchers. Those were three equality comparisons against
#     hooks/hooks.json, and they went with the tables they compared.
#     context_mode_hook_table, CONTEXT_MODE_MATCHER and
#     CONTEXT_MODE_POST_MATCHER were RiotBox's transcription of that file,
#     asserted equal to it so a drift between the two copies failed here; the
#     staged plugin ships hooks.json and Claude Code reads it directly, so
#     there is no second copy left to compare. What that costs is honest and
#     recorded: which tools are intercepted is now upstream's runtime decision
#     on BOTH agents, with no build-time signal when it changes. See
#     docs/dev/context-mode.md § Which tools are actually intercepted.
#
#     A grep is also the sounder shape. The comparisons it replaced compared
#     two command substitutions, so a run in which both sides failed compared
#     "" against "" and passed. A failed grep is a failed assert.
#
#     opencode asserts the three things its plugin shim re-exports through:
#     build/adapters/opencode/plugin.js exists, still exports
#     ContextModePlugin, and is still what package.json maps ./plugin to.
#     Nothing on that path is a hook or an MCP server, so none of the claude
#     constants have an analogue — an upstream move would surface as an
#     opencode session whose plugin silently fails to load.
#   * context_mode_pkg_root against CM_PKG, and after the shim is generated
#     rather than before, because the derivation parses that shim. The opencode
#     wiring builds the re-export path from it every session, so a change to
#     the shim's shape would point every generated plugin at a package root
#     that does not exist.
#   * NOT the `hook <platform> <event>` dispatcher. There was an assertion on
#     it — a grep of `--help` — and it has gone with the hand-authored wiring
#     that dispatched through it. The staged plugin's hooks.json invokes
#     hooks/<event>.mjs directly, so nothing RiotBox installs calls that
#     subcommand any more, and a guard on a surface RiotBox does not use only
#     buys a future build failure a maintainer has to rule out. (The string
#     still appears in tests/context-mode.venom.yml, as fixtures for the
#     legacy-stanza strip: recognising the shape RiotBox used to write is a
#     contract with its own past output, not with upstream's CLI.) What that
#     assertion was reaching for — proof that a hook routes rather than proof
#     that the CLI runs — is guarded by the routing probe in the plugin
#     staging layer below, which it never could be here: fed empty stdin, the
#     dispatcher exits 0 and prints nothing for a valid event and a
#     nonexistent one alike.
#   * getRealBytesStats in build/session/analytics.js — the counters the
#     generated CONTEXT_MODE_STATS_BIN shim imports — and then that shim's own
#     output against a throwaway empty sessions directory. Upstream renaming
#     either the module or the export would otherwise surface as sessions that
#     silently stop printing the exit report.
#
# DL3016 does not apply: the version is pinned via the build ARG.
#
# The trailing npm cache strip is the one "Why every npm layer empties
# /home/llm/.npm" explains. It runs last because `context-mode doctor` checks
# the published npm version and would repopulate the cache behind an earlier
# strip.
ARG CONTEXT_MODE_NODE=22.23.2
ARG CONTEXT_MODE_VERSION=1.0.169
RUN bash -c '\
    set -e; \
    export NVM_DIR=/home/llm/.nvm; \
    . "${NVM_DIR}/nvm.sh"; \
    nvm install "${CONTEXT_MODE_NODE}"; \
    CM_NODE_EXE="$(nvm which "${CONTEXT_MODE_NODE}")"; \
    CM_NODE_BIN="$(dirname "${CM_NODE_EXE}")"; \
    CM_PKG="${CM_NODE_BIN%/bin}/lib/node_modules/context-mode"; \
    "${CM_NODE_BIN}/npm" install -g "context-mode@${CONTEXT_MODE_VERSION}"; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/context-mode-setup.sh; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/context-mode-summary.sh; \
    : "${CONTEXT_MODE_STATS_BIN:?is no longer defined by context-mode-summary.sh — the exit report would read a shim that was never written}"; \
    : "${CONTEXT_MODE_BIN:?is no longer defined by context-mode-setup.sh — the shim would go where no session looks for it}"; \
    printf "%s\n" \
        "#!/usr/bin/env bash" \
        "# Generated by the RiotBox image build. Pins the interpreter — see the" \
        "# Context Mode block in the Containerfile for why a bare node is wrong." \
        "exec \"${CM_NODE_BIN}/node\" \"${CM_PKG}/cli.bundle.mjs\" \"\$@\"" \
        > "${CONTEXT_MODE_BIN}"; \
    chmod +x "${CONTEXT_MODE_BIN}"; \
    [ -x "${CONTEXT_MODE_BIN}" ]; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/agents/registry.sh; \
    for _cm_agent in "${AGENT_REGISTRY[@]}"; do \
        declare -F "agent_${_cm_agent}_context_mode_build_assert" >/dev/null || continue; \
        agent_call "${_cm_agent}" context_mode_build_assert "${CM_PKG}" \
            || { echo "context-mode@${CONTEXT_MODE_VERSION} broke the ${_cm_agent} Context Mode contract (above)" >&2; exit 1; }; \
    done; \
    [ "$(context_mode_pkg_root)" = "${CM_PKG}" ] \
        || { echo "context_mode_pkg_root derives $(context_mode_pkg_root) from the generated shim, but the package is at ${CM_PKG} — the opencode shim would re-export from the wrong path" >&2; exit 1; }; \
    [ -f "${CM_PKG}/build/session/analytics.js" ]; \
    grep -qF "export function getRealBytesStats" "${CM_PKG}/build/session/analytics.js"; \
    printf "%s\n" \
        "import { getRealBytesStats } from \"${CM_PKG}/build/session/analytics.js\";" \
        "const dir = process.argv[2];" \
        "if (!dir) { process.exit(1); }" \
        "try {" \
        "  process.stdout.write(JSON.stringify(getRealBytesStats({ sessionsDir: dir })) + \"\\n\");" \
        "} catch {" \
        "  process.exit(1);" \
        "}" \
        > /home/llm/.riotbox/context-mode-stats.mjs; \
    printf "%s\n" \
        "#!/usr/bin/env bash" \
        "# Generated by the RiotBox image build. Pins the interpreter for the same" \
        "# reason the context-mode shim does; --no-warnings suppresses the" \
        "# ExperimentalWarning node:sqlite emits, which would otherwise land in" \
        "# the middle of the exit report." \
        "exec \"${CM_NODE_BIN}/node\" --no-warnings \"/home/llm/.riotbox/context-mode-stats.mjs\" \"\$@\"" \
        > "${CONTEXT_MODE_STATS_BIN}"; \
    chmod +x "${CONTEXT_MODE_STATS_BIN}"; \
    CM_PROBE="$(mktemp -d)"; \
    "${CONTEXT_MODE_STATS_BIN}" "${CM_PROBE}" \
        | jq -e "has(\"eventDataBytes\") and has(\"bytesAvoided\") \
                 and has(\"bytesReturned\") and has(\"snapshotBytes\")" > /dev/null; \
    rmdir "${CM_PROBE}"; \
    "${CONTEXT_MODE_BIN}" doctor > /dev/null; \
    find /home/llm/.npm -mindepth 1 -delete'

# ── Context Mode plugin (staged, registered in place at session start) ───────
# Upstream ships its Claude Code surface — six hook events, eleven MCP tools
# and the eight bundled skills that surface as its /context-mode:* commands —
# only in the marketplace plugin. The npm package installed above carries the
# hooks and the MCP tools and nothing else, which is why a RiotBox session had
# no /context-mode commands. There is no commands/ directory upstream: the
# slash commands ARE the skills, declared by "skills": "./skills/" in
# .claude-plugin/plugin.json, so staging the tree is what buys them.
#
# Staged into a VERSION-STAMPED path and never copied into ~/.claude. The
# staged tree is 60 MB at v1.0.169 — 14 MB of source plus 47 MB of runtime
# dependencies — and ~/.claude is a per-session-key bind mount, so a copy would
# pay that disk and that startup latency again for every project set.
# container/plugin-setup.sh registers this path directly; see the reconcile
# there for what happens when a rebuild moves it.
#
# Cloned at a pinned ref at BUILD time, so no session start reaches the
# network and RIOTBOX_NETWORK=none holds. `context-mode upgrade` — which
# git-clones main over the installed tree — stays unsupported inside RiotBox
# for the reason docs/dev/decisions/context-mode-adoption.md already gives.
#
# CONTEXT_MODE_PLUGIN_REF, CONTEXT_MODE_PLUGIN_SHA and CONTEXT_MODE_VERSION
# must describe the same upstream code: v1.0.169 carries "version": "1.0.169"
# in its plugin.json and its package.json, and that tag resolves to commit
# 589d8214, so the staged tree and the npm package above are the same release.
# Bump all three together, and regenerate the lockfile in the same pass — the
# refresh recipe further down, just above the ARGs, is the whole procedure.
#
# ── Why the dependency install, not just the clone ──────────────────────────
# A clone alone does NOT work offline, and the Node version has nothing to do
# with it. hooks/ensure-deps.mjs gates purely on `existsSync(node_modules/
# better-sqlite3)` — its hasModernSqlite() check only skips a SIGSEGV-prone
# child probe, never the install, because the bundles require better-sqlite3
# as a fallback regardless. So EVERY hook invocation on a dependency-less tree
# shells out to `npm install better-sqlite3`. Measured on a bare clone under
# Node 22.23.1, offline: 120 SECONDS per hook — ensure-deps' own execSync
# timeout — after which the hook returns a decision but better-sqlite3 is
# still absent, so the FTS5 knowledge base, which is the entire feature, never
# comes up. PreToolUse fires on nearly every tool call. With the dependencies
# staged the same hook answers in 62 ms and better-sqlite3 loads.
#
# `npm ci --omit=dev`, run with the PINNED Node's npm, is what fits:
#   * `npm ci`, not `npm install` — upstream ships no package-lock.json, only
#     bun.lock, so the lockfile is generated against the pinned commit and
#     committed here as container/context-mode-package-lock.json. Without one
#     npm resolves the `^` ranges fresh on every build, and the pinned commit
#     would fix upstream's own code and nothing about the 139-package tree
#     that gets installed under it. What npm ci does NOT do is catch a stale
#     lockfile by itself: it fails only when the dependency set or its ranges
#     disagree with package.json, and measured on npm 11.9.0 a lockfile at
#     1.0.169 under a package.json at 1.0.170 installs green, because
#     upstream's patch releases rarely move a `^`. The three-way version
#     check that does catch it is in the venom shape guard over this layer.
#   * Not `bun install` — package.json declares no trustedDependencies, so bun
#     skips better-sqlite3's prebuild step, falls through to node-gyp against
#     bun's spoofed `node -v v24.3.0`, and the install script exits 1.
#   * Not the image default Node — npm's own shebang is `#!/usr/bin/env node`,
#     and this stage's PATH already puts NODE_DEFAULT first, so invoking the
#     pinned npm by path is not enough; CM_NODE_BIN has to lead PATH or npm
#     runs itself under Node 20. Upstream's postinstall hard-exits on
#     Linux + Node < 22.5 (their #564), and the prebuilt better-sqlite3 binary
#     is ABI-matched to whatever Node installed it. It must be the same Node
#     the patched hooks.json and plugin.json name, or ensure-deps tries to heal
#     the ABI at hook time — over the network, offline.
#   * --omit=dev keeps the devDependencies (typescript, tsx, vite, esbuild,
#     rolldown) out: 60 MB staged instead of the 148 MB a full install lands.
# What the lockfile does and does not buy, stated plainly: every version in
# the tree is fixed and all 266 resolved entries carry an integrity hash npm
# verifies on download, so a rebuild installs the same REGISTRY bytes and a
# republished tarball fails the install. It cannot notice a dependency that was
# already malicious when the lockfile was generated, because the hashes were
# transcribed from that same resolution — the same limit the bun digests above
# carry.
#
# It also does not cover every byte this layer installs. better-sqlite3 is
# marked hasInstallScript and depends on prebuild-install, and this RUN does not
# pass --ignore-scripts: the install fetches a prebuilt better_sqlite3.node from
# the project's GitHub releases, outside the registry and outside the lockfile,
# with no digest recorded anywhere in this repo. That artifact is native code
# every hook in every enabled session loads, and the loader check below proves
# it imports, not that it is the binary upstream published. Running with
# --ignore-scripts is not the fix on its own: without the prebuild the install
# falls through to node-gyp, which needs a toolchain this stage does not carry.
# Tracked as an open item under RIOTBOX-20260312-001 in THREAT_MODEL.md.
#
# ── Why the interpreter substitutions ───────────────────────────────────────
# Upstream invokes a bare `node` in two places — every hooks/hooks.json command
# and plugin.json's mcpServers entry. NODE_VERSIONS defaults to 20, Context
# Mode needs >= 22.5 for node:sqlite with FTS5, and the staged better-sqlite3
# binary is built for the pinned Node's ABI. Both are rewritten to the pinned
# interpreter. plugin.json's entry is the live one — RiotBox no longer writes
# an mcpServers entry of its own, so the server a session talks to is the one
# declared there.
#
# Each `before` guard is the one that catches upstream: it fails the build if
# nothing invokes a bare `node` any more, which is what a rename, a switch to
# another runtime, or a reshaped file all look like. The `after` guard is
# narrower — it can only catch jq failing to traverse what it just matched.
#
# ── Why the MCP-name assert runs here too ───────────────────────────────────
# The Context Mode layer above already calls context_mode_build_assert for
# every registered agent that implements it, but it hands them the npm package
# root, which is a different tree from this one. This clone is what
# container/plugin-setup.sh registers, so its hooks/core/tool-naming.mjs is the
# routing table a session's redirects are actually built from, its hooks.json
# is what dispatches the events, and its plugin.json declares the MCP server.
# Asserting the npm copy and calling the staged tree covered would rest the
# guarantee on CONTEXT_MODE_VERSION and CONTEXT_MODE_PLUGIN_REF naming one
# release — true today and checked by a venom case, but not something either
# build layer can observe. So the same verb is called a second time here with
# ${dest} as the tree root, and the artifact that executes is verified as
# itself.
#
# It runs before `npm ci`, so a tree whose routing table no longer carries the
# prefix fails without a minute of dependency install first.
#
# Hardcoded to claude rather than looped over AGENT_REGISTRY, unlike the layer
# above. This tree is a Claude Code plugin — plugin.json, hooks.json,
# CLAUDE_PLUGIN_ROOT — and no other agent reaches it, so there is no set to
# iterate, and an agent whose contract is about the npm package would be handed
# a root that says nothing about it.
#
# ── Why the routing probe ───────────────────────────────────────────────────
# Those counts prove the STRING in hooks.json changed. They cannot prove the
# command runs, and they cannot prove it decides anything. The guard this
# probe replaces fed upstream's dispatcher empty stdin — which, as the layer
# above now records, could only ever prove that the CLI runs, and a Context
# Mode that reported itself enabled while routing nothing passed it.
#
# So the probe feeds the real PreToolUse command a real WebFetch payload —
# WebFetch being a tool upstream's matcher set is supposed to intercept — and
# requires a hookSpecificOutput.permissionDecision back. It reads the command
# out of the staged hooks.json rather than hardcoding one, so whatever the
# substitution above produced is exactly what gets executed.
#
# ── Why the sentinel directory: do not simplify this away ───────────────────
# Every routing decision passes through mcpRedirect() in
# hooks/core/mcp-ready.mjs, which returns null unless isMCPReady() finds a
# live MCP server: it scans a directory for context-mode-mcp-ready-<PID>
# files and probes each PID. No MCP server runs during a build, so a probe
# without a sentinel gets empty output on EVERY build — a guard that fails
# closed for a reason that has nothing to do with the tree it guards.
# CONTEXT_MODE_MCP_SENTINEL_DIR is upstream's own override for exactly this;
# it points at a private directory here, seeded with one sentinel naming this
# shell's (live) PID.
#
# Private rather than the build's /tmp, because upstream's default scan root
# is a hardcoded /tmp and a probe run there is satisfied by ANY unrelated
# process's sentinel. That is not hypothetical: a probe run on a developer
# host returned a decision and was recorded as a pass while reading that
# session's own running context-mode server's sentinel out of the shared
# /tmp. The empty-sentinel run below is the control that makes the seeded run
# mean something — it asserts the probe returns NOTHING before the sentinel
# is written, so a pass cannot be arriving from anywhere else.
#
# ── Why the probe scrubs node off PATH ──────────────────────────────────────
# The hook runs with PATH=/usr/bin:/bin, which has no Node on it, so the
# command has to name its own interpreter. Measured against v1.0.169 on this
# image's default Node 20, an un-rewritten `node "…/pretooluse.mjs"` still
# answers `deny` — the WebFetch route is pure JS and runHook swallows
# everything else — so a probe that inherited the build PATH would pass on a
# tree the substitution above had missed. It would also CORRUPT that tree:
# ensure-deps' ABI heal fires below Node 22.5, `npm rebuild better-sqlite3`
# runs with the build's network, and the tree comes back carrying the
# devDependencies --omit=dev just excluded and a better-sqlite3 the pinned
# Node can no longer load — after the loader check above has already passed.
# With node unresolvable an un-rewritten command produces nothing and fails
# the layer, which is the whole point.
#
# The probe does leave one thing behind: under the pinned Node, ensure-deps
# copies the native binary to better_sqlite3.abi<N>.node. That is the whole of
# what the probe changes in the staged tree — the ABI cache a session would
# otherwise write on its first hook, pre-seeded.
#
# ── Why a commit SHA beside the tag ─────────────────────────────────────────
# A git tag is mutable. Upstream can move v1.0.169, and `git clone --depth 1
# --branch` takes whatever the tag resolves to at build time, which for a tree
# that then executes inside every enabled session is not a pin at all.
# CONTEXT_MODE_PLUGIN_SHA is compared against `git rev-parse HEAD` while the
# clone still has its .git directory, so a moved tag fails the layer instead
# of staging code nobody read. Same limit the bun digests above spell out: it
# catches the bytes behind a fixed tag changing after the SHA was transcribed,
# not a tag that was already pointing somewhere else when it was.
#
# To refresh:
#   1. Pick a new tag at https://github.com/mksglu/context-mode/tags
#   2. Resolve it to the commit a clone will report. Upstream's tags are
#      ANNOTATED, so it is the ^{} deref that matters — the bare ref names the
#      tag object, which is NOT what `git rev-parse HEAD` prints:
#        git ls-remote https://github.com/mksglu/context-mode.git \
#          "refs/tags/<TAG>^{}"
#   3. Regenerate the lockfile against that tree, with an npm running on
#      Node >= 22.5 — upstream's postinstall hard-exits below that, and the
#      resolution npm records is what every later build then installs:
#        git clone --depth 1 --branch <TAG> \
#          https://github.com/mksglu/context-mode.git /tmp/cm
#        npm install --package-lock-only --no-audit --no-fund --prefix /tmp/cm
#        cp /tmp/cm/package-lock.json container/context-mode-package-lock.json
#      No --omit=dev on that command. npm records the devDependencies in the
#      lockfile either way; the flag belongs at install time, not here.
#   4. Update CONTEXT_MODE_PLUGIN_REF + CONTEXT_MODE_PLUGIN_SHA below and
#      CONTEXT_MODE_VERSION above, all three, to the same release.
ARG CONTEXT_MODE_PLUGIN_REF=v1.0.169
ARG CONTEXT_MODE_PLUGIN_SHA=589d8214d56740a28b5f7bf63167743d586b0b40
ENV RIOTBOX_CM_PLUGIN_DIR=/home/llm/.riotbox/context-mode-plugin

# In container/ rather than packaging/: packaging/ holds nfpm maintainer
# scripts and is deliberately NOT installed to /opt/riotbox (nfpm.yaml
# contents, install.sh APP_PATHS), while `riotbox build` runs from that
# install tree — so a COPY source there resolves in the dev repo and nowhere
# else.
#
# Staged outside ${dest}, not into it: `git clone` below needs an empty target
# directory, so a COPY landing the lockfile there first would fail the clone.
# The RUN moves it into place between the clone and npm ci, which is the only
# directory npm ci will read a lockfile from.
COPY --chown=llm:llm container/context-mode-package-lock.json \
    /tmp/context-mode-package-lock.json

# The matcher set the staged tree is required to ship, staged the same way and
# for the same reason as the lockfile above: it is a build input, and a COPY is
# the only way it reaches a build that runs from the installed app tree.
#
# Regenerate it with the ref bump, from the tree the clone produces:
#   jq -S '.hooks | map_values([.[].matcher])' \
#       "${dest}/hooks/hooks.json" > container/context-mode-hooks-expected.json
# and review the diff — a change here is upstream reshaping what a session
# intercepts, which is a decision to make deliberately, not a file to refresh
# until the build goes green.
COPY --chown=llm:llm container/context-mode-hooks-expected.json \
    /tmp/context-mode-hooks-expected.json

# The npm cache strip near the end is the one "Why every npm layer empties
# /home/llm/.npm" explains. It runs after the loader and routing probes, which
# are the last things in this layer that read the staged tree.
RUN bash -o pipefail -c '\
    set -e; \
    export NVM_DIR=/home/llm/.nvm; \
    . "${NVM_DIR}/nvm.sh"; \
    CM_NODE_EXE="$(nvm which "${CONTEXT_MODE_NODE}")"; \
    CM_NODE_BIN="$(dirname "${CM_NODE_EXE}")"; \
    dest="${RIOTBOX_CM_PLUGIN_DIR}/${CONTEXT_MODE_PLUGIN_REF}"; \
    mkdir -p "${dest}"; \
    git clone --depth 1 --branch "${CONTEXT_MODE_PLUGIN_REF}" \
        https://github.com/mksglu/context-mode.git "${dest}"; \
    cloned="$(git -C "${dest}" rev-parse HEAD)"; \
    [ "${cloned}" = "${CONTEXT_MODE_PLUGIN_SHA}" ] || { \
        echo "${CONTEXT_MODE_PLUGIN_REF} resolves to ${cloned}, pinned ${CONTEXT_MODE_PLUGIN_SHA} — the tag moved, or the pin was not bumped with the ref" >&2; \
        exit 1; }; \
    rm -rf "${dest}/.git"; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/agents/registry.sh; \
    agent_call claude context_mode_build_assert "${dest}" \
        || { echo "the staged plugin at ${CONTEXT_MODE_PLUGIN_REF} broke the claude Context Mode contract (above) — this is the tree a session runs" >&2; exit 1; }; \
    hooks="${dest}/hooks/hooks.json"; \
    [ -r "${hooks}" ] || { echo "staged plugin has no hooks/hooks.json" >&2; exit 1; }; \
    cm_table="$(jq -Sc ".hooks | map_values([.[].matcher])" "${hooks}")"; \
    cm_expected_table="$(jq -Sc . /tmp/context-mode-hooks-expected.json)"; \
    [ "${cm_table}" = "${cm_expected_table}" ] || { \
        echo "the staged hook table is not the one container/context-mode-hooks-expected.json pins — a session would wire a different event set, or intercept a different set of tools, than this image was reviewed against" >&2; \
        echo "  expected: ${cm_expected_table}" >&2; \
        echo "  staged:   ${cm_table}" >&2; \
        exit 1; }; \
    rm -f /tmp/context-mode-hooks-expected.json; \
    mv /tmp/context-mode-package-lock.json "${dest}/package-lock.json"; \
    PATH="${CM_NODE_BIN}:${PATH}" \
        "${CM_NODE_BIN}/npm" ci --omit=dev --no-audit --no-fund --prefix "${dest}"; \
    "${CM_NODE_EXE}" -e "const { createRequire } = require(\"node:module\"); \
        const r = createRequire(\"${dest}/package.json\"); \
        for (const m of [\"better-sqlite3\", \"turndown\", \"turndown-plugin-gfm\", \"@mixmark-io/domino\"]) r.resolve(m); \
        new (r(\"better-sqlite3\"))(\":memory:\").close();" \
        || { echo "the staged plugin cannot load better-sqlite3 (or an esbuild external the bundles need) under ${CM_NODE_EXE} — every session start would run npm install at hook time" >&2; exit 1; }; \
    before="$(jq -r "[.hooks[][].hooks[].command] | map(select(startswith(\"node \"))) | length" "${hooks}")"; \
    [ "${before}" -gt 0 ] || { \
        echo "no hooks.json command invokes a bare node — upstream changed the command shape" >&2; \
        exit 1; }; \
    jq --arg node "${CM_NODE_EXE}" \
        "(.hooks[][].hooks[].command) |= (if startswith(\"node \") then \$node + .[4:] else . end)" \
        "${hooks}" > "${hooks}.tmp"; \
    mv "${hooks}.tmp" "${hooks}"; \
    after="$(jq -r "[.hooks[][].hooks[].command] | map(select(startswith(\"node \"))) | length" "${hooks}")"; \
    [ "${after}" -eq 0 ] || { \
        echo "${after} hooks.json commands still invoke a bare node after the substitution" >&2; \
        exit 1; }; \
    pj="${dest}/.claude-plugin/plugin.json"; \
    [ -r "${pj}" ] || { echo "staged plugin has no .claude-plugin/plugin.json — nothing can register it" >&2; exit 1; }; \
    [ "$(jq -r ".mcpServers[\"context-mode\"].command" "${pj}")" = "node" ] || { \
        echo "plugin.json no longer declares a bare node for the context-mode MCP server — the interpreter pin has nothing to replace" >&2; \
        exit 1; }; \
    jq --arg node "${CM_NODE_EXE}" ".mcpServers[\"context-mode\"].command = \$node" \
        "${pj}" > "${pj}.tmp"; \
    mv "${pj}.tmp" "${pj}"; \
    [ "$(jq -r ".mcpServers[\"context-mode\"].command" "${pj}")" = "${CM_NODE_EXE}" ] || { \
        echo "plugin.json still does not name ${CM_NODE_EXE} after the substitution" >&2; \
        exit 1; }; \
    cm_pre="$(jq -r "first(.hooks.PreToolUse[] | select(.matcher == \"WebFetch\") | .hooks[].command)" "${hooks}")"; \
    [ -n "${cm_pre}" ] || { \
        echo "hooks.json no longer routes WebFetch through a PreToolUse command — upstream reshaped the matcher set and the routing probe has nothing to run" >&2; \
        exit 1; }; \
    cm_probe="$(mktemp -d)"; \
    mkdir -p "${cm_probe}/sentinel" "${cm_probe}/tmp"; \
    cm_payload="{\"session_id\":\"riotbox-build-probe\",\"cwd\":\"${cm_probe}\",\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://example.invalid/riotbox-build-probe\"}}"; \
    cm_route() { printf "%s" "${cm_payload}" \
        | env PATH=/usr/bin:/bin HOME="${cm_probe}" TMPDIR="${cm_probe}/tmp" \
              CLAUDE_PLUGIN_ROOT="${dest}" CONTEXT_MODE_PLATFORM=claude-code \
              CONTEXT_MODE_MCP_SENTINEL_DIR="${cm_probe}/sentinel" \
              sh -c "${cm_pre}" \
        | jq -r ".hookSpecificOutput.permissionDecision // empty"; }; \
    cm_decision="$(cm_route)" || cm_decision=""; \
    [ -z "${cm_decision}" ] || { \
        echo "the routing probe decided \"${cm_decision}\" with its sentinel directory empty — it is reading an MCP sentinel it did not seed, so a pass would prove nothing" >&2; \
        exit 1; }; \
    printf "%s" "$$" > "${cm_probe}/sentinel/context-mode-mcp-ready-$$"; \
    cm_decision="$(cm_route)" || cm_decision=""; \
    [ -n "${cm_decision}" ] || { \
        echo "the staged plugin returned no PreToolUse decision for WebFetch — Context Mode would report itself enabled and route nothing, which is the bug this probe exists to catch" >&2; \
        if [ -s "${cm_probe}/.claude/context-mode/hook-errors.log" ]; then cat "${cm_probe}/.claude/context-mode/hook-errors.log" >&2; fi; \
        exit 1; }; \
    rm -rf "${cm_probe}"; \
    find /home/llm/.npm -mindepth 1 -delete; \
    echo "staged context-mode plugin ${CONTEXT_MODE_PLUGIN_REF} at ${dest} ($(du -sh "${dest}" | cut -f1)) — PreToolUse routes WebFetch to ${cm_decision}"'

# ── Context Mode event bridge: neutralized ───────────────────────────────────
# The PostToolUse / UserPromptSubmit / PreCompact / Stop hooks all route through
# attributeAndInsertEvents, which POSTs every event to ${platform_url}/events
# when a config file exists (hooks/platform-bridge.mjs). The gate is file
# presence: absent → readConfig() null → hasPlatformConfig() false → the
# per-event loop never runs.
#
# So the barrier is on the *containing directory*, not on the filename. Both
# directories platform-bridge.mjs resolves are created root-owned and 0555
# (XDG_CONFIG_HOME is unset in this image, so the default ~/.context-mode
# applies; ~/.config/context-mode is covered for a session that sets it).
# platform.json is therefore genuinely absent — the gate is closed — and
# nothing running as llm can create it.
#
# Taking the platform.json name itself, with a root-owned directory, closes the
# gate just as well but not quietly: readConfig() suppresses its warning for
# ENOENT alone, so an unreadable file makes every guarded hook print
# "[context-mode] cannot read …: EISDIR" to stderr. Upstream's one-shot latch
# does not help, because each hook dispatch is a fresh node process — and
# PostToolUse fires on nearly every tool call. An operator would reasonably
# read that stream of warnings as a real error. An absent file is the only
# rejection readConfig() takes silently.
#
# Nothing in the package writes anything else under these directories —
# platform.json is the only file it names there — so read-only breaks nothing.
#
# What this is: a barrier against inadvertent activation — upstream code writing
# the file, a stray setup flow, a copied dotfile. What it is not: a security
# boundary. llm holds NOPASSWD sudo, and it owns the grandparents (/home/llm and
# /home/llm/.config), so it can move a directory aside and recreate it writable
# without root at all. Deliberate activation stays possible;
# RIOTBOX_NETWORK=none is the hard control. See THREAT_MODEL.md.
USER root
RUN for d in /home/llm/.context-mode /home/llm/.config/context-mode; do \
        mkdir -p "${d}"; \
        chown root:root "${d}"; \
        chmod 0555 "${d}"; \
    done
USER llm
RUN for d in /home/llm/.context-mode /home/llm/.config/context-mode; do \
        [ -d "${d}" ]; \
        [ ! -w "${d}" ]; \
        [ ! -e "${d}/platform.json" ]; \
    done

# ── Pre-stage plugins (no auth needed — just clones a public GitHub repo) ────
# Installed to a staging dir because ~/.claude is bind-mounted at runtime.
# The entrypoint copies from here into the session dir on first run, avoiding
# network access and ~14 Node.js process spawns at startup.
RUN STAGING_DIR=/home/llm/.riotbox/plugins-staging/.claude && \
    mkdir -p "${STAGING_DIR}/plugins/cache" && \
    CLAUDE_CONFIG_DIR="${STAGING_DIR}" claude plugin marketplace add anthropics/claude-plugins-official && \
    for p in \
        superpowers ralph-loop \
        frontend-design feature-dev code-simplifier commit-commands \
        security-guidance claude-code-setup claude-md-management; do \
        CLAUDE_CONFIG_DIR="${STAGING_DIR}" claude plugin install "$p" || true; \
    done

# ═════════════════════════════════════════════════════════════════════════════
# Build flavor: riotbox-gh-glab (opt-in, RIOTBOX_GH_GLAB=1)
# ═════════════════════════════════════════════════════════════════════════════
# Adds the gh and glab CLIs plus the GitHub MCP server binary, and ships the
# four commands that wire the GitHub and GitLab MCP servers into every agent on
# demand. Build it with `task container:build-gh-glab`, which tags the result
# riotbox-gh-glab so it sits beside the base image rather than replacing it.
#
# ── Why this block is at the very bottom of the file ────────────────────────
#
# ARG invalidates the layer cache from the point it is USED, and everything
# after that point rebuilds. RIOTBOX_DIAGRAMS (near the top) is the pattern this
# follows but deliberately not the placement: it gates a base system package, so
# it has to be consumed early and a diagrams build genuinely does rebuild the
# world. This flavor is two rpms and one static binary. Consumed last, the base
# image and the flavor share every layer up to this one, and building the flavor
# after the base costs a minute instead of an hour.
#
# tests/gh-glab-build.venom.yml asserts this ARG stays in the last tenth of the
# file, because losing the property costs an hour per build and is invisible in
# a build that otherwise succeeds.

# The commands are copied unconditionally — COPY cannot be made conditional, and
# they are inert here. ~/.riotbox is a library directory: nothing runs anything
# from it unprompted, and only the flavor below puts these on PATH. Copying them
# in every image keeps one COPY instead of a duplicated conditional one.
COPY --chown=llm:llm container/forge-mcp.sh /home/llm/.riotbox/forge-mcp.sh
COPY --chown=llm:llm container/enable_github_mcp /home/llm/.riotbox/enable_github_mcp
COPY --chown=llm:llm container/enable_gitlab_mcp /home/llm/.riotbox/enable_gitlab_mcp
COPY --chown=llm:llm container/disable_github_mcp /home/llm/.riotbox/disable_github_mcp
COPY --chown=llm:llm container/disable_gitlab_mcp /home/llm/.riotbox/disable_gitlab_mcp

ARG RIOTBOX_GH_GLAB=0

# github-mcp-server — GitHub's own MCP server (https://github.com/github/github-mcp-server)
# Pinned per supply-chain review, same treatment as venom in the tools stage.
# Upstream DOES publish a checksums file, but fetching it at build time would
# authenticate the download against a file from the same unauthenticated place,
# which proves nothing. The digests are therefore pinned here, transcribed once
# from that file at review time. To refresh:
#   1. Pick a new tag at https://github.com/github/github-mcp-server/releases
#   2. Read the Linux digests out of the release's checksums file:
#        curl -sL "https://github.com/github/github-mcp-server/releases/download/<TAG>/github-mcp-server_<VER>_checksums.txt" \
#          | grep -E 'Linux_(x86_64|arm64)'
#   3. Update the three ARGs below (VERSION carries the leading v, the
#      tarball name does not)
ARG GITHUB_MCP_SERVER_VERSION=v1.10.1
ARG GITHUB_MCP_SERVER_SHA256_AMD64=c2629e850a344275cfc5a1590acdfd8c11476a44b688812d460163768e05572d
ARG GITHUB_MCP_SERVER_SHA256_ARM64=c51dc6cf192c35a328b9f71696d42c38a9a3ba3c2ffe010da836bed071d1ac8a

# Root for the rpm install and for writing to /usr/local/bin; back to llm at the
# end, since the entrypoint and every agent run as llm.
#
# gh and glab both come from EPEL, which is already enabled in the system
# packages layer. One provenance model, distro-signed, no checksum table to
# maintain by hand — at the cost of trailing upstream by a few releases.
#
# hadolint ignore=DL3041
USER root
RUN if [ "${RIOTBOX_GH_GLAB}" = "1" ]; then \
        dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
            gh glab \
        && dnf clean all \
        && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info \
        && bash -o pipefail -c '\
            ARCH=$(uname -m | sed "s/aarch64/arm64/") && \
            case "${ARCH}" in \
                x86_64) EXPECTED_SHA="'"${GITHUB_MCP_SERVER_SHA256_AMD64}"'" ;; \
                arm64)  EXPECTED_SHA="'"${GITHUB_MCP_SERVER_SHA256_ARM64}"'" ;; \
                *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;; \
            esac && \
            VER="'"${GITHUB_MCP_SERVER_VERSION}"'" && \
            curl -fsSLo /tmp/gh-mcp.tar.gz \
                "https://github.com/github/github-mcp-server/releases/download/${VER}/github-mcp-server_Linux_${ARCH}.tar.gz" && \
            echo "${EXPECTED_SHA}  /tmp/gh-mcp.tar.gz" | sha256sum -c - && \
            tar -xzf /tmp/gh-mcp.tar.gz -C /tmp github-mcp-server && \
            install -m 0755 /tmp/github-mcp-server /usr/local/bin/github-mcp-server && \
            rm -f /tmp/gh-mcp.tar.gz /tmp/github-mcp-server' \
        && for c in enable_github_mcp enable_gitlab_mcp disable_github_mcp disable_gitlab_mcp; do \
               ln -sf "/home/llm/.riotbox/${c}" "/home/llm/.local/bin/${c}"; \
           done; \
    fi
USER llm

# Fail the build, not a user session, when the flavor did not come out whole.
# Each of these is something a user would otherwise discover as a missing
# command halfway through a task: an EPEL package renamed, a release asset gone,
# a symlink pointing at a file that was never copied. The final disable_github_mcp
# call is an execution probe, not just a PATH probe: a command can resolve on
# PATH and still fail to find its own library, which command -v and -x cannot
# catch (see the four commands' BASH_SOURCE-vs-symlink history).
RUN if [ "${RIOTBOX_GH_GLAB}" = "1" ]; then \
        gh --version && \
        glab --version && \
        github-mcp-server --version && \
        for c in enable_github_mcp enable_gitlab_mcp disable_github_mcp disable_gitlab_mcp; do \
            command -v "${c}" >/dev/null || { echo "${c} is not on PATH" >&2; exit 1; }; \
            [ -x "/home/llm/.riotbox/${c}" ] || { echo "${c} is not executable" >&2; exit 1; }; \
        done && \
        { disable_github_mcp || { echo "disable_github_mcp failed when invoked through PATH" >&2; exit 1; }; }; \
    fi
