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
# The base deliberately floats on the `stream10` tag rather than a digest:
# every rebuild picks up the current Stream 10 compose and its security
# fixes, and the dnf packages installed below float with it anyway (DL3041).
# Both `FROM` lines (tools + runtime) MUST name the same reference so the
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
# compose, and the base image floats with them (see the top of this file).
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
ARG GIT_AI_VERSION=v1.7.6
ARG GIT_AI_SHA256_AMD64=f6cda0cb43c1c9a3d68e7efe2d79577680ea6f382c31bf36a2162906f93f6c1c
ARG GIT_AI_SHA256_ARM64=1326abd5547636e6b6b297ad79afc955e57e82361efac320d4f860147b95a87a
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
# Same floating reference as the tools stage; both `FROM` lines must name
# the same image (see the top of the tools stage).
FROM quay.io/centos/centos:stream10 AS runtime

# Pipefail policy: see the tools stage's comment. RUN steps that pipe
# wrap themselves in `bash -o pipefail -c '…'` instead of relying on a
# Dockerfile SHELL directive (which OCI image config doesn't support).

# ── Build args (populated by build.sh from host introspection) ────────────────
ARG NVM_INSTALLER_VERSION=0.41.0
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
        # The shell config below exports LANG/LC_ALL=en_US.UTF-8, and this is
        # what makes that locale exist. glibc requires the virtual provide
        # `glibc-langpack`, which glibc-minimal-langpack — all the base layer
        # ships — satisfies with C.utf8 alone. Left to dnf, whether en_US.UTF-8
        # landed in an image was an accident of how that provide resolved on
        # build day, and an image that lost the coin flip printed
        # "setlocale: LC_ALL: cannot change locale" from every shell it started.
        # 5.7 MB installed, against the size hygiene noted above.
        glibc-langpack-en \
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
        sqlite \
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
    # fd-find: Pi's find tool otherwise downloads an unpinned fd from GitHub into ~/.pi/agent/bin.
    && dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
           ripgrep fd-find bats \
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
# is impractical here, so semgrep floats like the base image, and the
# install is checked at build time (semgrep --version). Use a requirements
# file for prod.
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
# A HOST_GID the base image already uses (gid 20 is `games`) falls back to
# useradd's default ids, which differ from the host's; say so in the build log.
# A taken HOST_UID fails the build in useradd, with useradd's own message.
RUN if groupadd -g ${HOST_GID} llm; then \
        useradd -l -m -u ${HOST_UID} -g llm -s /bin/bash llm; \
    else \
        echo "WARNING: HOST_GID ${HOST_GID} is taken in the base image; llm gets default ids, not ${HOST_UID}:${HOST_GID}" >&2; \
        useradd -l -m -s /bin/bash llm; \
    fi && \
    mkdir -p /workspace && chown llm /workspace && \
    echo "llm ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/llm && \
    # env_reset would drop the egress proxy variables, so keep them for
    # `sudo dnf install` under RIOTBOX_EGRESS=1.
    echo 'Defaults:llm env_keep += "http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY"' >> /etc/sudoers.d/llm && \
    visudo -cf /etc/sudoers.d/llm && \
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
        -exec rm -rf {} +

# ── Security tools + task/venom from builder stage ───────────────────────────
COPY --from=tools --chown=llm:llm /tools/bin/ /home/llm/.local/bin/

# ── Fixed paths (set after useradd so HOME points to the real user dir) ──────
ENV HOME=/home/llm
ENV NVM_DIR=/home/llm/.nvm
ENV GOPATH=/home/llm/go
# The distro's /usr/lib/golang/go.env pins GOTOOLCHAIN=local, so a module whose
# go.mod requires a newer Go than the packaged one fails to build or install.
# auto fetches that toolchain from the module proxy, verified against GOSUMDB.
ENV GOTOOLCHAIN=auto
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
# shfmt and go-global-update are developer tools tracked at @latest for the same
# reason: the image is rebuilt to refresh them, not to reproduce an old version.
# hadolint ignore=DL3062
RUN if command -v go >/dev/null 2>&1; then \
        mkdir -p /home/llm/go /home/llm/.cache/go-build && \
        go install golang.org/x/tools/gopls@latest && \
        go install mvdan.cc/sh/v3/cmd/shfmt@latest && \
        go install github.com/Gelio/go-global-update@latest; \
    fi

# ── User-phase config (mount targets, podman, gem, git, shell) ───────────────
# All lightweight config writes combined into one layer.
# SC2088: the quoted ~ in core.excludesFile is deliberate. git expands it at
# read time, so the setting follows $HOME rather than baking the build's path.
# hadolint ignore=SC2088
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
    git config --global worktree.useRelativePaths true && \
    # build.sh stages ~/.gitignore_global (the host's own, or the shipped
    # container/gitignore_global when the host has none), but git only reads a
    # global ignore file that core.excludesFile names. Not include.path: that
    # parses its target as config, and ignore patterns are not config. git
    # also tolerates the file being absent, so deleting it is safe.
    git config --global core.excludesFile '~/.gitignore_global' && \
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

# Same reasoning for the CLIs and scanners baked into the image: their
# versions are pinned here, so a startup update check only leaks traffic.
# glab and trivy also send telemetry, and neither honors the DO_NOT_TRACK
# the entrypoint exports (gh does), so each needs its own opt-out.
export GLAB_CHECK_UPDATE=false
export GLAB_SEND_TELEMETRY=false
export GH_NO_UPDATE_NOTIFIER=1
export GRYPE_CHECK_FOR_APP_UPDATE=false
export SYFT_CHECK_FOR_APP_UPDATE=false
export TRIVY_SKIP_VERSION_CHECK=true
export TRIVY_DISABLE_TELEMETRY=true

# context-mode has no opt-out to set here: 2.x makes no startup or background
# calls and sends no telemetry. Its one automatic call is the version check in
# the ctx_doctor tool (npm dist-tags, then git ls-remote), run only when the
# agent calls that tool, with no off-switch (src/core/ops/doctor-env.ts:92,184
# upstream; see THREAT_MODEL.md). RIOTBOX_NETWORK=none or RIOTBOX_EGRESS=1
# (neither npm nor GitHub is on an agent's allowlist) are what stop it.

# Not on Debian, but some scripts check this to skip interactive prompts
export DEBIAN_FRONTEND=noninteractive

