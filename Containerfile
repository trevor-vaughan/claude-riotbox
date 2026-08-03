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
#   2. Compute SHA256 for amd64 + arm64:
#        for a in amd64 arm64; do
#          curl -sL "https://github.com/ovh/venom/releases/download/<TAG>/venom.linux-$a" \
#            | sha256sum | awk '{print $1}'
#        done
#   3. Update VENOM_VERSION + VENOM_SHA256_AMD64 + VENOM_SHA256_ARM64 below
ARG VENOM_VERSION=v1.3.0
ARG VENOM_SHA256_AMD64=89832ec25e820c605cf0d3c09122e60bad43d13c1724aa6d375ef7109fbfe201
ARG VENOM_SHA256_ARM64=aada8ac76cb642daecbc8e31e830c94c42bcdd78fecd3a9d9d1a73c37c60d946
# Pipefail matters here for `echo … | sha256sum -c -`: without it, a failed
# sha256sum step would not abort the chain if anything before it in a pipe
# silently succeeded.
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
ARG NVM_INSTALLER_VERSION=0.39.7
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
ARG LOLA_VERSION=0.4.4
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

# ── Diagram tools (for validating generated diagrams) ────────────────────────
# Off by default. Set RIOTBOX_DIAGRAMS=1 at build time to install Chromium
# and mermaid-cli (mmdc). The system Chromium rpm is installed earlier in
# the same conditional; puppeteer's bundled Chromium (~580 MB) is skipped
# either way so we don't accidentally double-install.
# DL3016: @mermaid-js/mermaid-cli is kept at latest to support current Mermaid
# diagram syntax; pinning a specific version risks stale diagram rendering.
# hadolint ignore=DL3016
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
RUN if [ "${RIOTBOX_DIAGRAMS}" = "1" ]; then \
        npm install -g @mermaid-js/mermaid-cli && mmdc --version; \
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
    /home/llm/.riotbox/context-mode-summary.sh
ENTRYPOINT ["/home/llm/.riotbox/entrypoint.sh"]
CMD ["bash"]

# ── Health check ──────────────────────────────────────────────────────────────
# This is a developer-shell image with no long-running daemon to probe. The
# check verifies that the core toolchain is intact (task is always present)
# without starting any service or network connection.
HEALTHCHECK --interval=30s --timeout=5s --retries=1 \
    CMD command -v task >/dev/null 2>&1

# ── LLM CLI tool cache-bust boundary ────────────────────────────────────────
# `task container:update` bumps LLM_TOOL_UPDATE to a fresh value, which makes
# this RUN a cache miss and forces every layer below it (headroom, opencode,
# Claude Code, CodeGraph, Context Mode, plugins) to rebuild and re-pull latest
# — without rebuilding the whole image. A normal `task container:build` always
# passes the default (0), so the boundary stays cached and the tools are
# reused. The six tool RUNs below are intentionally left unchanged; the
# boundary alone controls their freshness. headroom, CodeGraph and Context Mode
# are version-pinned, so an update re-installs them unchanged — the same
# headroom wheels and ~350 MB of models, the same CodeGraph npm package (no
# model download), and the same Context Mode npm package, which additionally
# re-runs `nvm install` and re-downloads its pinned Node toolchain because that
# too lives below the boundary. The cost is accepted so `riotbox update` can
# add all three to images built before they existed and refresh headroom's
# unpinned transitive deps.
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
# Upstream bug (present through 0.25.0): `headroom wrap --memory` spawns
# `python -m headroom.memory.sync`, which builds its backend config with the
# dataclass default embedder (torch sentence-transformers — excluded here)
# instead of the ONNX embedder the proxy auto-selects; there is no flag or
# env var to steer it. The sed below patches the call site to "onnx". The
# guard grep fails this layer on a pin bump that changes the line — the
# signal to re-check whether upstream fixed the sync path.
# The smoke test then runs the exact sync command the wrap emits, offline,
# against a seeded memory file under a throwaway HOME — proving the patched
# embedder path AND the pre-warmed model cache end to end. PYTHONPATH is
# pinned to the user site because overriding HOME hides pip's --user dir.
# The hf-xet chunk cache is transfer-time scratch — the offline loads above
# prove the hub cache alone suffices, so it is removed.
ARG HEADROOM_VERSION=0.25.0
RUN pip3 install --user --no-cache-dir --break-system-packages \
        "headroom-ai[proxy,code]==${HEADROOM_VERSION}" && \
    /home/llm/.local/bin/headroom --version && \
    SYNC="$(python3 -c 'import headroom.memory.sync as m; print(m.__file__)')" && \
    grep -qF 'config = LocalBackendConfig(db_path=args.db)' "${SYNC}" && \
    sed -i 's/config = LocalBackendConfig(db_path=args.db)/config = LocalBackendConfig(db_path=args.db, embedder_backend="onnx")/' "${SYNC}" && \
    python3 -c "from headroom.transforms.kompress_compressor import KompressCompressor; \
print('kompress backend:', KompressCompressor().preload(allow_download=True))" && \
    python3 -c "from huggingface_hub import hf_hub_download; \
[hf_hub_download('Qdrant/all-MiniLM-L6-v2-onnx', f) for f in ('model.onnx', 'tokenizer.json')]" && \
    HF_HUB_OFFLINE=1 python3 -c "from headroom.transforms.kompress_compressor import KompressCompressor; \
KompressCompressor().preload(allow_download=False)" && \
    HF_HUB_OFFLINE=1 python3 -c "from huggingface_hub import hf_hub_download; \
[hf_hub_download('Qdrant/all-MiniLM-L6-v2-onnx', f, local_files_only=True) for f in ('model.onnx', 'tokenizer.json')]" && \
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
RUN bash -o pipefail -c '\
    curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && \
    mv /home/llm/.opencode/bin/opencode /home/llm/.local/bin/opencode && \
    /home/llm/.local/bin/opencode --version'

