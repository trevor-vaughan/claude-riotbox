# ─────────────────────────────────────────────────────────────────────────────
# Claude Riotbox — CentOS Stream 10
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
# TODO(security): Pin to a specific digest for supply chain integrity:
#   FROM quay.io/centos/centos:stream10@sha256:<digest> AS tools
# Run: podman inspect quay.io/centos/centos:stream10 --format '{{index .RepoDigests 0}}'
FROM quay.io/centos/centos:stream10 AS tools

RUN dnf -y install curl tar gzip && dnf clean all

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
# TODO(security): No checksums or signatures published upstream. Pin to a
#   version and verify a self-computed SHA256 if supply-chain risk is a concern.
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/') && \
    curl -LO "https://github.com/ovh/venom/releases/latest/download/venom.linux-${ARCH}" && \
    mv "venom.linux-${ARCH}" /tools/bin/venom && \
    chmod +x /tools/bin/venom && \
    /tools/bin/venom version


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

# ── System packages ───────────────────────────────────────────────────────────
# Combined into one layer to avoid intermediate bloat from dnf metadata.
RUN dnf -y update && \
    dnf -y install \
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
    && dnf -y install epel-release \
    && dnf -y install ripgrep plantuml chromium bats \
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

# ── Podman-in-podman (nested containers) ──────────────────────────────────────
# Pre-installed so RIOTBOX_NESTED=1 works without rebuilding the image.
# slirp4netns provides rootless networking; fuse-overlayfs for storage.
RUN dnf -y install podman fuse-overlayfs slirp4netns && dnf clean all

# ── semgrep (Python package — must be installed in the runtime stage) ─────────
RUN pip3 install --no-cache-dir --break-system-packages semgrep pyyaml && semgrep --version

# ── Non-root user + root-phase config ─────────────────────────────────────────
# User creation, dnf config, and system prompt dir. The chown -R happens later
# (after COPY/pip that create root-owned dirs under /home/claude).
RUN useradd -l -m -u ${HOST_UID} -s /bin/bash claude 2>/dev/null || \
    useradd -l -m -s /bin/bash claude && \
    mkdir -p /workspace && chown claude /workspace && \
    echo "claude ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/claude && \
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
    chown claude:claude /etc/claude-code

COPY container/CLAUDE.md /etc/riotbox/CLAUDE.md
RUN . /etc/os-release && \
    awk -v os="${PRETTY_NAME:-Linux}" \
        '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        /etc/riotbox/CLAUDE.md > /etc/claude-code/CLAUDE.md && \
    chown claude:claude /etc/claude-code/CLAUDE.md && \
    mkdir -p /home/claude/.riotbox && \
    awk -v os="${PRETTY_NAME:-Linux}" \
        '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
        /etc/riotbox/CLAUDE.md > /home/claude/.riotbox/AGENTS.md.template && \
    chown -R claude:claude /home/claude/.riotbox

# ── Security tools + task/venom from builder stage ───────────────────────────
COPY --from=tools --chown=claude:claude /tools/bin/ /home/claude/.local/bin/

# ── Fixed paths (set after useradd so HOME points to the real user dir) ──────
ENV HOME=/home/claude
ENV NVM_DIR=/home/claude/.nvm
ENV GOPATH=/home/claude/go
ENV PATH=/home/claude/.riotbox/bin:/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/go/bin:/usr/lib/golang/bin:/home/claude/bin:${PATH}

# Fix ownership after root-stage COPY that creates dirs under /home/claude.
RUN chown -R claude:claude /home/claude

USER claude
WORKDIR /home/claude

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
ENV PATH=/home/claude/.nvm/versions/node/v${NODE_DEFAULT}/bin:${PATH}

# ── uv (pins to the version detected on the host) ────────────────────────────
RUN if [ "${UV_VERSION}" = "latest" ]; then \
        curl -LsSf https://astral.sh/uv/install.sh | bash; \
    else \
        curl -LsSf https://astral.sh/uv/install.sh | UV_TOOL_VERSION="${UV_VERSION}" bash; \
    fi && \
    /home/claude/.local/bin/uv --version

# ── Rust (via rustup) + cargo-binstall for pre-built binaries ────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable && \
    bash -c "\
        source /home/claude/.cargo/env && \
        for tc in ${RUST_TOOLCHAINS}; do \
            echo \"==> rustup install \$tc\" && \
            rustup toolchain install \$tc; \
        done && \
        rustc --version && cargo --version && \
        ARCH=\$(uname -m) && \
        # TODO(security): cargo-binstall publishes .sig files (minisign) but uses
        #   ephemeral keys per release — no stable public key to verify against.
        curl -LSfs https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-\${ARCH}-unknown-linux-musl.tgz \
            | tar xz -C /home/claude/.cargo/bin && \
        cargo binstall --no-confirm ast-grep && sg --version \
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
RUN if command -v go >/dev/null 2>&1; then \
        mkdir -p /home/claude/go /home/claude/.cache/go-build && \
        go install golang.org/x/tools/gopls@latest; \
    fi