# Bigger history — useful when Claude needs to review what it already ran
export HISTSIZE=10000
export HISTFILESIZE=10000
# ignoreboth = ignorespace + ignoredups. A command typed with a leading space
# (` export TOKEN=…`) stays out of ~/.bash_history, so secrets need not land
# on disk; repeated commands are recorded once.
export HISTCONTROL=ignoreboth
# Timestamp each entry so the history shows when a command ran, not just
# that it did — the first question when reconstructing a session.
export HISTTIMEFORMAT='%F %T '

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
# OS plugins (os/<ID>/): in an egress session the entrypoint points the
# distro's package manager at its own mirror (scripts/lib/egress-os.sh).
COPY --chown=llm:llm os/ /home/llm/.riotbox/os/
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
COPY --chown=llm:llm container/run-main.sh /home/llm/.riotbox/run-main.sh
COPY --chown=llm:llm container/nested-podman-setup.sh /home/llm/.riotbox/nested-podman-setup.sh
COPY --chown=llm:llm container/headroom-summary.sh /home/llm/.riotbox/headroom-summary.sh
COPY --chown=llm:llm container/codegraph-setup.sh /home/llm/.riotbox/codegraph-setup.sh
COPY --chown=llm:llm container/context-mode-setup.sh /home/llm/.riotbox/context-mode-setup.sh
COPY --chown=llm:llm container/context-mode-summary.sh /home/llm/.riotbox/context-mode-summary.sh
COPY --chown=llm:llm container/context-mode-stats.mjs /home/llm/.riotbox/context-mode-stats.mjs
COPY --chown=llm:llm container/git-ai-setup.sh /home/llm/.riotbox/git-ai-setup.sh
COPY --chown=llm:llm container/anywhere.sh /home/llm/.riotbox/anywhere.sh
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
    /home/llm/.riotbox/run-main.sh \
    /home/llm/.riotbox/nested-podman-setup.sh /home/llm/.riotbox/headroom-summary.sh \
    /home/llm/.riotbox/codegraph-setup.sh /home/llm/.riotbox/context-mode-setup.sh \
    /home/llm/.riotbox/context-mode-summary.sh /home/llm/.riotbox/git-ai-setup.sh \
    /home/llm/.riotbox/anywhere.sh
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
# Pi, Claude Code, CodeGraph, bun, Context Mode, the OpenCode plugin smoke,
# plugins) to rebuild and re-pull latest — without rebuilding the whole image.
# A normal `task container:build` always passes the default (0), so the
# boundary stays cached and the tools are reused. Those tool RUNs are
# intentionally left unchanged; the boundary alone controls their freshness.
# The list above is the inventory — deliberately not a count, because the one
# this replaced went stale the moment a layer was added below the boundary.
#
# The remaining RUNs below the boundary are cheap or inert. The gh/glab block
# does nothing unless RIOTBOX_GH_GLAB=1 selected that flavor — where an update
# also re-installs gh and glab from EPEL.
#
# headroom, CodeGraph, bun and Context Mode are version-pinned, so an update
# re-installs them unchanged, re-fetching identical bytes:
#   * the same headroom wheels and ~350 MB of models
#   * the same CodeGraph npm package (no model download)
#   * the same ~34 MB bun release zip, re-downloaded and re-verified against
#     the pinned digest
#   * the same Context Mode npm package, `npm ci` against the committed
#     lockfile and put back through the build asserts and the routing probe,
#     which additionally re-runs `nvm install`; PI_NODE equals
#     CONTEXT_MODE_NODE, so the Pi layer re-downloads the pinned Node and
#     Context Mode's `nvm install` reuses it
# The cost is accepted so `riotbox update` can add all of them to images built
# before they existed and refresh headroom's unpinned transitive deps.
# The OpenCode plugin smoke is what makes `update` re-gate V2: it re-loads all
# three plugins against the freshly installed opencode.
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
# The smoke test then runs the proxy the way a session does — `headroom
# proxy --memory --no-learn`, offline, HEADROOM_MEMORY_DB_PATH set, in a
# throwaway HOME — and waits for /livez to answer as headroom
# (proxy/server.py:4437-4452) and for its log to say the memory backend came
# up at that path with the ONNX embedder ("Memory: Initialized LocalBackend at
# <db> (embedder: onnx)", proxy/memory_handler.py:408-411) and that the
# embedder then really encoded something ("Memory: embedder warm-up encode
# complete", :2147). The first line is logged before the model loads, and a
# failed warm-up only logs "Memory: embedder warm-up failed" (:2150) and
# carries on, so the smoke fails on that line at once. That proves the
# pre-warmed model cache and the memory path end to end, and a pin that
# regresses the embedder to the torch default (excluded here) fails THIS layer
# instead of a user session. It also asserts nothing went to $HOME/.headroom
# instead. The DB's directory is created first: headroom does not create it
# ("unable to open database file"); in a session it is the state-dir mount.
# Through this release the smoke ran `python -m headroom.memory.sync`, the
# command `headroom wrap claude --memory` spawns; no session runs it any more.
# PYTHONPATH is pinned to the user site because overriding HOME hides pip's
# --user dir. The hf-xet chunk cache is transfer-time scratch — the offline
# loads above prove the hub cache alone suffices, so it is removed.
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
ARG HEADROOM_VERSION=0.43.0
# DL3001: the `kill` stops the smoke test's own background proxy, not a
# service in the image.
# hadolint ignore=DL3001
RUN pip3 install --user --no-cache-dir --break-system-packages \
        "headroom-ai[proxy,code]==${HEADROOM_VERSION}" || { echo "headroom layer: pip install of headroom-ai ${HEADROOM_VERSION} failed" >&2; exit 1; }; \
    /home/llm/.local/bin/headroom --version || { echo "headroom layer: the installed headroom does not run" >&2; exit 1; }; \
    HEADROOM_KOMPRESS_CANARY_SECONDS=0 python3 -c "from headroom.transforms.kompress_compressor import KompressCompressor; \
print('kompress backend:', KompressCompressor().preload(allow_download=True))" || { echo "headroom layer: downloading the Kompress model failed" >&2; exit 1; }; \
    python3 -c "from headroom.onnx_runtime import hf_hub_download_local_first as d; \
[d('Qdrant/all-MiniLM-L6-v2-onnx', f) for f in ('model.onnx', 'tokenizer.json')]" || { echo "headroom layer: downloading the MiniLM embedder failed" >&2; exit 1; }; \
    HF_HUB_OFFLINE=1 HEADROOM_KOMPRESS_CANARY_SECONDS=0 python3 -c "from headroom.transforms.kompress_compressor import KompressCompressor; \
KompressCompressor().preload(allow_download=False)" || { echo "headroom layer: the Kompress model does not load offline from the cache" >&2; exit 1; }; \
    HF_HUB_OFFLINE=1 python3 -c "from headroom.onnx_runtime import hf_hub_download_local_first as d; \
[d('Qdrant/all-MiniLM-L6-v2-onnx', f, allow_network=False) for f in ('model.onnx', 'tokenizer.json')]" || { echo "headroom layer: the MiniLM embedder does not load offline from the cache" >&2; exit 1; }; \
    USERSITE="$(python3 -m site --user-site)" && \
    SMOKE="$(mktemp -d)" && mkdir "${SMOKE}/state" && \
    { env -C "${SMOKE}" HOME="${SMOKE}" HF_HUB_OFFLINE=1 HF_HOME=/home/llm/.cache/huggingface \
        PYTHONPATH="${USERSITE}" HEADROOM_MEMORY_DB_PATH="${SMOKE}/state/memory.db" \
        /home/llm/.local/bin/headroom proxy --port 18999 --memory --no-learn \
        >"${SMOKE}/proxy.out" 2>&1 & } && \
    PID=$! && READY="" && LINE="" && WARM="" && \
    for _ in $(seq 1 180); do \
        if [ -z "${READY}" ] && python3 -c "import json, sys, urllib.request as u; \
b = json.load(u.urlopen('http://127.0.0.1:18999/livez', timeout=2)); \
sys.exit(0 if b.get('service') == 'headroom-proxy' and b.get('status') == 'healthy' else 1)" 2>/dev/null; then READY=1; fi; \
        LOG="${SMOKE}/.headroom/logs/proxy-18999.log"; \
        if grep -qF "Memory: embedder warm-up failed" "${LOG}" 2>/dev/null; then WARM=failed; break; fi; \
        if [ -n "${READY}" ] && grep -qF "Memory: Initialized LocalBackend at ${SMOKE}/state/memory.db (embedder: onnx)" "${LOG}" 2>/dev/null && \
            grep -qF "Memory: embedder warm-up encode complete" "${LOG}"; then LINE=1; WARM=ok; break; fi; \
        kill -0 "${PID}" 2>/dev/null || break; \
        sleep 1; \
    done; \
    kill "${PID}" 2>/dev/null; wait "${PID}" 2>/dev/null; \
    if [ -z "${READY}" ] || [ -z "${LINE}" ] || [ "${WARM}" != ok ] || [ ! -s "${SMOKE}/state/memory.db" ] || [ -e "${SMOKE}/.headroom/memory.db" ]; then \
        echo "headroom proxy smoke failed (ready=${READY:-no} memory-line=${LINE:-no} embedder-warm-up=${WARM:-none})" >&2; \
        cat "${SMOKE}/proxy.out" "${SMOKE}/.headroom/logs/proxy-18999.log" >&2; exit 1; \
    fi && \
    rm -rf "${SMOKE}" && \
    rm -rf /home/llm/.cache/huggingface/xet

