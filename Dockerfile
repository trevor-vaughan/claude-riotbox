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

RUN dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        curl tar gzip && \
    dnf clean all && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc

WORKDIR /tools

# trivy — vulnerability scanner
RUN curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | \
    sh -s -- -b /tools/bin && \
    /tools/bin/trivy --version

# grype — vulnerability scanner for SBOMs
RUN curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | \
    sh -s -- -b /tools/bin && \
    /tools/bin/grype version

# syft — SBOM generator (pairs with grype)
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | \
    sh -s -- -b /tools/bin && \
    /tools/bin/syft version

# task — task runner for Taskfiles (https://taskfile.dev)
RUN curl -sL https://taskfile.dev/install.sh | sh -s -- -b /tools/bin && \
    /tools/bin/task --version

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
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/') && \
    case "${ARCH}" in \
        amd64) EXPECTED_SHA="${VENOM_SHA256_AMD64}" ;; \
        arm64) EXPECTED_SHA="${VENOM_SHA256_ARM64}" ;; \
        *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/venom "https://github.com/ovh/venom/releases/download/${VENOM_VERSION}/venom.linux-${ARCH}" && \
    echo "${EXPECTED_SHA}  /tmp/venom" | sha256sum -c - && \
    mv /tmp/venom /tools/bin/venom && \
    chmod +x /tools/bin/venom && \
    /tools/bin/venom version


# ═════════════════════════════════════════════════════════════════════════════
# Stage 2: Runtime image
# ═════════════════════════════════════════════════════════════════════════════
# Pinned to the same digest as the tools stage. See refresh procedure at the
# top of the tools stage; both `FROM` lines must move together.
FROM quay.io/centos/centos:stream10 AS runtime

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
ARG RUBY_VERSIONS="3.2.9"
ARG RUBY_DEFAULT="3.2.9"
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
           ripgrep chromium bats \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info

# ── Common dev libraries (pre-installed to save Claude from installing them) ──
# Separated from base system packages for cache clarity.
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
RUN if [ -n "${RUBY_VERSIONS}" ]; then \
        dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
            libyaml-devel ruby \
        && dnf clean all \
        && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info; \
    fi

# ── Go (system package, if version specified) ────────────────────────────────
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
RUN dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        podman fuse-overlayfs slirp4netns \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/log/dnf* /usr/share/man /usr/share/doc /usr/share/info

# ── semgrep (Python package — must be installed in the runtime stage) ─────────
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

COPY container/CLAUDE.md /etc/riotbox/CLAUDE.md
RUN . /etc/os-release && \
    awk -v os="${PRETTY_NAME:-Linux}" \
        '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        /etc/riotbox/CLAUDE.md > /etc/claude-code/CLAUDE.md && \
    chown llm:llm /etc/claude-code/CLAUDE.md && \
    mkdir -p /home/llm/.riotbox && \
    awk -v os="${PRETTY_NAME:-Linux}" \
        '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        /etc/riotbox/CLAUDE.md > /home/llm/.riotbox/AGENTS.md.template && \
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

# Fix ownership after root-stage COPY that creates dirs under /home/llm.
RUN chown -R llm:llm /home/llm

USER llm
WORKDIR /home/llm

# ── nvm ───────────────────────────────────────────────────────────────────────
RUN curl -fsSL \
    "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_INSTALLER_VERSION}/install.sh" \
    | bash

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
RUN if [ "${UV_VERSION}" = "latest" ]; then \
        curl -LsSf https://astral.sh/uv/install.sh | bash; \
    else \
        curl -LsSf https://astral.sh/uv/install.sh | UV_TOOL_VERSION="${UV_VERSION}" bash; \
    fi && \
    /home/llm/.local/bin/uv --version

