# ─────────────────────────────────────────────────────────────────────────────
# Claude Riotbox — CentOS Stream 10
# Built to mirror your host dev environment (nvm, uv, Go, Rust, Ruby).
# Secrets (ANTHROPIC_API_KEY, ~/.claude) are NEVER baked in — mount at runtime.
#
# Multi-stage build:
#   tools   — downloads standalone binaries (trivy, grype, syft, bats)
#   runtime — final image with toolchains + copied binaries
# ─────────────────────────────────────────────────────────────────────────────

# ═════════════════════════════════════════════════════════════════════════════
# Stage 1: Download standalone tool binaries
# ═════════════════════════════════════════════════════════════════════════════
# TODO(security): Pin to a specific digest for supply chain integrity:
#   FROM quay.io/centos/centos:stream10@sha256:<digest> AS tools
# Run: podman inspect quay.io/centos/centos:stream10 --format '{{index .RepoDigests 0}}'
FROM quay.io/centos/centos:stream10 AS tools

RUN dnf -y install curl git tar gzip && dnf clean all

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

# bats — bash testing framework
RUN git clone --depth 1 https://github.com/bats-core/bats-core.git /tools/bats

# ═════════════════════════════════════════════════════════════════════════════
# Stage 2: Runtime image
# ═════════════════════════════════════════════════════════════════════════════
# TODO(security): Pin to same digest as tools stage
FROM quay.io/centos/centos:stream10 AS runtime

# ── Build args (populated by build.sh from host introspection) ────────────────
ARG NVM_INSTALLER_VERSION=0.39.7
ARG NODE_VERSIONS="20"
ARG NODE_DEFAULT="20"
ARG UV_VERSION="latest"
ARG GO_VERSION=""
ARG RUST_TOOLCHAINS="stable"
ARG RUBY_VERSIONS="3.2.9"
ARG RUBY_DEFAULT="3.2.9"
ARG HOST_UID=1000

# ── Fixed paths ───────────────────────────────────────────────────────────────
ENV HOME=/home/claude
ENV NVM_DIR=/home/claude/.nvm
ENV GOPATH=/home/claude/go
ENV PATH=/home/claude/.riotbox/bin:/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/go/bin:/usr/lib/golang/bin:/home/claude/bin:${PATH}

# ── System packages ───────────────────────────────────────────────────────────
# Combined into one layer to avoid intermediate bloat from dnf metadata.
RUN dnf -y update && \
    dnf -y install \
        bash \
        curl \
        wget \
        git \
        make \
        gcc \
        gcc-c++ \
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
    && dnf -y install epel-release \
    && dnf -y install ripgrep \
    && dnf clean all

# ── Common dev libraries (pre-installed to save Claude from installing them) ──
# Separated from base system packages for cache clarity.
RUN /usr/bin/crb enable && \
    dnf -y install \
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
        # C/C++ dev libraries
        libcurl-devel \
        libxml2-devel \
        pcre2-devel \
        # GUI / desktop app toolkits (Tauri, GTK apps)
        glib2-devel \
        gtk3-devel \
        webkit2gtk4.1-devel \
        libsoup3-devel \
        # Database client libraries
        postgresql-devel \
    && dnf clean all

# ── Ruby build dependencies (needed by RVM to compile Ruby from source) ──────
RUN if [ -n "${RUBY_VERSIONS}" ]; then \
        dnf -y install libyaml-devel ruby \
        && dnf clean all; \
    fi

# ── Go (system package, if version specified) ────────────────────────────────
RUN if [ -n "${GO_VERSION}" ]; then \
        dnf -y install golang && dnf clean all && go version; \
    fi

# ── Non-root user — UID matches host so mounted volume files are owned correctly
# Falls back to auto-assigned UID if HOST_UID conflicts with an existing user.
# sudo with NOPASSWD is intentional: Claude needs to dnf-install build deps,
# and the container is disposable — this grants no host privileges.
# chown is needed because earlier ENV/mkdir steps may create dirs as root.
RUN useradd -m -u ${HOST_UID} -s /bin/bash claude 2>/dev/null || \
    useradd -m -s /bin/bash claude && \
    mkdir -p /workspace && chown claude /workspace && \
    chown -R claude:claude /home/claude && \
    echo "claude ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/claude

# ── Security tools from builder stage ─────────────────────────────────────────
COPY --from=tools --chown=claude:claude /tools/bin/ /home/claude/.local/bin/
COPY --from=tools /tools/bats /tmp/bats
RUN /tmp/bats/install.sh /usr/local && rm -rf /tmp/bats && bats --version

# ── semgrep (Python package — must be installed in the runtime stage) ─────────
RUN pip3 install --break-system-packages semgrep && semgrep --version

# ── Podman-in-podman (nested containers) ──────────────────────────────────────
# Pre-installed so RIOTBOX_NESTED=1 works without rebuilding the image.
# slirp4netns provides rootless networking; fuse-overlayfs for storage.
RUN dnf -y install podman fuse-overlayfs slirp4netns && dnf clean all && \
    echo "claude:100000:65536" >> /etc/subuid && \
    echo "claude:100000:65536" >> /etc/subgid

# ── dnf non-interactive by default ───────────────────────────────────────────
RUN mkdir -p /etc/dnf/dnf.conf.d && \
    printf '[main]\nassumeyes=True\n' > /etc/dnf/dnf.conf.d/riotbox.conf