# ── User-phase config (mount targets, podman, gem, git, shell) ───────────────
# All lightweight config writes combined into one layer.
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
        /home/claude/.bun/install \
        /home/claude/.config/containers && \
    # Inner podman config (for nested container support)
    printf '[storage]\ndriver = "overlay"\n\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' \
        > /home/claude/.config/containers/storage.conf && \
    printf '[containers]\ninit = false\n' \
        > /home/claude/.config/containers/containers.conf && \
    # Gem / Bundler — skip docs, parallel installs
    echo 'gem: --no-document' > /home/claude/.gemrc && \
    printf 'BUNDLE_JOBS: "4"\nBUNDLE_RETRY: "3"\n' > /home/claude/.bundle/config && \
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
COPY --chown=claude:claude configs/ /home/claude/

# ── Diagram tools (for validating generated diagrams) ────────────────────────
# Skip puppeteer's bundled Chromium (~580 MB) — use the system package instead.
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
RUN npm install -g @mermaid-js/mermaid-cli && mmdc --version

# ── Riotbox scripts: agent registry + generic wrapper ───────────────────────
# The agent registry (agents/<name>.sh + agents/registry.sh) is the single
# source of truth for which CLI agents this image supports. The Dockerfile
# stays agent-agnostic: agent-wrapper.sh is installed once, and per-agent
# entries in /home/claude/.riotbox/bin/ are symlinks created from the
# registry. Adding a new agent is a manifest edit, not a Dockerfile edit.
COPY --chown=claude:claude agents/ /home/claude/.riotbox/agents/
COPY --chown=claude:claude container/find-real-bin.sh /home/claude/.riotbox/find-real-bin.sh
COPY --chown=claude:claude container/agent-wrapper.sh /home/claude/.riotbox/agent-wrapper.sh
RUN chmod +x /home/claude/.riotbox/agent-wrapper.sh \
              /home/claude/.riotbox/find-real-bin.sh && \
    # Install one symlink per registered agent. The wrapper detects the
    # agent from basename($0), so the symlink name doubles as the agent
    # name. Reading AGENT_REGISTRY directly keeps the Dockerfile in sync
    # with agents/registry.sh — no second list to update.
    bash -c '\
        set -euo pipefail; \
        # shellcheck disable=SC1091  # path verified above \
        source /home/claude/.riotbox/agents/registry.sh; \
        for a in "${AGENT_REGISTRY[@]}"; do \
            ln -sf ../agent-wrapper.sh "/home/claude/.riotbox/bin/${a}"; \
        done'

WORKDIR /workspace

# ── Entrypoint ──────────────────────────────────────────────────────────────
# Agent setup scripts (claude/setup.sh, opencode/setup.sh) ride along with
# the manifests via the COPY agents/ above; the entrypoint reaches them
# through the registry, so they don't need separate COPY lines.
COPY --chown=claude:claude container/session-branch.sh /home/claude/.riotbox/session-branch.sh
COPY --chown=claude:claude container/overlay-setup.sh /home/claude/.riotbox/overlay-setup.sh
COPY --chown=claude:claude container/plugin-setup.sh /home/claude/.riotbox/plugin-setup.sh
COPY --chown=claude:claude container/nested-podman-setup.sh /home/claude/.riotbox/nested-podman-setup.sh
COPY --chown=claude:claude container/entrypoint.sh /home/claude/.riotbox/entrypoint.sh
RUN chmod +x /home/claude/.riotbox/entrypoint.sh \
    /home/claude/.riotbox/session-branch.sh /home/claude/.riotbox/overlay-setup.sh \
    /home/claude/.riotbox/plugin-setup.sh /home/claude/.riotbox/nested-podman-setup.sh
ENTRYPOINT ["/home/claude/.riotbox/entrypoint.sh"]
CMD ["bash"]

# ── opencode (installed alongside Claude Code) ───────────────────────────────
# The official installer hardcodes the install target at $HOME/.opencode/bin
# and modifies .bashrc to extend PATH. Skip the .bashrc modification with
# --no-modify-path (we manage PATH explicitly in the image), then move the
# binary into the existing user-local bin dir so no extra PATH entry is
# needed. The .opencode/bin directory itself is left in place — empty after
# the move and harmless.
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path && \
    mv /home/claude/.opencode/bin/opencode /home/claude/.local/bin/opencode && \
    /home/claude/.local/bin/opencode --version

# ── Claude Code (LAST — changes most frequently, preserves layer cache) ─────
RUN curl -fsSL https://claude.ai/install.sh | bash && claude --version

# ── Pre-stage plugins (no auth needed — just clones a public GitHub repo) ────
# Installed to a staging dir because ~/.claude is bind-mounted at runtime.
# The entrypoint copies from here into the session dir on first run, avoiding
# network access and ~14 Node.js process spawns at startup.
RUN STAGING_DIR=/home/claude/.riotbox/plugins-staging/.claude && \
    mkdir -p "${STAGING_DIR}/plugins/cache" && \
    CLAUDE_CONFIG_DIR="${STAGING_DIR}" claude plugin marketplace add anthropics/claude-plugins-official && \
    for p in \
        superpowers ralph-loop \
        frontend-design feature-dev code-simplifier commit-commands \
        security-guidance claude-code-setup claude-md-management; do \
        CLAUDE_CONFIG_DIR="${STAGING_DIR}" claude plugin install "$p" || true; \
    done