# ── Claude Code (LAST — changes most frequently, preserves layer cache) ─────
RUN bash -o pipefail -c 'curl -fsSL https://claude.ai/install.sh | bash && claude --version'

# ── CodeGraph (pre-indexed code knowledge graph, MCP server per session) ─────
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
ARG CODEGRAPH_VERSION=1.5.0
RUN npm install -g "@colbymchenry/codegraph@${CODEGRAPH_VERSION}" && \
    CODEGRAPH_NO_DOWNLOAD=1 codegraph version && \
    codegraph telemetry off && \
    env -u CODEGRAPH_TELEMETRY codegraph telemetry status | grep -q disabled

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
#     claude compares the event set and both matchers for EQUALITY against
#     hooks/hooks.json in the installed package — the hooks config upstream's
#     own installer emits, and the one artifact in the package that states all
#     three exactly rather than in fragments. Three comparisons: the event
#     names as sorted key lists against context_mode_hook_table; the
#     PreToolUse matchers, pipe-joined in array order, against
#     CONTEXT_MODE_MATCHER; and PostToolUse's single matcher against
#     CONTEXT_MODE_POST_MATCHER. All three were verified byte-identical against
#     context-mode@1.0.169.
#
#     Equality rather than a grep of cli.bundle.mjs is the whole point.
#     Upstream's sources of truth (PRE_TOOL_USE_MATCHERS in
#     src/adapters/claude-code/hooks.ts, and the array MI the PostToolUse set
#     is joined from at runtime) survive bundling as individual string
#     literals, so a grep of the 1.1 MB bundle proves only that a name appears
#     SOMEWHERE in it — "Grep" occurs three times — which means each plain name
#     would survive its own removal from the matcher array, and no grep of the
#     bundle can notice a tool upstream ADDED, the direction that silently
#     costs continuity. A dropped tool, an added tool, a renamed event, an
#     added event and a reordered alternation all fail this layer instead. The
#     last of those is cosmetic upstream and still fails here, deliberately and
#     on the same terms as the MCP-name grep: the drift gets read by a
#     maintainer instead of by a session.
#
#     claude also greps CONTEXT_MODE_MCP_NAME out of hooks/core/tool-naming.mjs
#     — the routing table that names the tools a redirect points the agent at,
#     and a file that the path RiotBox uses actually reaches: `context-mode
#     hook claude-code <event>` dispatches by importing hooks/<event>.mjs out
#     of the package, which imports that table. It hardcodes
#     mcp__plugin_context-mode_context-mode__<tool> with nothing to steer it,
#     so the MCP server has to be registered under that name; a pin bump that
#     changed the prefix would leave every redirect pointing at a tool the
#     session does not have. The grep includes the backtick that opens the
#     template literal, so the identical string in the file's own doc table
#     cannot satisfy it while the code drifts. Both this and the path itself
#     are upstream internals that could be relocated without any change in
#     behaviour; that would fail this layer too, which is the intent — the
#     drift then gets read by a maintainer instead of by a session.
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
#   * The `hook <platform> <event>` dispatcher the template's hook commands
#     call. This one is load-bearing: the CLI treats an unrecognised first
#     argument as "start the MCP server", so if upstream ever drops or renames
#     the subcommand, every hook would silently emit nothing and route nothing
#     — a feature that looks enabled and does exactly zero.
#   * One hooks/<event>.mjs per row of context_mode_hook_table. This is the only
#     assertion that can catch a nonexistent event name, and the only one that
#     checks the key-to-event mapping at all: that mapping is this layer's own
#     (PreToolUse → pretooluse), so nothing in hooks.json can validate it, and
#     `context-mode hook claude-code <name>` exits 0 and prints nothing for an
#     event that does not exist, exactly as a valid event fed empty stdin does —
#     so invoking the dispatcher can only ever prove that the CLI runs.
#   * getRealBytesStats in build/session/analytics.js — the counters the
#     generated CONTEXT_MODE_STATS_BIN shim imports — and then that shim's own
#     output against a throwaway empty sessions directory. Upstream renaming
#     either the module or the export would otherwise surface as sessions that
#     silently stop printing the exit report.
#
# DL3016 does not apply: the version is pinned via the build ARG.
ARG CONTEXT_MODE_NODE=22.23.1
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
    "${CONTEXT_MODE_BIN}" --help | grep -q "context-mode hook <platform> <event>"; \
    context_mode_hook_table | jq -r "to_entries[] | .value.event" > /tmp/cm-events; \
    while read -r event; do \
        [ -f "${CM_PKG}/hooks/${event}.mjs" ] \
            || { echo "context_mode_hook_table names the event \"${event}\", which has no hooks/${event}.mjs in context-mode@${CONTEXT_MODE_VERSION} — the dispatcher exits 0 for it, so every session would wire a hook that does nothing" >&2; exit 1; }; \
        "${CONTEXT_MODE_BIN}" hook claude-code "${event}" < /dev/null; \
    done < /tmp/cm-events; \
    rm -f /tmp/cm-events; \
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
    "${CONTEXT_MODE_BIN}" doctor > /dev/null'

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