# Fix ownership after root-stage installs (COPY, semgrep) that create dirs
# under /home/claude as root.
RUN chown -R claude:claude /home/claude

USER claude
WORKDIR /home/claude

# ── nvm ───────────────────────────────────────────────────────────────────────
RUN curl -fsSL \
    "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_INSTALLER_VERSION}/install.sh" \
    | bash

# Install every Node version detected on the host, then set the default
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
ENV PATH=/home/claude/.nvm/versions/node/v${NODE_DEFAULT}/bin:${PATH}

# ── uv (pins to the version detected on the host) ────────────────────────────
RUN if [ "${UV_VERSION}" = "latest" ]; then \
        curl -LsSf https://astral.sh/uv/install.sh | bash; \
    else \
        curl -LsSf https://astral.sh/uv/install.sh | UV_TOOL_VERSION="${UV_VERSION}" bash; \
    fi && \
    /home/claude/.local/bin/uv --version

# ── Rust (via rustup) ────────────────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable && \
    bash -c "\
        source /home/claude/.cargo/env && \
        for tc in ${RUST_TOOLCHAINS}; do \
            echo \"==> rustup install \$tc\" && \
            rustup toolchain install \$tc; \
        done && \
        rustc --version && cargo --version \
    "

# ── Ruby (via RVM, if versions specified) ────────────────────────────────
# GPG keys must be imported before RVM's installer will pass signature checks
RUN if [ -n "${RUBY_VERSIONS}" ]; then \
        bash -c "\
            gpg2 --keyserver hkps://keyserver.ubuntu.com \
                 --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 \
                             7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
            curl -sSL https://get.rvm.io | bash -s stable && \
            source /home/claude/.rvm/scripts/rvm && \
            for v in ${RUBY_VERSIONS}; do \
                echo \"==> rvm install \$v\" && \
                rvm install \$v; \
            done && \
            rvm alias create default ${RUBY_DEFAULT} && \
            ruby --version \
        "; \
    fi

# ── Go tools (installed after user is set up) ───────────────────────────────
RUN if command -v go &>/dev/null; then \
        mkdir -p /home/claude/go /home/claude/.cache/go-build && \
        go install golang.org/x/tools/gopls@latest; \
    fi

# ── Pre-create mount targets so bind mounts don't create root-owned dirs ─────
RUN mkdir -p \
    /home/claude/.riotbox/bin \
    /home/claude/bin \
    /home/claude/.npm \
    /home/claude/.cargo/registry \
    /home/claude/go/pkg \
    /home/claude/.cache/pip \
    /home/claude/.cache/uv \
    /home/claude/.bundle/cache \
    /home/claude/.m2/repository \
    /home/claude/.gradle/caches \
    /home/claude/.bun/install

# ── Inner podman config (for nested container support) ───────────────────────
RUN mkdir -p /home/claude/.config/containers && \
    printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' \
        > /home/claude/.config/containers/storage.conf && \
    printf '[containers]\ninit = false\n' \
        > /home/claude/.config/containers/containers.conf

# ── Shell config ──────────────────────────────────────────────────────────────
RUN cat >> /home/claude/.bashrc <<'BASHRC'

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

# ── Gem / Bundler — skip docs, parallel installs ────────────────────────────
RUN echo 'gem: --no-document' > /home/claude/.gemrc && \
    mkdir -p /home/claude/.bundle && \
    printf 'BUNDLE_JOBS: "4"\nBUNDLE_RETRY: "3"\n' > /home/claude/.bundle/config

# ── Tool configs (.npmrc, pip.conf, etc.) copied from host by build.sh ────────
# configs/ is always created by build.sh (even if empty)
COPY --chown=claude:claude configs/ /home/claude/

# ── Git config (baked in — no host .gitconfig is copied) ─────────────────────
# Claude commits as itself so reown-commits.sh can identify its work.
# GPG signing disabled (no keys in container). No pager (non-interactive).
RUN git config --global user.name "Claude (riotbox)" && \
    git config --global user.email "claude@riotbox" && \
    git config --global commit.gpgsign false && \
    git config --global tag.gpgsign false && \
    git config --global core.pager "" && \
    git config --global advice.detachedHead false && \
    git config --global advice.addIgnoredFile false && \
    git config --global init.defaultBranch main && \
    git config --global --add safe.directory /workspace && \
    git config --global receive.denyNonFastForwards true && \
    git config --global receive.denyDeletes true

# ── Plugin list (edit container/plugins.json to customize) ───────────────────
COPY --chown=claude:claude container/plugins.json /home/claude/.riotbox/plugins.json

# ── Riotbox wrapper (shadows the npm-installed claude via PATH priority) ─────
COPY --chown=claude:claude container/claude-wrapper.sh /home/claude/.riotbox/bin/claude
RUN chmod +x /home/claude/.riotbox/bin/claude

WORKDIR /workspace

# ── Entrypoint ──────────────────────────────────────────────────────────────
COPY --chown=claude:claude container/entrypoint.sh /home/claude/.riotbox/entrypoint.sh
RUN chmod +x /home/claude/.riotbox/entrypoint.sh
ENTRYPOINT ["/home/claude/.riotbox/entrypoint.sh"]
CMD ["bash"]

# ── Claude Code (LAST — changes most frequently, preserves layer cache) ─────
RUN npm install -g @anthropic-ai/claude-code && claude --version