# ── Rust (via rustup) + cargo-binstall for pre-built binaries ────────────────
# Conditional: when RUST_TOOLCHAINS is empty (the default), skip the whole
# rustup install. This saves ~1.4 GB for users who don't need Rust in-container.
# The first toolchain in the space-separated list becomes the rustup default.
RUN if [ -n "${RUST_TOOLCHAINS}" ]; then \
        set -- ${RUST_TOOLCHAINS}; \
        RUST_DEFAULT_TC="$1"; \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
            sh -s -- -y --default-toolchain "${RUST_DEFAULT_TC}" && \
        bash -c "\
            source /home/llm/.cargo/env && \
            for tc in ${RUST_TOOLCHAINS}; do \
                echo \"==> rustup install \$tc\" && \
                rustup toolchain install \$tc; \
            done && \
            rustc --version && cargo --version && \
            ARCH=\$(uname -m) && \
            curl -LSfs https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-\${ARCH}-unknown-linux-musl.tgz \
                | tar xz -C /home/llm/.cargo/bin && \
            cargo binstall --no-confirm ast-grep && sg --version \
        "; \
    fi
# TODO(security): cargo-binstall publishes .sig files (minisign) but uses
#   ephemeral keys per release — no stable public key to verify against.

# ── Ruby (via RVM, if versions specified) ────────────────────────────────
# GPG keys must be imported before RVM's installer will pass signature checks
RUN if [ -n "${RUBY_VERSIONS}" ]; then \
        bash -c "\
            gpg2 --keyserver hkps://keyserver.ubuntu.com \
                 --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 \
                             7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
            curl -sSL https://get.rvm.io | bash -s stable && \
            source /home/llm/.rvm/scripts/rvm && \
            for v in ${RUBY_VERSIONS}; do \
                echo \"==> rvm install \$v\" && \
                rvm install \$v; \
            done && \
            rvm alias create default ${RUBY_DEFAULT} && \
            ruby --version \
        "; \
    fi

# ── Go tools (installed after user is set up) ───────────────────────────────
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
    git config --global --add safe.directory /workspace && \
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

# Make it obvious we're in the riotbox
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
# Skip puppeteer's bundled Chromium (~580 MB) — use the system package instead.
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
RUN npm install -g @mermaid-js/mermaid-cli && mmdc --version

# ── Riotbox scripts: agent registry + generic wrapper ───────────────────────
# The agent registry (agents/<name>.sh + agents/registry.sh) is the single
# source of truth for which CLI agents this image supports. The Dockerfile
# stays agent-agnostic: agent-wrapper.sh is installed once, and per-agent
# entries in /home/llm/.riotbox/bin/ are symlinks created from the
# registry. Adding a new agent is a manifest edit, not a Dockerfile edit.
COPY --chown=llm:llm agents/ /home/llm/.riotbox/agents/
COPY --chown=llm:llm container/find-real-bin.sh /home/llm/.riotbox/find-real-bin.sh
COPY --chown=llm:llm container/agent-wrapper.sh /home/llm/.riotbox/agent-wrapper.sh
RUN chmod +x /home/llm/.riotbox/agent-wrapper.sh \
              /home/llm/.riotbox/find-real-bin.sh && \
    # Install one symlink per registered agent. The wrapper detects the
    # agent from basename($0), so the symlink name doubles as the agent
    # name. Reading AGENT_REGISTRY directly keeps the Dockerfile in sync
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
COPY --chown=llm:llm container/nested-podman-setup.sh /home/llm/.riotbox/nested-podman-setup.sh
COPY --chown=llm:llm container/entrypoint.sh /home/llm/.riotbox/entrypoint.sh
RUN chmod +x /home/llm/.riotbox/entrypoint.sh \
    /home/llm/.riotbox/session-branch.sh /home/llm/.riotbox/overlay-setup.sh \
    /home/llm/.riotbox/plugin-setup.sh /home/llm/.riotbox/nested-podman-setup.sh
ENTRYPOINT ["/home/llm/.riotbox/entrypoint.sh"]
CMD ["bash"]

# ── opencode (installed alongside Claude Code) ───────────────────────────────
# The official installer hardcodes the install target at $HOME/.opencode/bin
# and modifies .bashrc to extend PATH. Skip the .bashrc modification with
# --no-modify-path (we manage PATH explicitly in the image), then move the
# binary into the existing user-local bin dir so no extra PATH entry is
# needed. The .opencode/bin directory itself is left in place — empty after
# the move and harmless.
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && \
    mv /home/llm/.opencode/bin/opencode /home/llm/.local/bin/opencode && \
    /home/llm/.local/bin/opencode --version

# ── Claude Code (LAST — changes most frequently, preserves layer cache) ─────
RUN curl -fsSL https://claude.ai/install.sh | bash && claude --version

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