# ── opencode (installed alongside Claude Code) ───────────────────────────────
# The image installs OpenCode 2 from the V2 installer. The V1 installer
# (opencode.ai/install) refuses to install 2.x, so it cannot be used here.
# The V2 installer hardcodes the install target at $HOME/.opencode/bin and
# modifies .bashrc to extend PATH. Skip the .bashrc modification with
# --no-modify-path (we manage PATH explicitly in the image), then move the
# binary into the existing user-local bin dir so no extra PATH entry is
# needed. The installer also drops an `opencode2` shim beside the binary that
# execs its sibling `opencode`. The move strands it, so it would dangle, and
# nothing uses it; remove it. The now-empty .opencode/bin directory is not on
# PATH and is left in place, harmless.
#
# Deliberately unpinned: the installer resolves the latest release, and we want
# opencode to track upstream. The 2.0.0 floor is there because V1 plugins do not
# load in V2, so an image that quietly resolved to 1.x would ship sessions with
# the wired plugins doing nothing. Whether the wired plugins still load in a
# newer 2.x is checked against the real binary by container/opencode/smoke.sh,
# which the smoke layer below runs. The floor also covers --auto, the flag
# agents/opencode/manifest.sh injects for autonomous runs. opencode's parser is
# strict, so a build without --auto would fail loudly, but in the user's
# session, at the moment they tried to work. Assert it here instead, where the
# failure names what moved and costs a rebuild rather than a debugging session.
#
# The version command prints `opencode vX.Y.Z`, and sort -VC compares whole
# lines, so any output that is not a bare X.Y.Z (the word, the `v`, a banner)
# sorts above the floor and passes the check vacuously. Pull the bare version
# out first, accepting `opencode vX.Y.Z`, `opencode X.Y.Z`, `vX.Y.Z` and
# `X.Y.Z`, and fail the build when there isn't one, so a change in upstream's
# output format cannot silently retire the guard. sed takes the first matching
# line and quits, reading a here-string: there is no pipe, so no stage can die
# of SIGPIPE under pipefail and end the build without this message.
#
# The floor alone only catches a downgrade, and downgrades cannot happen while
# the install is unpinned. The move that CAN happen is upstream renaming or
# dropping --auto in a release well above the floor, which sails past the
# version check. So also probe the installed binary for the flag itself.
# `--help` is written to STDERR, hence the 2>&1.
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
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path; \
    mv /home/llm/.opencode/bin/opencode /home/llm/.local/bin/opencode; \
    rm -f /home/llm/.opencode/bin/opencode2; \
    v_raw="$(/home/llm/.local/bin/opencode --version)"; \
    v="$(sed -nE "/^(opencode )?v?([0-9]+\.[0-9]+\.[0-9]+)$/{s//\2/p;q}" <<<"${v_raw}")"; \
    [ -n "${v}" ] || { \
        echo "cannot read a bare X.Y.Z version out of opencode --version: ${v_raw}" >&2; \
        exit 1; }; \
    echo "installed opencode ${v}"; \
    printf "2.0.0\n%s\n" "${v}" | sort -VC || { \
        echo "opencode ${v} is not OpenCode 2 (this image requires OpenCode 2, >= 2.0.0)" >&2; \
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

# ── Pi (https://pi.dev) ─────────────────────────────────────────────────────
# Pi core floats to the latest release, like opencode and Claude Code, and is
# refreshed by `riotbox update` because this layer sits below the
# LLM_TOOL_UPDATE cache bust. It is NOT unlocked: pi.dev publishes the exact
# package.json + package-lock.json its own installer uses for every release,
# and this layer installs from that lock, so every version in the tree is the
# one upstream shipped for the release it resolves. Integrity is upstream's
# where the lock carries it; upstream omits it for Pi's own @earendil-works/*
# packages, which `npm ci` would then install unverified, so
# container/pi/lock-integrity.sh first pins every entry to its exact registry
# tarball on registry.npmjs.org and fills each missing hash from the
# configured npm registry's dist.integrity (registry.npmjs.org unless the
# host ~/.npmrc copied into the image names a mirror). Upstream's
# install.sh is not used: it is interactive, and its managed install lives
# under ~/.pi/agent/install, which the session bind mount of ~/.pi/agent
# would shadow.
#
# The extensions are pinned (issue #16) in container/pi/package.json and its
# committed lock. They install with --legacy-peer-deps into their own prefix
# so the lock carries no second Pi core: Pi's extension loader supplies the
# SDK modules extensions import. agents/pi/setup.sh derives settings.json
# `packages` from that same package.json, so adding an extension is: edit
# container/pi/package.json, then regenerate the lock with
#   (cd container/pi && npm install --package-lock-only --legacy-peer-deps \
#        --ignore-scripts --no-audit --no-fund)
# and update the parity list in container/pi/smoke.mjs if it adds a tool.
#
# --ignore-scripts on both installs, so no lifecycle script runs unreviewed
# at build time. The extension lock declares none (tests/pi.venom.yml asserts
# it). The core lock for 1.2.0 declares two, both safe to skip:
# @google/genai's preinstall is `echo 'preinstall: no-op'` and protobufjs's
# postinstall only prints a version notice. A future script that Pi actually
# needs is not caught by the smoke, which only checks that extensions load
# and register their tools; review a new hasInstallScript entry in the core
# lock when one appears.
#
# PI_NODE matches CONTEXT_MODE_NODE, so nvm installs it once and the Context
# Mode layer reuses it. Pi needs Node >= 22.19 of its own, but Context Mode's Pi
# extension runs in-process in Pi's Node and opens node:sqlite there, and
# context-mode 2.x refuses anything below 24.15.0 — so that floor is Pi's too.
# They are separate ARGs so either can move without the other, within it.
#
# The smoke is the compatibility gate for the floating core: it loads every
# pinned extension into a real offline Pi session and fails the build when
# one does not load or stops registering its tool.
#
# The trailing npm cache strip is the one "Why every npm layer empties
# /home/llm/.npm" explains.
ARG PI_NODE=24.22.2
ENV RIOTBOX_PI_DIR=/home/llm/.riotbox/pi
COPY --chown=llm:llm container/pi/ /tmp/riotbox-pi/
RUN bash -o pipefail -c '\
    set -e; \
    export NVM_DIR=/home/llm/.nvm; \
    . "${NVM_DIR}/nvm.sh"; \
    nvm install "${PI_NODE}" >/dev/null; \
    node_bin="$(dirname "$(nvm which "${PI_NODE}")")"; \
    export PATH="${node_bin}:${PATH}"; \
    core="${RIOTBOX_PI_DIR}/core"; \
    ext="${RIOTBOX_PI_DIR}/extensions"; \
    mkdir -p "${core}" "${ext}"; \
    ver="$(npm view @earendil-works/pi-coding-agent@latest version)"; \
    printf "%s\n" "${ver}" | grep -qxE "[0-9]+\.[0-9]+\.[0-9]+" || { \
        echo "npm reported no bare X.Y.Z for the latest Pi: ${ver}" >&2; exit 1; }; \
    printf "1.2.0\n%s\n" "${ver}" | sort -VC || { \
        echo "latest Pi ${ver} is below the 1.2.0 floor agents/pi was verified against" >&2; exit 1; }; \
    curl -fsSL -o "${core}/package.json" "https://pi.dev/api/installer/releases/${ver}/package.json"; \
    curl -fsSL -o "${core}/package-lock.json" "https://pi.dev/api/installer/releases/${ver}/package-lock.json"; \
    [ "$(jq -r ".dependencies[\"@earendil-works/pi-coding-agent\"]" "${core}/package.json")" = "${ver}" ] || { \
        echo "pi.dev installer manifest for ${ver} does not pin @earendil-works/pi-coding-agent@${ver}" >&2; exit 1; }; \
    bash /tmp/riotbox-pi/lock-integrity.sh "${core}/package-lock.json"; \
    (cd "${core}" && npm ci --ignore-scripts --omit=dev --no-audit --no-fund); \
    cp /tmp/riotbox-pi/package.json /tmp/riotbox-pi/package-lock.json "${ext}/"; \
    (cd "${ext}" && npm ci --ignore-scripts --omit=dev --legacy-peer-deps --no-audit --no-fund); \
    pkg="${core}/node_modules/@earendil-works/pi-coding-agent"; \
    entry="$(jq -r ".bin.pi" "${pkg}/package.json")"; \
    [[ "${entry}" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "unexpected bin.pi path: ${entry}" >&2; exit 1; }; \
    [ -f "${pkg}/${entry}" ] || { echo "Pi ${ver} has no bin.pi entry at ${pkg}/${entry}" >&2; exit 1; }; \
    printf "%s\n" \
        "#!/usr/bin/env bash" \
        "# Generated by the RiotBox image build. Pins the interpreter to PI_NODE." \
        "export PI_TELEMETRY=0" \
        "export PI_SKIP_VERSION_CHECK=1" \
        "exec \"${node_bin}/node\" \"${pkg}/${entry}\" \"\$@\"" \
        > /home/llm/.local/bin/pi; \
    chmod +x /home/llm/.local/bin/pi; \
    probe_home="$(mktemp -d)"; \
    [ "$(HOME="${probe_home}" /home/llm/.local/bin/pi --version)" = "${ver}" ] || { \
        echo "the generated pi shim does not report ${ver}" >&2; exit 1; }; \
    h="$(HOME="${probe_home}" /home/llm/.local/bin/pi --help 2>&1)" || { \
        echo "pi --help failed" >&2; \
        printf "%s\n" "${h}" >&2; \
        exit 1; }; \
    for flag in --print --continue; do \
        printf "%s\n" "${h}" | grep -qE -- "(^|[[:space:]])${flag}([[:space:],]|$)" || { \
            echo "Pi ${ver} no longer lists ${flag}; agents/pi/manifest.sh depends on it" >&2; \
            printf "%s\n" "${h}" >&2; exit 1; }; \
    done; \
    rm -rf "${probe_home}"; \
    node /tmp/riotbox-pi/smoke.mjs "${pkg}" "${ext}"; \
    rm -rf /tmp/riotbox-pi; \
    find /home/llm/.npm -mindepth 1 -delete'

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
# npm's cache is per-user, not per-install: every npm layer in this stage writes
# the tarballs it downloaded to /home/llm/.npm/_cacache. Measured on npm 11.9.0
# against an empty cache: 61 MB here. All of it is redundant with the resolved
# trees those installs just wrote, and /home/llm/.npm is a named-volume mount
# target at runtime, so no session ever reads the build's copy. Each npm layer
# therefore empties it in its OWN RUN, the way the pip and dnf layers do — a
# single strip at the bottom would only whiteout bytes the layers above had
# already committed, reclaiming nothing.
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
ARG CODEGRAPH_VERSION=1.6.2
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
# The release asset, not https://bun.sh/install: RIOTBOX-20260312-001 asks
# every download in this image for download-then-verify against a pinned
# SHA256, which a piped installer cannot give (the finding is accepted for the
# piped installers that remain). Same treatment venom gets, and pinning costs
# nothing extra here — the version was already the only control over what
# lands, since nothing in this layer probes for a feature the way the opencode
# block probes for --auto.
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
# file's _AMD64/_ARM64 convention. The case labels do not: they match `uname -m`
# untranslated (x86_64, aarch64) rather than venom's sed to amd64/arm64, and
# each arm sets upstream's asset name beside the digest that goes with it, so
# the two cannot drift apart. And BUN_VERSION is bare where VENOM_VERSION
# carries a leading v — `bun --version` prints 1.4.4, so the bare form is what
# the check at the end can compare against, and the URL puts the v back as part
# of the bun-v${BUN_VERSION} tag.
ARG BUN_VERSION=1.4.4
ARG BUN_SHA256_AMD64=e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76
ARG BUN_SHA256_ARM64=baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e
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

# ── jsonschema CLI (sourcemeta) ──────────────────────────────────────────────
# Replaces the python3-jsonschema RPM: a single static-ish binary with a
# validator/linter/formatter CLI, instead of a Python library no tool here
# imports. The glibc asset, not -musl, because this image is glibc. Pinned and
# SHA256-verified like venom and bun. Upstream publishes the digest on each
# release asset, so these are transcribed from it at review time.
#
# To refresh:
#   1. Pick a new tag at https://github.com/sourcemeta/jsonschema/releases
#   2. Read the digests for the two glibc zips:
#        gh api repos/sourcemeta/jsonschema/releases/tags/v<VER> \
#          --jq '.assets[] | select(.name|test("linux-(x86_64|arm64)\\.zip$")) | "\(.name) \(.digest)"'
#   3. Update JSONSCHEMA_VERSION + JSONSCHEMA_SHA256_AMD64 + JSONSCHEMA_SHA256_ARM64
# JSONSCHEMA_VERSION is bare: it is both the asset's name and what
# `jsonschema version` prints, which the check at the end compares.
ARG JSONSCHEMA_VERSION=17.3.2
ARG JSONSCHEMA_SHA256_AMD64=ff660a20e5c9273742d5d73de9da2cffbdb91208293f90a8c3ea64a09ad7ed69
ARG JSONSCHEMA_SHA256_ARM64=f8ede4a0b7e26e024d791c6c1af7e8d3d1c444a88dfc901cfb9d3f04825ec643
RUN bash -o pipefail -c '\
    set -e; \
    case "$(uname -m)" in \
        x86_64)  ARCH=x86_64; EXPECTED_SHA="${JSONSCHEMA_SHA256_AMD64}" ;; \
        aarch64) ARCH=arm64;  EXPECTED_SHA="${JSONSCHEMA_SHA256_ARM64}" ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    NAME="jsonschema-${JSONSCHEMA_VERSION}-linux-${ARCH}"; \
    curl -fsSLo /tmp/jsonschema.zip \
        "https://github.com/sourcemeta/jsonschema/releases/download/v${JSONSCHEMA_VERSION}/${NAME}.zip"; \
    echo "${EXPECTED_SHA}  /tmp/jsonschema.zip" | sha256sum -c -; \
    unzip -qj /tmp/jsonschema.zip "${NAME}/bin/jsonschema" -d /home/llm/.local/bin; \
    chmod +x /home/llm/.local/bin/jsonschema; \
    rm -f /tmp/jsonschema.zip; \
    v="$(/home/llm/.local/bin/jsonschema version)"; \
    echo "installed jsonschema ${v}"; \
    [ "${v}" = "${JSONSCHEMA_VERSION}" ] || { \
        echo "jsonschema reports ${v}, pinned ${JSONSCHEMA_VERSION}" >&2; exit 1; }'

# ── Context Mode (opt-in at runtime via RIOTBOX_CONTEXT_MODE) ────────────────
# One layer installs context-mode, stages it as every agent's Context Mode, and
# proves the result routes. It is one package for all three agents: the npm
# tarball carries the CLI (cli.mjs), the MCP server and hook bundles
# (server.mjs, hook.mjs), the OpenCode adapter (opencode/plugin.js), the Pi
# extension (pi/index.js), and the Claude Code plugin manifest
# (.claude-plugin/plugin.json naming hooks/claude-code.json). Upstream's own
# plugins/claude-code tree is built from that tarball (build/main-tree.mjs
# upstream), which is why there is no separate git clone.
#
# ── Why the lockfile is the single pin ──────────────────────────────────────
# `npm ci` installs a generated package.json that depends on exactly
# CONTEXT_MODE_VERSION, against container/context-mode-package-lock.json. The
# lockfile's integrity hash is the only pin on the bytes: npm verifies the
# downloaded tarball against it, so a republished release fails the layer.
# `ci` also refuses a package.json the lockfile does not satisfy (EUSAGE), so
# an ARG bumped without regenerating the lockfile fails here rather than
# installing the old release under a new label. The hash was transcribed from
# one resolution, so it catches the bytes changing after review, not a
# release that was already bad when it was recorded.
#
# context-mode 2.x has no runtime dependencies and no install scripts. Before
# moving the package out of node_modules the layer asserts node_modules holds
# context-mode and nothing else (npm's own dot-entries aside) — anything npm
# installed beside it, whether a dependency, an optional one or a peer, would be
# stranded by the move — and it passes --ignore-scripts so a future install
# script cannot run unreviewed at build time.
#
# To refresh, with the npm of the Node CONTEXT_MODE_NODE names (run it under
# docker.io/library/node:<CONTEXT_MODE_NODE>), from an empty directory:
#   printf '{"name":"riotbox-context-mode","private":true,"dependencies":{"context-mode":"%s"}}\n' \
#     <VERSION> > package.json
#   npm install --package-lock-only --ignore-scripts --no-audit --no-fund
#   cp package-lock.json container/context-mode-package-lock.json
# then set CONTEXT_MODE_VERSION below to the same <VERSION>. The package.json
# line is the one the RUN writes; keep the two identical.
#
# ── Why the pinned Node, and the shim ───────────────────────────────────────
# context-mode 2.x uses node:sqlite and refuses Node below 24.15.0: its hook
# prints "Node vX is below 24.15.0" and does nothing. NODE_DEFAULT above is
# whatever nvm versions scripts/build.sh found on the host — often 20 — so the
# package runs on its own pinned Node. The install paths come from `nvm which`
# rather than from the ARG, because nvm accepts a partial version and a path
# built as v${CONTEXT_MODE_NODE} by hand breaks on the major-only form.
#
# The shim at CONTEXT_MODE_BIN is what makes the pin stick for the CLI: a bare
# `node` on PATH is the session default. The hooks and the MCP server get the
# same pin by rewriting the bare `node` upstream's hooks/claude-code.json and
# .claude-plugin/plugin.json invoke. Each rewrite has a `before` guard (there
# was a bare node to replace — a reshaped file makes the substitution a silent
# no-op otherwise) and an `after` guard (none was missed). OpenCode and Pi load
# the package in-process, on their own runtimes: OpenCode's embedded bun, and
# Pi's Node, which PI_NODE pins to this same version.
#
# ── Why the staged tree is trimmed, and what it keeps ───────────────────────
# The tarball also ships a Gemini hooks/hooks.json. Claude Code always loads
# <plugin>/hooks/hooks.json, and that file holds Gemini's events, so it is
# deleted — as upstream deletes it when it builds plugins/claude-code. Nothing
# else reads it: the CLI, OpenCode and Pi load the same package.
#
# .claude-plugin/marketplace.json stays, although upstream drops it from
# plugins/claude-code (its marketplace lives at the repo root there).
# container/plugin-setup.sh registers the staged tree as its own marketplace,
# and that only resolves while the tree declares the plugin with source "./".
#
# It is staged at a VERSION-STAMPED path under RIOTBOX_CM_PLUGIN_DIR and never
# copied into ~/.claude, which is a per-session-key bind mount.
# container/plugin-setup.sh registers the newest stamped tree in place; see the
# reconcile there for what happens when a rebuild moves it. Nothing at session
# start reaches the network, so RIOTBOX_NETWORK=none holds.
#
# ── Why these checks ────────────────────────────────────────────────────────
# Each runs here so an upstream move fails the build rather than a session.
# The RUN is not `set -u` (nvm.sh is not clean under it), so the ${VAR:?} line
# is what stops an emptied constant from letting the checks pass on nothing.
#
#   * The CLI answers --version with the pin, through the generated shim, and
#     context_mode_pkg_root derives CM_PKG back from that shim — the opencode
#     and Pi wiring build their paths from it every session.
#   * Every registered agent's context_mode_build_assert, handed CM_PKG. The
#     contract an agent depends on is declared in agents/<name>/context-mode.sh
#     beside the code that depends on it; a failure names the agent.
#   * The OpenCode adapter imported under the pinned Node: its default export
#     must carry id, server and setup, the shape both opencode loaders read.
#     The opencode shim re-exports that default alone.
#   * The staged hook table against container/context-mode-hooks-expected.json.
#     A change there is upstream reshaping what a session intercepts — a
#     decision to make deliberately. Regenerate it, and review the diff, with
#       jq -S '.hooks | map_values([.[].matcher])' \
#         "${CM_PKG}/hooks/claude-code.json" > container/context-mode-hooks-expected.json
#   * The routing probe: the real PreToolUse command, read out of the staged
#     hook file after the interpreter rewrite, fed a real WebFetch payload, must
#     return a permission decision. Its control feeds a plain `ls`, which the
#     hook allows by saying nothing, so a pass cannot come from a hook that
#     answers every tool. PATH is scrubbed to /usr/bin:/bin, which has no Node,
#     so a command the rewrite missed produces nothing and fails the layer
#     instead of answering on the build's Node 20. HOME is a scratch directory,
#     so the probe leaves no store in the image.
#   * The stats probe. The exit report's stats shim (CONTEXT_MODE_STATS_BIN,
#     generated here on the pinned Node) runs container/context-mode-stats.mjs,
#     which reads upstream's events table directly. The real PostToolUse
#     command, fed a canned Bash call with a large output in a fresh scratch
#     HOME, must leave a store holding exactly one claude-code call, with bytes
#     kept out; read again at the watermark that read reported, the run must
#     be empty. Then a canned Read with the same large output, which the hook
#     replaces, must add nothing: 2.x journals no row for a clean Read, so the
#     report documents those savings as unmeasured and its kept-out figure as
#     a lower bound. If upstream starts journalling them, this fails, so the
#     report starts counting them on purpose rather than by surprise. An upstream change to the columns, to
#     what a replaced output records, or to where the store lives would
#     otherwise surface as sessions whose report silently stops, or lies.
#     tests/fixtures/context-mode-2-events.sql, which the suites build their
#     stores from, is a copy of this table; this probe is what keeps it honest.
#
# What this layer does NOT run: `context-mode doctor`. It checks each agent it
# finds for the config `context-mode setup` writes, which riotbox never runs —
# it wires per session — so it exits 1 for every agent in the image.
#
# The lockfile and the hook expectation are COPY'd from container/ rather than
# packaging/: packaging/ holds nfpm maintainer scripts and is deliberately NOT
# installed to /opt/riotbox (.goreleaser.yaml contents, install.sh APP_PATHS),
# while `riotbox build` runs from that install tree — so a COPY source there
# resolves in the dev repo and nowhere else.
#
# The trailing npm cache strip is the one "Why every npm layer empties
# /home/llm/.npm" explains. It runs last, after the probes.
ARG CONTEXT_MODE_NODE=24.22.2
ARG CONTEXT_MODE_VERSION=2.1.4
ENV RIOTBOX_CM_PLUGIN_DIR=/home/llm/.riotbox/context-mode-plugin
COPY --chown=llm:llm container/context-mode-package-lock.json \
    /tmp/context-mode-package-lock.json
COPY --chown=llm:llm container/context-mode-hooks-expected.json \
    /tmp/context-mode-hooks-expected.json
RUN bash -o pipefail -c '\
    set -e; \
    export NVM_DIR=/home/llm/.nvm; \
    . "${NVM_DIR}/nvm.sh"; \
    nvm install "${CONTEXT_MODE_NODE}"; \
    CM_NODE_EXE="$(nvm which "${CONTEXT_MODE_NODE}")"; \
    CM_NODE_BIN="$(dirname "${CM_NODE_EXE}")"; \
    cm_install="$(mktemp -d)"; \
    printf "{\"name\":\"riotbox-context-mode\",\"private\":true,\"dependencies\":{\"context-mode\":\"%s\"}}\n" "${CONTEXT_MODE_VERSION}" > "${cm_install}/package.json"; \
    mv /tmp/context-mode-package-lock.json "${cm_install}/package-lock.json"; \
    PATH="${CM_NODE_BIN}:${PATH}" \
        "${CM_NODE_BIN}/npm" ci --ignore-scripts --no-audit --no-fund --prefix "${cm_install}"; \
    cm_installed="${cm_install}/node_modules/context-mode"; \
    [ "$(jq -r ".version" "${cm_installed}/package.json")" = "${CONTEXT_MODE_VERSION}" ] || { \
        echo "npm ci installed context-mode $(jq -r ".version" "${cm_installed}/package.json"), not ${CONTEXT_MODE_VERSION}" >&2; \
        exit 1; }; \
    [ "$(cd "${cm_install}/node_modules" && find . -mindepth 1 -maxdepth 1 ! -name ".*" -printf "%f\n")" = "context-mode" ] || { \
        echo "npm ci installed more than context-mode into node_modules (dependencies, optional or peer) — moving context-mode out of it would strand them" >&2; \
        exit 1; }; \
    CM_PKG="${RIOTBOX_CM_PLUGIN_DIR}/v${CONTEXT_MODE_VERSION}"; \
    mkdir -p "${RIOTBOX_CM_PLUGIN_DIR}"; \
    mv "${cm_install}/node_modules/context-mode" "${CM_PKG}"; \
    rm -rf "${cm_install}"; \
    rm -f "${CM_PKG}/hooks/hooks.json"; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/context-mode-setup.sh; \
    : "${CONTEXT_MODE_BIN:?is no longer defined by context-mode-setup.sh — the shim would go where no session looks for it}"; \
    printf "%s\n" \
        "#!/usr/bin/env bash" \
        "# Generated by the RiotBox image build. Pins the interpreter — see the" \
        "# Context Mode block in the Containerfile for why a bare node is wrong." \
        "exec \"${CM_NODE_BIN}/node\" \"${CM_PKG}/cli.mjs\" \"\$@\"" \
        > "${CONTEXT_MODE_BIN}"; \
    chmod +x "${CONTEXT_MODE_BIN}"; \
    [ -x "${CONTEXT_MODE_BIN}" ]; \
    [ "$("${CONTEXT_MODE_BIN}" --version)" = "${CONTEXT_MODE_VERSION}" ] || { \
        echo "the context-mode shim does not answer --version with ${CONTEXT_MODE_VERSION}" >&2; \
        exit 1; }; \
    [ "$(context_mode_pkg_root)" = "${CM_PKG}" ] \
        || { echo "context_mode_pkg_root derives $(context_mode_pkg_root) from the generated shim, but the package is at ${CM_PKG} — the opencode and Pi wiring would point at the wrong path" >&2; exit 1; }; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/agents/registry.sh; \
    for _cm_agent in "${AGENT_REGISTRY[@]}"; do \
        declare -F "agent_${_cm_agent}_context_mode_build_assert" >/dev/null || continue; \
        agent_call "${_cm_agent}" context_mode_build_assert "${CM_PKG}" \
            || { echo "context-mode@${CONTEXT_MODE_VERSION} broke the ${_cm_agent} Context Mode contract (above)" >&2; exit 1; }; \
    done; \
    cm_probe="$(mktemp -d)"; \
    HOME="${cm_probe}" "${CM_NODE_EXE}" --input-type=module -e "const d = (await import(process.argv[1])).default; if (!(d && typeof d.id === \"string\" && typeof d.server === \"function\" && typeof d.setup === \"function\")) process.exit(1);" "${CM_PKG}/opencode/plugin.js" \
        || { echo "the OpenCode adapter default export no longer carries id, server and setup — the opencode shim re-exports it, so opencode would load no plugin" >&2; exit 1; }; \
    pj="${CM_PKG}/.claude-plugin/plugin.json"; \
    [ -r "${pj}" ] || { echo "the staged package has no .claude-plugin/plugin.json — nothing can register it" >&2; exit 1; }; \
    [ "$(jq -r "[.plugins[] | select(.name == \"context-mode\") | .source] | first" "${CM_PKG}/.claude-plugin/marketplace.json")" = "./" ] || { \
        echo "marketplace.json no longer declares context-mode with source \"./\" — container/plugin-setup.sh registers the staged tree as its own marketplace, which would not resolve" >&2; \
        exit 1; }; \
    [ "$(jq -r ".hooks" "${pj}")" = "./hooks/claude-code.json" ] || { \
        echo "plugin.json no longer names ./hooks/claude-code.json — the hook table checked below is not the one Claude Code loads" >&2; \
        exit 1; }; \
    hooks="${CM_PKG}/hooks/claude-code.json"; \
    [ -r "${hooks}" ] || { echo "the staged package has no hooks/claude-code.json" >&2; exit 1; }; \
    cm_table="$(jq -Sc ".hooks | map_values([.[].matcher])" "${hooks}")"; \
    cm_expected_table="$(jq -Sc . /tmp/context-mode-hooks-expected.json)"; \
    [ "${cm_table}" = "${cm_expected_table}" ] || { \
        echo "the staged hook table is not the one container/context-mode-hooks-expected.json pins — a session would wire a different event set, or intercept a different set of tools, than this image was reviewed against" >&2; \
        echo "  expected: ${cm_expected_table}" >&2; \
        echo "  staged:   ${cm_table}" >&2; \
        exit 1; }; \
    rm -f /tmp/context-mode-hooks-expected.json; \
    before="$(jq -r "[.hooks[][].hooks[].command] | map(select(startswith(\"node \"))) | length" "${hooks}")"; \
    [ "${before}" -gt 0 ] || { \
        echo "no hooks/claude-code.json command invokes a bare node — upstream changed the command shape" >&2; \
        exit 1; }; \
    jq --arg node "${CM_NODE_EXE}" \
        "(.hooks[][].hooks[].command) |= (if startswith(\"node \") then \$node + .[4:] else . end)" \
        "${hooks}" > "${hooks}.tmp"; \
    mv "${hooks}.tmp" "${hooks}"; \
    after="$(jq -r "[.hooks[][].hooks[].command] | map(select(startswith(\"node \"))) | length" "${hooks}")"; \
    [ "${after}" -eq 0 ] || { \
        echo "${after} hooks/claude-code.json commands still invoke a bare node after the substitution" >&2; \
        exit 1; }; \
    [ "$(jq -r ".mcpServers[\"context-mode\"].command" "${pj}")" = "node" ] || { \
        echo "plugin.json no longer declares a bare node for the context-mode MCP server — the interpreter pin has nothing to replace" >&2; \
        exit 1; }; \
    jq --arg node "${CM_NODE_EXE}" ".mcpServers[\"context-mode\"].command = \$node" \
        "${pj}" > "${pj}.tmp"; \
    mv "${pj}.tmp" "${pj}"; \
    [ "$(jq -r ".mcpServers[\"context-mode\"].command" "${pj}")" = "${CM_NODE_EXE}" ] || { \
        echo "plugin.json still does not name ${CM_NODE_EXE} after the substitution" >&2; \
        exit 1; }; \
    cm_pre="$(jq -r "first(.hooks.PreToolUse[].hooks[].command)" "${hooks}")"; \
    [ -n "${cm_pre}" ] || { \
        echo "hooks/claude-code.json has no PreToolUse command — the routing probe has nothing to run" >&2; \
        exit 1; }; \
    cm_route() { printf "{\"session_id\":\"riotbox-build-probe\",\"cwd\":\"%s\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"%s\",\"tool_input\":%s}" "${cm_probe}" "$1" "$2" \
        | env PATH=/usr/bin:/bin HOME="${cm_probe}" \
              CLAUDE_PLUGIN_ROOT="${CM_PKG}" CLAUDE_PROJECT_DIR="${cm_probe}" \
              sh -c "${cm_pre}" \
        | jq -r ".hookSpecificOutput.permissionDecision // empty"; }; \
    cm_control="$(cm_route Bash "{\"command\":\"ls\"}")" || cm_control=""; \
    [ -z "${cm_control}" ] || { \
        echo "the routing probe decided \"${cm_control}\" for a plain ls — a hook that answers every tool would pass the WebFetch check below, so a pass would prove nothing" >&2; \
        exit 1; }; \
    cm_decision="$(cm_route WebFetch "{\"url\":\"https://example.invalid/riotbox-build-probe\",\"prompt\":\"p\"}")" || cm_decision=""; \
    [ -n "${cm_decision}" ] || { \
        echo "the staged plugin returned no PreToolUse decision for WebFetch — Context Mode would report itself enabled and route nothing, which is the bug this probe exists to catch" >&2; \
        if [ -s "${cm_probe}/.context-mode/hook-errors.log" ]; then cat "${cm_probe}/.context-mode/hook-errors.log" >&2; fi; \
        exit 1; }; \
    # shellcheck disable=SC1091  # copied into the image by the COPY above \
    . /home/llm/.riotbox/context-mode-summary.sh; \
    : "${CONTEXT_MODE_STATS_BIN:?is no longer defined by context-mode-summary.sh — the exit report would read a shim that was never written}"; \
    printf "%s\n" \
        "#!/usr/bin/env bash" \
        "# Generated by the RiotBox image build. Pins the interpreter for the same" \
        "# reason the context-mode shim does; --no-warnings suppresses the" \
        "# ExperimentalWarning node:sqlite emits, which would otherwise land in" \
        "# the middle of the exit report." \
        "exec \"${CM_NODE_EXE}\" --no-warnings /home/llm/.riotbox/context-mode-stats.mjs \"\$@\"" \
        > "${CONTEXT_MODE_STATS_BIN}"; \
    chmod +x "${CONTEXT_MODE_STATS_BIN}"; \
    cm_post="$(jq -r "first(.hooks.PostToolUse[].hooks[].command)" "${hooks}")"; \
    [ -n "${cm_post}" ] || { \
        echo "hooks/claude-code.json has no PostToolUse command — the stats probe has nothing to run" >&2; \
        exit 1; }; \
    cm_stats_home="$(mktemp -d)"; \
    cm_stats() { "${CONTEXT_MODE_STATS_BIN}" "${cm_stats_home}/.context-mode" claude-code "$@"; }; \
    seq 1 30000 | jq -Rs --arg cwd "${cm_probe}" "{session_id: \"riotbox-build-probe\", cwd: \$cwd, hook_event_name: \"PostToolUse\", tool_name: \"Bash\", tool_input: {command: \"seq 1 30000\"}, tool_response: {stdout: ., stderr: \"\", interrupted: false}}" \
        | env PATH=/usr/bin:/bin HOME="${cm_stats_home}" \
              CLAUDE_PLUGIN_ROOT="${CM_PKG}" CLAUDE_PROJECT_DIR="${cm_probe}" \
              sh -c "${cm_post}" > /dev/null || { \
        echo "the PostToolUse probe pipeline failed — the staged hook did not accept a canned Bash call" >&2; \
        exit 1; }; \
    cm_run="$(cm_stats)" || { \
        echo "the stats shim could not read the store the PostToolUse probe wrote" >&2; \
        if [ -s "${cm_stats_home}/.context-mode/hook-errors.log" ]; then cat "${cm_stats_home}/.context-mode/hook-errors.log" >&2; fi; \
        exit 1; }; \
    jq -e ".calls == 1 and .kept_out > 0 and .kept_out == .total_kept_out and .re_read == 0 and .rewound == false" > /dev/null <<<"${cm_run}" || { \
        echo "the stats shim did not see the probe call as one claude-code call with bytes kept out: ${cm_run}" >&2; \
        exit 1; }; \
    cm_mark="$(jq -c .seq <<<"${cm_run}")"; \
    cm_after="$(cm_stats "${cm_mark}")" || { \
        echo "the stats shim could not re-read the probe store at its own watermark" >&2; \
        exit 1; }; \
    jq -e --argjson run "${cm_run}" ".calls == 0 and .kept_out == 0 and .total_kept_out == \$run.total_kept_out" > /dev/null <<<"${cm_after}" || { \
        echo "the stats shim still counted the probe call above its own watermark: ${cm_after}" >&2; \
        exit 1; }; \
    seq 1 30000 > "${cm_probe}/cm-read-probe.txt"; \
    jq -Rs --arg cwd "${cm_probe}" --arg f "${cm_probe}/cm-read-probe.txt" "{session_id: \"riotbox-build-probe\", cwd: \$cwd, hook_event_name: \"PostToolUse\", tool_name: \"Read\", tool_input: {file_path: \$f}, tool_response: {type: \"text\", file: {filePath: \$f, content: ., numLines: 30000, startLine: 1, totalLines: 30000}}}" \
        < "${cm_probe}/cm-read-probe.txt" \
        | env PATH=/usr/bin:/bin HOME="${cm_stats_home}" \
              CLAUDE_PLUGIN_ROOT="${CM_PKG}" CLAUDE_PROJECT_DIR="${cm_probe}" \
              sh -c "${cm_post}" > /dev/null || { \
        echo "the PostToolUse probe pipeline failed — the staged hook did not accept a canned Read call" >&2; \
        exit 1; }; \
    cm_read="$(cm_stats "${cm_mark}")" || { \
        echo "the stats shim could not read the store after the Read probe" >&2; \
        exit 1; }; \
    jq -e ".calls == 0 and .kept_out == 0" > /dev/null <<<"${cm_read}" || { \
        echo "context-mode now journals a replaced Read (${cm_read}) — the exit report documents those savings as unmeasured; count them deliberately and update docs/dev/context-mode.md" >&2; \
        exit 1; }; \
    rm -rf "${cm_probe}" "${cm_stats_home}"; \
    find /home/llm/.npm -mindepth 1 -delete; \
    echo "staged context-mode ${CONTEXT_MODE_VERSION} at ${CM_PKG} ($(du -sh "${CM_PKG}" | cut -f1)) — PreToolUse routes WebFetch to ${cm_decision}; the stats shim read $(jq -r .kept_out <<<"${cm_run}") B kept out from the PostToolUse probe"'

# OpenCode V2 compatibility gate: load every plugin RiotBox wires into the
# real (floating) opencode and fail here, not in a user's session, when one
# no longer loads. Runs after every layer that installs opencode or a wired
# plugin (git-ai, headroom, context-mode). Offline: no provider key, no proxy.
# See container/opencode/smoke.sh.
COPY --chown=llm:llm container/opencode/smoke.sh /tmp/riotbox-opencode-smoke.sh
RUN bash /tmp/riotbox-opencode-smoke.sh /home/llm/.riotbox && \
    rm -f /tmp/riotbox-opencode-smoke.sh

# ── Yep Anywhere (served only by `riotbox anywhere`) ─────────────────────────
# A mobile-first web UI that starts Claude Code and opencode itself, so it
# lives here beside them; container/anywhere.sh runs it. Pinned the way the
# Context Mode layer is: `npm ci` of a generated package.json that depends on
# exactly YEPANYWHERE_VERSION, against container/yepanywhere-package-lock.json,
# whose integrity hashes are the only pin on the bytes. `ci` refuses a
# package.json the lockfile does not satisfy, so bumping the ARG without
# regenerating the lockfile fails here.
#
# To refresh, under docker.io/library/node:<CONTEXT_MODE_NODE>, from an empty
# directory:
#   printf '{"name":"riotbox-yepanywhere","private":true,"dependencies":{"yepanywhere":"%s"}}\n' \
#     <VERSION> > package.json
#   npm install --package-lock-only --ignore-scripts --no-audit --no-fund
#   cp package-lock.json container/yepanywhere-package-lock.json
# then set YEPANYWHERE_VERSION to the same <VERSION>.
#
# --ignore-scripts: the one install script in the graph is bcrypt's
# `node-gyp-build`, which only compiles when no prebuilt binary matches; bcrypt
# ships linux-x64 and linux-arm64 prebuilds, which node-gyp-build loads at
# run time. The --setup-auth smoke below hashes a password, so a missing
# prebuild fails the layer.
#
# Node: Yep Anywhere wants ^22.16 || >=24.10, and NODE_DEFAULT is whatever the
# host had. The Context Mode layer above already installed CONTEXT_MODE_NODE
# (24.x), so the shim pins that one instead of downloading a second toolchain.
#
# The Agent SDK's bundled Claude binaries (@anthropic-ai/claude-agent-sdk-*)
# are deleted. container/anywhere.sh points the SDK at the RiotBox wrapper
# through CLAUDE_CODE_EXECUTABLE; without the bundle a regression there fails
# a session instead of running a second, unwrapped Claude Code. It also drops
# about 300 MB.
#
# Outbound traffic, for THREAT_MODEL: nothing at start. Features the user
# opens can reach updates.yepanywhere.com (version check), push.yepanywhere.com
# (push notifications), api.github.com (issue links) and the relay
# (relay.yepanywhere.com, only if remote access is set up in its settings).
ARG YEPANYWHERE_VERSION=0.11.0
COPY --chown=llm:llm container/yepanywhere-package-lock.json \
    /tmp/yepanywhere-package-lock.json
RUN bash -o pipefail -c '\
    set -e; \
    : "${YEPANYWHERE_VERSION:?}"; \
    export NVM_DIR=/home/llm/.nvm; \
    . "${NVM_DIR}/nvm.sh"; \
    YEP_NODE_EXE="$(nvm which "${CONTEXT_MODE_NODE}")"; \
    YEP_NODE_BIN="$(dirname "${YEP_NODE_EXE}")"; \
    YEP_ROOT=/home/llm/.riotbox/yepanywhere; \
    rm -rf "${YEP_ROOT}"; \
    mkdir -p "${YEP_ROOT}/bin"; \
    printf "{\"name\":\"riotbox-yepanywhere\",\"private\":true,\"dependencies\":{\"yepanywhere\":\"%s\"}}\n" "${YEPANYWHERE_VERSION}" > "${YEP_ROOT}/package.json"; \
    mv /tmp/yepanywhere-package-lock.json "${YEP_ROOT}/package-lock.json"; \
    PATH="${YEP_NODE_BIN}:${PATH}" \
        "${YEP_NODE_BIN}/npm" ci --ignore-scripts --no-audit --no-fund --prefix "${YEP_ROOT}"; \
    YEP_PKG="${YEP_ROOT}/node_modules/yepanywhere"; \
    [ "$(jq -r .version "${YEP_PKG}/package.json")" = "${YEPANYWHERE_VERSION}" ] || { \
        echo "npm ci installed yepanywhere $(jq -r .version "${YEP_PKG}/package.json"), not ${YEPANYWHERE_VERSION}" >&2; exit 1; }; \
    rm -rf "${YEP_ROOT}"/node_modules/@anthropic-ai/claude-agent-sdk-*; \
    if find "${YEP_ROOT}/node_modules" -path "*claude-agent-sdk-*" -name claude -type f | grep -q .; then \
        echo "a bundled Claude binary survived the delete — the SDK could run it instead of the wrapper" >&2; exit 1; fi; \
    grep -q "process.env.CLAUDE_CODE_EXECUTABLE" "${YEP_PKG}/dist/sdk/providers/claude.js" || { \
        echo "yepanywhere ${YEPANYWHERE_VERSION} no longer reads CLAUDE_CODE_EXECUTABLE — container/anywhere.sh could not point it at the RiotBox wrapper" >&2; exit 1; }; \
    printf "%s\n" \
        "#!/usr/bin/env bash" \
        "# Generated by the RiotBox image build: pins the Node Yep Anywhere runs on." \
        "exec \"${YEP_NODE_EXE}\" --no-warnings \"${YEP_PKG}/dist/cli.js\" \"\$@\"" \
        > "${YEP_ROOT}/bin/yepanywhere"; \
    chmod +x "${YEP_ROOT}/bin/yepanywhere"; \
    [ "$("${YEP_ROOT}/bin/yepanywhere" --version | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)" = "${YEPANYWHERE_VERSION}" ] || { \
        echo "the yepanywhere shim does not report ${YEPANYWHERE_VERSION}" >&2; exit 1; }; \
    yep_probe="$(mktemp -d)"; \
    HOME="${yep_probe}" YEP_DATA_DIR="${yep_probe}/data" "${YEP_ROOT}/bin/yepanywhere" --setup-auth riotbox-build-probe >/dev/null \
        || { echo "yepanywhere --setup-auth failed — bcrypt has no usable prebuild here, so no session could set a password" >&2; exit 1; }; \
    [ -s "${yep_probe}/data/auth.json" ] || { echo "yepanywhere --setup-auth wrote no auth.json under YEP_DATA_DIR" >&2; exit 1; }; \
    rm -rf "${yep_probe}"; \
    find /home/llm/.npm -mindepth 1 -delete; \
    echo "staged yepanywhere ${YEPANYWHERE_VERSION} at ${YEP_ROOT} ($(du -sh "${YEP_ROOT}" | cut -f1))"'

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
        CLAUDE_CONFIG_DIR="${STAGING_DIR}" claude plugin install "$p" || exit 1; \
    done

# ═════════════════════════════════════════════════════════════════════════════
# Build flavor: riotbox-gh-glab (opt-in, RIOTBOX_GH_GLAB=1)
# ═════════════════════════════════════════════════════════════════════════════
# Adds the gh and glab CLIs. There is no GitHub or GitLab MCP server: models
# already drive both CLIs well and the servers' tool schemas cost more context
# than they returned (issue #19). Build it with `task container:build-gh-glab`,
# which tags the result riotbox-gh-glab so it sits beside the base image rather
# than replacing it.
#
# ── Why this block is at the very bottom of the file ────────────────────────
#
# ARG invalidates the layer cache from the point it is USED, and everything
# after that point rebuilds. RIOTBOX_DIAGRAMS (near the top) is the pattern this
# follows but deliberately not the placement: it gates a base system package, so
# it has to be consumed early and a diagrams build genuinely does rebuild the
# world. This flavor is two rpms. Consumed last, the base image and the flavor
# share every layer up to this one, and building the flavor after the base costs
# a minute instead of an hour.
#
# tests/gh-glab-build.venom.yml asserts this ARG stays in the last tenth of the
# file, because losing the property costs an hour per build and is invisible in
# a build that otherwise succeeds.

ARG RIOTBOX_GH_GLAB=0

# Root for the rpm install; back to llm at the end, since the entrypoint and
# every agent run as llm.
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
        && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info; \
    fi
USER llm

# Fail the build, not a user session, when the flavor did not come out whole.
# An EPEL package renamed would otherwise surface as a missing command halfway
# through a task; running --version also proves each binary executes.
RUN if [ "${RIOTBOX_GH_GLAB}" = "1" ]; then \
        gh --version && \
        glab --version; \
    fi
