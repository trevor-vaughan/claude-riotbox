# RiotBox - Letting your coding agent run wild

______________________________________________________________________

> 🤖 LLM/AI WARNING 🤖
>
> This project was largely written by an AI coding agent. It has been reviewed and tested, but use in production at your own discretion.
>
> 🤖 LLM/AI WARNING 🤖

______________________________________________________________________

Container-based isolation for running AI coding agents autonomously against your projects. The container ships [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [opencode](https://opencode.ai/) and mirrors your host dev environment (nvm, uv, Go, Rust, Ruby) so the agent has the same toolchain you do, but runs isolated from your credentials and secrets.

> **Security:** This project has an AI-generated [threat model](THREAT_MODEL.md) covering the container isolation boundary, auth handling, mount surface, and nested container mode. Read it before use.

## Why did I build this?

Claude has [Sandboxing](https://code.claude.com/docs/en/sandboxing), but I wanted the opposite of what that does. I wanted unbridled insanity, the ability to install whatever it needed, and the ability to map in multiple projects easily for complex coordinated development while I was sleeping.

I also use CentOS/RHEL and wanted something that would work natively in that environment.

Finally...it was fun!

## How it works

1. **`scripts/build.sh`** introspects your local environment (nvm, uv, Go, Rust/rustup, Ruby/RVM, UID, tool configs) and passes them as build args.
1. The **Containerfile** uses a multi-stage build: a `tools` stage downloads standalone binaries (trivy, grype, syft, task, venom), and the `runtime` stage assembles the final CentOS Stream 10 image with all toolchains. The agent CLIs are installed last — opencode via its [installer](https://opencode.ai/install), then Claude Code via the [official installer](https://claude.ai/install.sh) — for
   optimal layer caching.
1. At runtime your project directory is bind-mounted into the container. Auth credentials are synced into an isolated session directory: `~/.claude/.credentials.json` is bind-mounted read-write (so token refreshes write back to the host), and `~/.claude.json` is copied so each container gets a writable snapshot without host contention.
1. **A single generic wrapper** (`container/agent-wrapper.sh`) shadows the real agent binaries via per-agent symlinks under `~/.riotbox/bin/`. The wrapper detects which agent it's running as from its own filename, looks up that agent's manifest at `agents/<name>/manifest.sh`, and applies the manifest's flag-injection rules. The RiotBox autonomy prompt lives at `/etc/claude-code/CLAUDE.md`
   (managed-policy path read by Claude) and at `~/.config/opencode/AGENTS.md` (placed at runtime by the agent's setup hook). Selection happens via `--agent=claude|opencode` (default `claude`); see `riotbox agents` to list the registered set.

## Prerequisites

- [Podman](https://podman.io/) or Docker (podman preferred, auto-detected)

- [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) (required for podman — see [Podman setup](#podman-setup))

- One of:

  - `ANTHROPIC_API_KEY` environment variable, **or**
  - `~/.claude.json` with OAuth tokens (created by running `claude` on the host and completing the OAuth flow)

- [git-filter-repo](https://github.com/newren/git-filter-repo) (required for `reown` — `pip install git-filter-repo`)

- (Optional) nvm, uv, Go, rustup, RVM installed locally — the build mirrors whatever it finds

## Install

RiotBox installs as a normal application that puts a `riotbox` command on your PATH. Pick one of three paths:

```sh
# System package (rpm — Fedora/RHEL/CentOS)
sudo dnf install ./riotbox-<ver>-1.noarch.rpm

# System package (deb — Debian/Ubuntu)
sudo apt install ./riotbox_<ver>_all.deb

# Rootless (no sudo) — see ./setup.sh below for the guided variant
./install.sh
```

**Layouts.** The two install models differ only in where files land:

|                               | App tree                                                    | CLI symlink            | Config dir                                               |
|-------------------------------|-------------------------------------------------------------|------------------------|----------------------------------------------------------|
| **rpm / deb** (system)        | `/opt/riotbox`                                              | `/usr/bin/riotbox`     | `/etc/riotbox/{config,mounts.conf}`                      |
| **rootless** (`./install.sh`) | `$XDG_DATA_HOME/riotbox` (default `~/.local/share/riotbox`) | `~/.local/bin/riotbox` | `$XDG_CONFIG_HOME/riotbox` (default `~/.config/riotbox`) |

The `riotbox` dispatcher is self-locating, so it works from either tree without extra configuration.

**Config precedence** (highest to lowest):

```
env  >  $XDG_CONFIG_HOME/riotbox  >  /etc/riotbox  >  built-in defaults
```

This applies to the host-side settings the launcher reads: `config` (sourced by the launcher) and `mounts.conf` (read by mount detection). A value in your user config overrides the system `/etc/riotbox` default, and an explicit environment variable overrides both. Plugins are configured per-user only (`$XDG_CONFIG_HOME/riotbox/plugins.conf` or the `RIOTBOX_PLUGINS` env var) — they are applied
inside the container, where host `/etc/riotbox` is not visible, so there is no system-wide plugin layer.

**After installing**, build the image and verify your host:

```sh
riotbox build     # introspect the host and build the container image
riotbox doctor    # run host preflight checks
```

`./setup.sh` is the guided rootless path (prerequisite checks + podman config + `install.sh` + `riotbox build` in one idempotent run). The rpm/deb packages are the system-wide path. Both leave you with the same `riotbox` command.

## Setup

The quickest way to get started is the guided setup script:

```sh
./setup.sh
```

This checks prerequisites, configures podman, installs the CLI, and builds the image. It's idempotent — safe to re-run if you need to fix something.

### Manual setup

If you prefer to set things up yourself:

1. Install the `riotbox` command:

   ```sh
   ./install.sh                 # symlink → ~/.local/bin/riotbox (default)
   ./install.sh ~/bin           # pick a different directory for the symlink
   ```

   The app tree always lands in `$XDG_DATA_HOME/riotbox` (default
   `~/.local/share/riotbox`); only the entrypoint symlink's directory is
   configurable.

1. Configure podman (see [Podman setup](#podman-setup))

1. Build the image:

   ```sh
   riotbox build
   ```

## Quick start

```sh
cd /path/to/your/project

# Run the agent autonomously against the current directory
riotbox run "add tests for the auth module"

# Or specify a project directory explicitly
riotbox run "fix lint errors" /path/to/other/project

# Interactive shell in the riotbox
riotbox shell

# After a run, rewrite the agent's commits to use your identity
riotbox reown
```

## Using opencode

RiotBox ships with [opencode](https://opencode.ai/) installed alongside Claude Code. Pick the agent per command with the `--agent` flag:

```sh
# Run opencode against the current directory
riotbox --agent=opencode run "fix the build"

# Resume the last opencode session
riotbox --agent=opencode resume

# Open a shell with both binaries on PATH (use either)
riotbox shell
```

Default is `claude` if `--agent` is omitted. You can persist a default in `~/.config/riotbox/config` by uncommenting the `RIOTBOX_AGENT` line.

> Want to add a third agent (aider, goose, cursor-agent, codex, …)? See [`docs/dev/adding-an-agent.md`](docs/dev/adding-an-agent.md). The agent registry at `agents/registry.sh` is the single source of truth — adding an agent is a manifest plus a Containerfile install line, no edits to dispatch sites or wrappers.

### Opencode auth

1. **`opencode auth login` on the host** (recommended) — credentials at `~/.local/share/opencode/auth.json` are bind-mounted RW into the container. OAuth token refreshes write back to the host file.
1. **Provider env vars** — direct API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.) and Claude Code routing vars (`CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`, `AWS_PROFILE`, etc.) are passed through automatically when set on the host. See `~/.config/riotbox/config` for the full default list and how to extend it.
1. **Cloud SDK credential files** — `GOOGLE_APPLICATION_CREDENTIALS` (Vertex), `AWS_SHARED_CREDENTIALS_FILE` (Bedrock), `KUBECONFIG`, and `AWS_CONFIG_FILE` are auto-mounted **read-only** at a fixed in-container path and the env var is rewritten to that path. Configure via `RIOTBOX_CREDFILE_VARS`.

If `CLAUDE_CODE_USE_VERTEX` is set on the host but `GOOGLE_APPLICATION_CREDENTIALS` is unset, the launcher additionally checks for `~/.config/gcloud/application_default_credentials.json` (the file `gcloud auth application-default login` writes) and prompts before bind-mounting it. Answer `n` if you'd rather plumb credentials yourself; the launcher will skip the mount and print a notice. The
prompt is TTY-only — non-interactive launches always skip with a notice.

Long-lived AWS access keys (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) are **not** passed through by default — use a profile + credentials file instead. SSH agent forwarding is also out of scope.

### Opencode config

Your host `~/.config/opencode/` (agents, commands, themes, `opencode.json`, `opencode.jsonc`) is copied into the session dir at every launch. The container then merges `opencode.json` and `opencode.jsonc` into a single `opencode.jsonc` (jsonc wins on key conflict) and forces these keys to RiotBox values regardless of host input:

- `permission = "allow"` — the container is RiotBox; per-tool permission prompts are pointless inside it.
- `share = "disabled"` — no session telemetry from the container.
- `autoupdate = false` — the image pins opencode at build time.
- `instructions` includes `~/.config/opencode/AGENTS.md` — the RiotBox autonomy prompt is always loaded.

A banner comment in the generated `opencode.jsonc` records these forced keys. To change anything else (model, theme, agents, commands, etc.), edit your host `opencode.json` or `opencode.jsonc`; the next launch picks up the change.

### Opencode plugins

Plugins listed in your `opencode.jsonc` `plugin` array (npm packages or git URLs) are installed by opencode itself via `bun install` the first time you run a session. The install output (`node_modules/`, `package.json`, `package-lock.json`, `bun.lock`, `.gitignore`) is **not** copied from your host — those files are platform-specific and opencode's own `.gitignore` marks them disposable. Instead
the install lands in `~/.cache/opencode`, which RiotBox keeps in a persistent named volume (`riotbox-cache-opencode`). The cold install takes ~15s; later sessions resolve plugins from the warm cache in ~2s, offline. Because the plugins are built inside the container, their native dependencies always match the container platform regardless of your host OS.

## Commands

| Command                               | Description                                                                                                                                 |
|---------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `riotbox build`                       | Introspect host environment and build the container image                                                                                   |
| `riotbox rebuild`                     | Force a clean rebuild with no layer cache                                                                                                   |
| `riotbox update`                      | Re-pull LLM CLI tools — opencode, Claude Code, plugins to latest; headroom, CodeGraph, Context Mode at pinned versions (large re-download)  |
| `riotbox run "<task>" [dir]`          | Run the agent autonomously (defaults to current directory)                                                                                  |
| `riotbox shell [dir]`                 | Interactive shell (defaults to current directory)                                                                                           |
| `riotbox resume [dir]`                | Continue the last agent session                                                                                                             |
| `riotbox reown`                       | Rewrite all container-authored commits to your git identity                                                                                 |
| `riotbox reown <ref>`                 | Rewrite only commits since a specific ref                                                                                                   |
| `riotbox mounts`                      | Show auto-detected mounts (useful for debugging)                                                                                            |
| `riotbox nested-run "<task>" [dir]`   | Run with podman-in-podman support (disables SELinux)                                                                                        |
| `riotbox nested-shell [dir]`          | Shell with podman-in-podman support (disables SELinux)                                                                                      |
| `riotbox socket-run "<task>" [dir]`   | Run with shared host podman socket (WARNING: grants host root)                                                                              |
| `riotbox socket-shell [dir]`          | Shell with shared host podman socket (WARNING: grants host root)                                                                            |
| `riotbox session-list`                | List all RiotBox sessions                                                                                                                   |
| `riotbox session-remove [key/path]`   | Remove a session by key or project path (or `--all`)                                                                                        |
| `riotbox session-reset [all] [force]` | Reset session cache (forces fresh skill/config copy); `all` resets every session, `force` skips the confirmation prompt                     |
| `riotbox overlays`                    | List sessions with pending overlay data (podman-only)                                                                                       |
| `riotbox overlay-diff [project]`      | Show overlay changes vs host project                                                                                                        |
| `riotbox overlay-accept [project]`    | Apply overlay changes to host project                                                                                                       |
| `riotbox overlay-reject [project]`    | Discard overlay changes                                                                                                                     |
| `riotbox audit "<task>" [dir]`        | Read-only session for inspecting untrusted code (workspace mounted RO)                                                                      |
| `riotbox install-hooks [global]`      | Install the pre-push hook that blocks container-identity commits ([details](#reclaiming-authorship))                                        |
| `riotbox agents`                      | List registered agents (riotbox name + binary)                                                                                              |
| `riotbox tokscale [args...]`          | Unified [tokscale](https://github.com/IvGolovach/tokscale) usage across your native agent home + every riotbox session, offline (no telemetry); args pass through to tokscale                     |
| `riotbox doctor`                      | Walks every preflight check; prints each result with a fix hint. Exits with the first failure's code (0 on full pass).                      |

## Pre-installed tools

The image comes with a broad set of tools pre-installed so the agent can start working immediately without spending time on setup.

**Development toolchains** (auto-detected from your host):

- Node.js (via nvm), Python/uv, Rust/cargo, Go, Ruby/RVM, git-lfs

**Security scanners:**

- [trivy](https://github.com/aquasecurity/trivy), [grype](https://github.com/anchore/grype), [syft](https://github.com/anchore/syft), [semgrep](https://semgrep.dev/), ShellCheck

**Testing:**

- [venom](https://github.com/ovh/venom) (integration and end-to-end test suites)

**AI tooling:**

- [`lola`](https://github.com/LobsterTrap/lola) — AI Skills Package Manager (cross-assistant skill distribution)
- [`context-mode`](https://github.com/mksglu/context-mode) — context-window optimization (opt-in per session, see [Context Mode](#context-mode-opt-in))

**Diagram validation:**

- `plantuml` — UML diagram generation and validation
- `mmdc` ([mermaid-cli](https://github.com/mermaid-js/mermaid-cli)) — Mermaid diagram rendering

**Containers:**

- podman, fuse-overlayfs, slirp4netns (for nested container support)

## Plugins

Claude Code [plugins](https://docs.anthropic.com/en/docs/claude-code/plugins) are managed by `container/plugin-setup.sh`, which runs at every container startup. Plugins are loaded in order of precedence (lowest to highest):

1. **Pre-staged defaults** — baked into the image at build time (defined in the `Containerfile`). Copied into the session on first run.
1. **Marketplace plugins** — installed from `~/.config/riotbox/plugins.conf` (one plugin name per line) or the `RIOTBOX_PLUGINS` environment variable (comma-separated). Already-installed plugins are skipped to avoid spawning Node.js on every startup.
1. **Host plugins** — your host `~/.claude/plugins/` directory is bind-mounted read-only at `~/.host-plugins` and merged into the session with highest precedence. Host plugin paths are rewritten to the container's filesystem automatically.

```sh
# Install extra plugins via env var
RIOTBOX_PLUGINS=superpowers,ralph-loop riotbox shell

# Or configure permanently
cat > ~/.config/riotbox/plugins.conf << 'EOF'
# One plugin per line (comments and blank lines OK)
superpowers
ralph-loop
EOF
```

**User extensions** from your host `~/.claude/` are copied into the session directory at every launch, so newly installed resources are available immediately. The covered directories are `skills/`, `agents/` (subagents), `commands/` (slash commands), and `output-styles/`. Symlinks are dereferenced during copy, and removing a directory on the host removes it from the next session too.

## Status bar customization

Claude Code can display a custom status line beneath the input box. To enable it, create an executable script at `~/.claude/statusline-command.sh` on your host. RiotBox copies it into the session directory on every launch and wires it into Claude Code's settings automatically.

The script receives a JSON object on stdin and its stdout is displayed in the status bar. The JSON includes:

```json
{
  "context_window": {
    "used_percentage": 42.0,
    "total_input_tokens": 50000,
    "total_output_tokens": 5000
  },
  "model": {
    "id": "claude-sonnet-4-6",
    "display_name": "Claude Sonnet 4.6"
  }
}
```

A minimal example that shows context usage:

```sh
#!/usr/bin/env bash
input=$(cat)
pct=$(echo "$input" | jq -r '.context_window.used_percentage // "?"')
model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
echo "${model} | ctx ${pct}%"
```

RiotBox ships a more complete default script with a Unicode progress bar and color coding — run `/statusline` inside Claude Code to regenerate or customise it.

## Auto-detected mounts

The mount set comes from two scripts, applied in this order:

1. **`scripts/detect-mounts.sh`** — always-on mounts that don't depend on a project: `~/bin`, `~/.config/riotbox/`, and the named cache volumes. Uses an allowlist (only paths listed in the script are mounted).
2. **`scripts/mount-projects.sh`** — per-launch mounts: the project bind, the session directory mount, and the per-agent contributions from `agents/<name>/manifest.sh::host_sync` (credentials nest, opencode auth, host plugins, host `~/.claude/{skills,agents,…}` copies, statusline script copy).

Run `riotbox mounts [project ...]` to print the projected mount set — it lists the always-on group, the project + session group, and a static enumeration of what the agent host_sync hooks would add at launch.

**Always-on** (from `detect-mounts.sh`):

| Host path            | Container path       | How                          |
|----------------------|----------------------|------------------------------|
| `~/.config/riotbox/` | `~/.config/riotbox/` | bind mount (read-only, `:z`) |
| `~/bin`              | `~/bin`              | bind mount (read-only, `:z`) |
| named cache volumes  | `~/.npm`, `~/.cargo/registry`, … | named volumes (rw)     |

**Per-launch** (from `mount-projects.sh`):

| Host path                                           | Container path                | How                                  |
|-----------------------------------------------------|-------------------------------|--------------------------------------|
| Each `<project>` path                               | `/workspace[/<basename>]`     | bind mount (`:z` or `:O` overlay)    |
| `~/.local/share/riotbox/<session>/`                 | `~/.claude`                   | bind mount (`:z`)                    |
| `~/.claude/.credentials.json`                       | `~/.claude/.credentials.json` | nested bind mount (`:z`, read-write) |
| `~/.claude.json`                                    | copied into session dir       | file copy                            |
| `~/.claude/{skills,agents,commands,output-styles}/` | copied into session dir       | file copy (symlinks dereferenced)    |
| `~/.claude/statusline-command.sh`                   | copied into session dir       | file copy (chmod +x enforced)        |
| `~/.claude/plugins/`                                | `~/.host-plugins`             | bind mount (read-only, `:z`)         |
| `~/.local/share/opencode/auth.json`                 | same path in container        | bind mount (rw, when opencode runs)  |

RiotBox sessions are isolated from your host `~/.claude` — it is never mounted directly. `.credentials.json` is bind-mounted read-write so OAuth token refreshes write directly back to the host file (rotating refresh tokens require this). `.claude.json` is copied so each container gets a writable snapshot without host contention.

> `detect-mounts.sh` and `mount-projects.sh` both accept `--format=podman` (default; one `-v host:container[:flag]` line per mount) and `--format=triple` (one `host:container:mode` line per mount, where `mode` is `rw`/`ro`/`ovl`). The triple format is for tooling that needs to parse the mount table — config generators, tests — without regexing podman flags.

**Package caches** (named volumes, shared across containers):

| Volume                   | Container path      |
|--------------------------|---------------------|
| `riotbox-cache-npm`      | `~/.npm`            |
| `riotbox-cache-cargo`    | `~/.cargo/registry` |
| `riotbox-cache-go`       | `~/go/pkg`          |
| `riotbox-cache-pip`      | `~/.cache/pip`      |
| `riotbox-cache-uv`       | `~/.cache/uv`       |
| `riotbox-cache-bundler`  | `~/.bundle/cache`   |
| `riotbox-cache-m2`       | `~/.m2/repository`  |
| `riotbox-cache-gradle`   | `~/.gradle/caches`  |
| `riotbox-cache-bun`      | `~/.bun/install`    |
| `riotbox-cache-opencode` | `~/.cache/opencode` |

Package caches use named podman/docker volumes rather than bind mounts. This avoids SELinux relabeling overhead — bind-mounting gigabytes of cache with `:z` causes recursive `chcon` on every container start, which can take minutes. Named volumes get `container_file_t` automatically. The tradeoff is that caches are not shared with the host.

Sensitive directories (`.ssh`, `.gnupg`, `.kube`, `.aws`, etc.) are never mounted. Run `riotbox mounts` to see what would be mounted for your system.

**User-defined mounts** (`~/.config/riotbox/mounts.conf`):

If you need additional host files inside the container (e.g., `.npmrc` for private npm registries), list them in `mounts.conf`:

```sh
mkdir -p ~/.config/riotbox
cat > ~/.config/riotbox/mounts.conf << 'EOF'
# Private npm registry auth (mount live token, read-only)
.npmrc
# Yarn config
# .yarnrc.yml
# Maven settings with server credentials
# .m2/settings.xml
EOF
```

Each line is a path relative to `$HOME` (or absolute with `/`). All user mounts are **read-only** — the container can read your live tokens but cannot modify the host files. This is the recommended way to provide private registry credentials at runtime, since auth tokens are [stripped from configs at build time](#build-time-config-collection) and never baked into image layers.

**Persistent defaults** (`~/.config/riotbox/config`):

You can set default values for any `RIOTBOX_*` environment variable in the `config` file. Values use shell `:=` syntax so explicit env vars and command-line flags always take precedence:

```sh
# ~/.config/riotbox/config
# Disable network by default (air-gapped sessions)
: "${RIOTBOX_NETWORK:=none}"
```

**Startup scripts** (`~/.config/riotbox/startup_scripts/*.sh`):

Drop executable scripts at `~/.config/riotbox/startup_scripts/*.sh` to run arbitrary setup inside the container after plugins, agent setup, overlay, and session branch are all in place — for example, registering a CA, exporting credentials assembled at runtime, or warming a local cache.

```sh
mkdir -p ~/.config/riotbox/startup_scripts
cat > ~/.config/riotbox/startup_scripts/10-register-ca.sh << 'EOF'
#!/usr/bin/env bash
# CA file is sourced from the riotbox config dir (bind-mounted read-write).
sudo trust anchor --store ~/.config/riotbox/internal-ca.crt
EOF
chmod +x ~/.config/riotbox/startup_scripts/10-register-ca.sh
```

Conventions:

- Scripts must have the executable bit (`chmod +x`); non-executable files are skipped with a notice on stderr.
- Scripts run in lexicographic filename order; prefix with `10-`, `20-`, etc. to control ordering.
- The script's shebang chooses the interpreter (`#!/usr/bin/env bash`, `#!/usr/bin/env python3`, etc.).
- A failing script (non-zero exit) prints a warning and the session continues. One broken hook will not brick your sessions.

**XDG directory layout:**

All RiotBox paths follow the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/):

| XDG variable      | Default                   | Contents                  |
|-------------------|---------------------------|---------------------------|
| `XDG_CONFIG_HOME` | `~/.config/riotbox/`      | `mounts.conf`, `config`   |
| `XDG_DATA_HOME`   | `~/.local/share/riotbox/` | Session dirs, git backups |

## Agent wrapper

Inside the container, each agent binary is shadowed by a single generic wrapper (`container/agent-wrapper.sh`) that injects the agent's autonomy flags (for Claude Code, `--dangerously-skip-permissions`) — this is safe here because the container **is** RiotBox. The agent can't escape to the host, and the mounted project directory has a git checkpoint for easy rollback.

The system prompt is pre-rendered at build time into `/etc/claude-code/CLAUDE.md` (the managed policy path). This location is loaded automatically by Claude Code, cannot be excluded, and survives context compression. Build-time rendering avoids SELinux AVC denials that occur when `container_t` writes to `etc_t` paths in the overlay filesystem. The `RIOTBOX_PROMPT` env var can override the
template at runtime if needed. Using the managed policy path frees `~/.claude/CLAUDE.md` for the user's own instructions — personal CLAUDE.md and rules from the host are synced into the session directory at launch.

## Container runtime modes

RiotBox supports three modes for code that needs to run containers inside the session. Pick based on your trust posture and use case.

| Mode    | Flag               | Trust posture                   | Image cache             | Auth                       | Isolation                     |
|---------|--------------------|---------------------------------|-------------------------|----------------------------|-------------------------------|
| Default | (none)             | tight (single-uid keep-id)      | n/a                     | n/a                        | full                          |
| Nested  | `RIOTBOX_NESTED=1` | broad-trust inside outer userns | per-session vfs (large) | per-session `podman login` | inner namespace               |
| Socket  | `RIOTBOX_SOCKET=1` | **host root** (effective)       | shared with host        | host's podman login state  | none — containers run on host |

`RIOTBOX_NESTED=1` and `RIOTBOX_SOCKET=1` are mutually exclusive. The launcher refuses to start if both are set.

**Which to pick:**

- **Need authenticated registry pulls across many sessions with minimum fuss** → socket mode. Bind-mounts the host's `podman.sock`, so `podman pull ghcr.io/private/img` uses your host's `podman login` state automatically. The container has effective root on the host; use only with trusted code.
- **Need actually-isolated nested containers, accept the per-session vfs storage cost, willing to `podman login` inside the container** → nested mode.
- **Don't need a container engine inside the session** → default mode.

### Socket mode (shared host podman engine)

Enable the user-level podman socket on the host (once per machine):

```sh
systemctl --user enable --now podman.socket
```

Verify the socket is alive:

```sh
podman --url unix://${XDG_RUNTIME_DIR}/podman/podman.sock info
```

Then run a session with the shared socket:

```sh
RIOTBOX_SOCKET=1 riotbox shell
# or
riotbox socket-shell
```

The launcher only uses your **rootless** socket. It checks `$XDG_RUNTIME_DIR/podman/podman.sock` first, then falls back to `/run/user/$(id -u)/podman/podman.sock`. The rootful socket at `/run/podman/podman.sock` is intentionally NOT used: with `--userns=keep-id`, a root-owned bind mount is unreachable from the in-container user (it appears as `nobody:nobody` and every `podman` call fails with
permission denied). If neither candidate is alive, the launcher exits with an actionable error rather than mounting the wrong one. The bind mount uses podman's `:z` shared-label option so SELinux relabels the host socket to `container_file_t:s0` — without this, the in-container `container_t` process is denied `connect(2)` on the host socket's `user_runtime_t` label even when Unix permissions
match (a no-op on hosts without SELinux). The nested-podman setup (vfs storage override, subuid plumbing, v3 file caps) is skipped — there is no inner engine.

**Trust caveat:** the host podman socket is roughly equivalent to root on the host. Any process inside the container that can reach the socket can `podman run --privileged --pid=host -v /:/host alpine chroot /host` and own the machine. This is the same delegation Docker Desktop ships by default and the same pattern CI runners use with `-v /var/run/docker.sock` — well-trodden, but a well-known
attack vector. Use only with code you trust.

### Nested mode (podman-in-podman)

If the agent needs to build or run containers (e.g., testing Dockerfiles, running docker-compose stacks), use the nested variants:

```sh
riotbox nested-run "build and test the Dockerfile"
riotbox nested-shell
```

This passes `--device /dev/fuse` and `--security-opt label=disable` to the outer container, enabling rootless podman inside RiotBox. The image includes podman, fuse-overlayfs, and slirp4netns pre-installed with proper subuid/subgid mappings.

> **WARNING:** Nested mode disables SELinux confinement on the outer container. This is a meaningful reduction in host isolation — the container processes are no longer confined by SELinux policy. Only use this when the agent actually needs container capabilities.

You can also enable nested mode on any command via the environment variable:

```sh
RIOTBOX_NESTED=1 riotbox shell
```

### Extra engine arguments (`RIOTBOX_EXTRA_ARGS`)

`RIOTBOX_EXTRA_ARGS` is a catch-all for run-time container-engine flags that have no dedicated RiotBox setting. Its value is appended to the `podman run` (or `docker run`) command after every other managed flag, just before `-w` and the image, so whatever you put here is the last thing the engine sees.

> **WARNING:** These flags bypass RiotBox's safety defaults and can weaken container isolation. When `RIOTBOX_EXTRA_ARGS` is set, the launcher prints a warning and asks `[y/N]` (default No) on every interactive launch. Set `RIOTBOX_EXTRA_ARGS_ACK=1` to acknowledge the risk and skip the prompt for routine use. Without a TTY and without that acknowledgment, the launch aborts rather than applying the flags silently.

The canonical use is GPU access:

```sh
# ~/.config/riotbox/config
: "${RIOTBOX_EXTRA_ARGS:=--device nvidia.com/gpu=all --security-opt=label=disable}"
: "${RIOTBOX_EXTRA_ARGS_ACK:=1}"
```

The value is whitespace-split, so a single flag value cannot contain spaces, and a bare `--` is rejected (it would let the launcher's own trailing options be reinterpreted as positionals).

For narrowly scoped needs, prefer the dedicated settings (`RIOTBOX_NETWORK`, project mounts, `RIOTBOX_CREDFILE_VARS`) over this catch-all.

## Reclaiming authorship

After a riotbox run, the container's commits will carry its generic identity (`LLM (riotbox)` \<`llm@riotbox`>). Use `riotbox reown` from the project directory to rewrite those commits with your name and email (read from your `~/.gitconfig`).

By default, `reown` finds all container-authored commits on the current branch, starts the rewrite from the oldest one's parent (minimising hash changes to pre-container commits), and rewrites only the container-authored authorship fields. Running it twice is safe — the second run is a no-op.

```sh
cd /path/to/project
riotbox reown              # rewrites all container-authored commits
riotbox reown abc123       # rewrites only commits since a specific ref
```

> **Note:** This uses `git filter-repo` under the hood, which rewrites commit hashes. Only use this on commits that haven't been pushed to a shared remote, or be prepared to force-push. A backup tag (`backup/pre-reown-<timestamp>`) is created before rewriting — use `git diff <backup-tag>..<branch>` to verify the result.
>
> `reown` recognises the current container identity (`llm@riotbox`) and three legacy identities used by older RiotBox versions (`claude@riotbox`, `llm@localhost`, `riotbox@local`), so old commits are also caught.

**Forgetting to reown is a footgun** — pushing a container-identity commit to a shared remote leaks `llm@riotbox` into your project's history. To make that mistake hard to make accidentally, install the pre-push guard hook:

```sh
# Per-repo
cd /path/to/project
riotbox install-hooks

# Or globally (applies to every repo without its own hooksPath)
riotbox install-hooks global
```

The hook checks the push range for any container-identity commits and aborts the push with a hint to run `riotbox reown` if it finds any. Existing hook managers (lefthook, husky, pre-commit) are detected and a snippet is printed so you can chain the RiotBox hook from your manager's config. `riotbox install-hooks --help` lists the options.

## Headroom context compression (opt-in)

[Headroom](https://github.com/chopratejas/headroom) compresses tool outputs,
logs, and conversation history before they reach the model — typically a
60–95% token reduction. RiotBox ships it in the image (pinned version,
telemetry permanently off) and activates it per session:

```bash
RIOTBOX_HEADROOM=1 riotbox run "fix the failing tests"
# or persist it:
echo ': "${RIOTBOX_HEADROOM:=1}"' >> ~/.config/riotbox/config
```

What changes when enabled:

- The agent launches through a localhost-only compression proxy inside the
  container. Nothing is exposed outside the container.
- Cross-session memory and failure learning (`--memory`, `--learn`) are on.
  State persists per project set under the session directory
  (`~/.local/share/riotbox/<session>/headroom`, also visible in-container at
  `~/.claude/headroom`) and is shared by all agents of that project set.
- Model inference is fully offline — the compression models are baked into
  the image at build time.
- Wired for `--agent=claude` (via `headroom wrap`) and `--agent=opencode`
  (via `headroom proxy` plus provider baseURL injection — headroom has no
  `wrap opencode`). Other agents print a warning and run uncompressed.
- For opencode, only the `anthropic` and `openai` providers route through
  the proxy; other providers (openrouter, gemini, …) go direct. A baseURL
  you set yourself in `opencode.json(c)` always wins — riotbox prints a
  notice and leaves that provider unrouted.
- Nested agent invocations inside a wrapped session (e.g. the agent's own
  shell running `claude`) intentionally run uncompressed.

Headroom keeps reversible copies of compressed content (originals the model
can retrieve on demand) in that state directory — treat it with the same
sensitivity as your `.claude` session transcripts. `riotbox session-remove`
deletes both together.

The toggle accepts only the literal `1` — anything else disables the feature
(`riotbox doctor` flags unrecognized values). If a session misbehaves under
compression, drop the variable and rerun — default behavior is untouched
when `RIOTBOX_HEADROOM` is unset.

## Context Mode (opt-in)

[Context Mode](https://github.com/mksglu/context-mode) keeps large tool output out
of the model's context window. Two layers do the work. **Interception** catches
the calls that produce large output — `Bash`, `Read`, `Grep`, `WebFetch`,
`Agent`, and every external MCP tool — before their bytes reach the transcript,
and parks the raw output in a local SQLite FTS5 store the agent searches on
demand instead of re-reading. **Continuity** records what the session did into a
second, per-project store, which is replayed into the next session and after each
compact. RiotBox ships it in the image (pinned version, no telemetry) and wires it
per session:

```bash
RIOTBOX_CONTEXT_MODE=1 riotbox run "fix the failing tests"
# or persist it:
echo ': "${RIOTBOX_CONTEXT_MODE:=1}"' >> ~/.config/riotbox/config
```

**Both agents are wired, and the wiring has nothing in common between them.**
Upstream reaches Claude Code through hooks and an MCP server, and opencode
through a TypeScript plugin that runs inside the agent process; there is no
shared shape to abstract over. Each agent supplies its own wiring in
`agents/<name>/context-mode.sh`, and `container/context-mode-setup.sh` drives it
without naming any agent — see
[`docs/dev/agent-contract.md`](docs/dev/agent-contract.md#optional-verbs-context-mode)
for the contract. An agent that supplies none runs with the feature off after a
warning naming it.

|                        | `--agent=claude`                                                                | `--agent=opencode`                                                              |
|------------------------|---------------------------------------------------------------------------------|---------------------------------------------------------------------------------|
| What riotbox writes    | six hook stanzas in `settings.json`, plus an `mcpServers` entry in `.claude.json` | one generated plugin file, `~/.config/opencode/plugins/riotbox-context-mode.js`   |
| Where the code runs    | a short-lived hook process per matched tool call, plus an MCP child process        | in-process, inside opencode's own embedded bun                                    |
| How the `ctx_*` tools arrive | over MCP, named `mcp__plugin_context-mode_context-mode__ctx_*`              | eleven native opencode tools the plugin registers directly — no MCP server at all  |
| Where interception happens | a `PreToolUse` matcher, reproduced from upstream and asserted at build time    | `tool.execute.before`, enforced in-process                                        |
| Store                  | `~/.claude/context-mode`                                                          | `~/.config/opencode/context-mode`                                                 |

What changes when enabled:

- `WebFetch` is redirected to Context Mode's own fetch tools, which store the
  response and return a summary. Large `Bash` output gets a routing suggestion
  rather than a hard redirect, so savings there depend on the model taking it.
- **`WebSearch` is not intercepted on Claude Code.** It appears in no alternative
  of the `PreToolUse` matcher (`CONTEXT_MODE_MATCHER` in
  `agents/claude/context-mode.sh`, which reproduces upstream's
  `PRE_TOOL_USE_MATCHERS` verbatim), and a `PreToolUse` hook only runs for the
  tools its matcher names — so search results still land in the transcript in
  full. **opencode has no matcher at all**: routing is decided in-process inside
  `tool.execute.before`, so which tools it intercepts is upstream's runtime
  decision rather than a list riotbox reproduces and the build asserts.
- The FTS5 store lives in the session directory
  (`~/.local/share/riotbox/<session>/context-mode`), under the config directory of
  the agent that wired it — in-container `~/.claude/context-mode` for Claude Code
  and `~/.config/opencode/context-mode` for opencode. It holds verbatim tool
  output — treat it with the same sensitivity as your session transcripts.
  `riotbox session-remove` deletes it along with the rest of the session.

  The location is per agent rather than shared, which is a deliberate cost: a
  session directory reused with a different `--agent` starts from an empty store,
  because recall does not cross from one agent's store to the other's. Only one
  agent's *wiring* exists in a session directory at a time — starting a session
  with a different `--agent` strips the other's on the way in — but the stores
  themselves both stay until the session directory is removed.
- **Two stores, both in the session directory.** `content/` holds the parked tool
  output; `sessions/` holds continuity — what the session did, and the snapshot
  `PreCompact` writes so an autocompact does not lose the thread. Both persist for
  the project set, so `riotbox resume` and a fresh run on the same projects pick up
  what the last one learned.
- **The session prints what it kept out when it exits**, the same way
  `RIOTBOX_HEADROOM=1` prints its token summary:

  ```text
  ── context-mode ─────────────────────────────────────
   this run 218 KB kept out · 21.5 KB re-read via ctx_search · 8.2 KB hook log on disk
   last 7 days 1.4 MB
   store: /home/llm/.claude/context-mode (this project set)
  ```

  "Kept out" is upstream's `bytesAvoided` — bytes the hooks withheld from the
  model's context — and nothing else; the re-read figure is what came back out of
  the store to pay for it, omitted when it is zero. Deliberately **not** what
  `context-mode statusline` shows for the same store: its headline adds the
  session bookkeeping and the resume snapshot to the savings and prints a
  percentage of them, which is why it reads near 100% even for a session that
  redirected nothing. See `container/context-mode-summary.sh`.
- **A wired session always prints the report, including when it saved nothing.**
  That is the case worth reading closely:

  ```text
  ── context-mode ─────────────────────────────────────
   this run 0 B kept out · 8.0 KB hook log on disk
   last 7 days 0 B
   store: /home/llm/.claude/context-mode (this project set)
  ```

  The hooks fired and withheld nothing. "Hook log on disk" is `eventDataBytes`,
  the continuity rows `PostToolUse` writes for every matched call whether or not
  anything was redirected. **It is not a token cost** — those rows are read back
  only by aggregate queries and never enter a context window, so the unit is
  bytes on disk, not context. It is on the line as proof-of-life: non-zero means
  the hooks ran, which beside a zero kept-out is the whole diagnosis. A missing
  report means something else entirely: the wiring did not complete. Look for
  `[context-mode] WARN` on stderr at session start, and see "Context Mode does
  not appear to do anything" below.

  The figures cover the store, not one session: `mount-projects.sh` allows two
  concurrent sessions per project set and they share one store, so each one's
  report includes the other's bytes.

  "Last 7 days" is the honest ceiling, not a display choice: the totals come from
  `session_events`, and upstream's `hooks/sessionstart.mjs` calls
  `cleanupOldSessions(7)` — a hardcoded literal with no configuration knob —
  deleting event, meta and resume rows for sessions older than a week. The parked
  content is untouched by that sweep (`ctx_purge` is the only thing that removes
  it), so retrieval keeps working across the boundary while the counters reset.
  Totals beyond seven days have to be captured at session exit; they cannot be
  recovered from the store afterwards.

  Nothing prints in two cases now: the store could not be read at exit, or the
  session degraded to Context Mode off. A zero run prints a row of zeros rather
  than nothing, so an absent report always means one of those two.
- **Each session exit also writes a durable record**, one small JSON file per
  run, into `${RIOTBOX_CONTEXT_LEDGER:-${XDG_DATA_HOME:-~/.local/share}/riotbox-context-mode}/runs/`.
  This is deliberately outside `RIOTBOX_DATA_DIR`, so `riotbox session-reset`
  and `riotbox session-remove` cannot erase it along with a session directory.
  That separation matters because of the seven-day pruning described above:
  the store's own counters do not survive past a week, which is why the exit
  report says "last 7 days" rather than "lifetime". A total spanning longer
  than that exists only because it was captured into the ledger at the moment
  each session exited — there is nothing left in the store to re-derive it
  from later.
- **`riotbox ctx-stats` aggregates the ledger.** It runs entirely on the host —
  no container starts — and reads every record under the ledger directory.
  Default view, run against a ledger with four valid records, one
  `baseline_unknown` run, one record from a newer schema, and one unreadable
  file:

  ```text
  ── context-mode rollup ──────────────────────────────
   4 runs  2026-07-28 → 2026-07-29
   kept out  264 KB
   re-read   21.0 KB
   hook log  18.2 KB (disk, not tokens)
   1 run saved nothing
   1 run excluded (baseline unknown)
   1 record from a newer schema (upgrade riotbox)
   1 file skipped (unreadable)
   ledger: /tmp/riotbox-context-mode-demo/runs
  ```

  Other views:

  - `--by-project` — the same totals grouped by project set. A project whose
    every run is `baseline_unknown` prints `unmeasured` rather than `0 B`,
    which would read as measured-and-saved-nothing.
  - `--runs [N|all]` — a per-run table, newest first, 20 rows by default.
    `--runs 0` is rejected at parse time (exit 2) rather than silently
    producing an empty table that would be mistaken for an empty ledger.
  - `--json` — the aggregation as JSON, for scripting.
  - `--ledger-dir DIR` — read records from `DIR` instead of the mounted
    ledger.

  `--by-project` and `--runs` are mutually exclusive view selectors:
  `ctx-stats --by-project --runs 5` exits 2 with `choose one of --by-project
  or --runs` rather than letting the second flag silently win. Repeating the
  same selector is fine.
- **The record schema**, one file per run, written by
  `context_mode_ledger_append` in `container/context-mode-summary.sh`:

  ```json
  {
    "schema": 1,
    "started_at": "2026-07-30T14:02:11Z",
    "ended_at": "2026-07-30T14:48:03Z",
    "session_id": "a3f9c1d4e8b27f60",
    "project_set": "riotbox",
    "agent": "claude",
    "kept_out_bytes": 219184,
    "re_read_bytes": 21500,
    "hook_log_bytes": 8412,
    "retained_total_bytes": 221184,
    "baseline_unknown": false
  }
  ```

  `kept_out_bytes`, `re_read_bytes` and `hook_log_bytes` are `null` and
  `baseline_unknown` is `true` when a run's start snapshot could not be read
  — a concurrent session held the write lock. `ctx-stats` counts those runs
  (they happened) but excludes them from the kept/re-read/hook-log totals,
  because a run whose start point is unknown has no honest delta to add.
- **Audit sessions are not recorded.** `riotbox audit` runs with
  `RIOTBOX_READONLY=1` and gets no ledger mount at all. The mount is an
  ordinary read-write bind mount — nothing enforces "write-only" at the
  podman level — and its filenames and record contents name every other
  project set you work on. An untrusted repo being audited does not get
  handed that.
- **Three kinds of records get disclosed, not silently dropped:** files that
  cannot be parsed as valid records ("N files skipped (unreadable)"),
  records written by a newer schema than this reader understands ("N records
  from a newer schema (upgrade riotbox)"), and runs excluded from the
  aggregate totals because their baseline was unknown ("N runs excluded
  (baseline unknown)"). The first two are reported by every view, including
  the empty-ledger message when they're the only thing the ledger holds; the
  third is specific to the default aggregate view — `--by-project` and
  `--runs` surface baseline-unknown runs per row instead (`unmeasured`,
  `baseline unknown`). A reader that silently skipped any of these would
  under-report a total while still presenting it as complete — the wrong
  answer, stated with confidence.
- **Event forwarding is neutralized.** Context Mode can POST session events to a
  remote platform when a `platform.json` config file exists. RiotBox ships that
  file's directory root-owned and unwritable at both paths Context Mode resolves
  by default — `~/.context-mode` when `XDG_CONFIG_HOME` is unset, and
  `~/.config/context-mode` when it is left at `~/.config` — so the file stays
  absent and cannot be created inadvertently. A session that points
  `XDG_CONFIG_HOME` somewhere else moves the path outside both. Absent is also
  the only state Context Mode reads without logging, so the closed gate is silent
  rather than warning on every tool call. This is not a boundary against a
  deliberate actor — the container's user holds `sudo` — and `RIOTBOX_NETWORK=none`
  remains the hard control. See [Context Mode store and
  wiring](THREAT_MODEL.md#context-mode-store-and-wiring).
- **Wiring the session needs no network, on either agent.** RiotBox writes the
  wiring itself rather than running `context-mode upgrade`, which clones upstream
  and overwrites the installed package with whatever is on `main`. On opencode
  the same reasoning is why the generated plugin file re-exports the copy
  **vendored in the image, by absolute path**, instead of riotbox adding
  `"plugin": ["context-mode"]` to the opencode config: an npm plugin entry makes
  opencode `bun install` the package from the registry at every startup, which
  needs network (`RIOTBOX_NETWORK=none` forbids it) and floats the version off
  the pin the image build asserts against.

  One outbound request remains on the Claude path, and it is not RiotBox's: the
  MCP server GETs `https://registry.npmjs.org/context-mode/latest` at startup to
  warn about newer versions. It carries no payload, fails soft, and — unlike
  headroom and CodeGraph — has no off switch; `RIOTBOX_NETWORK=none` is what
  suppresses it. The opencode path has no counterpart, because it starts no
  server: the plugin imports the server module with
  `CONTEXT_MODE_EMBEDDED_PLUGIN_TOOLS=1`, which is exactly the flag that skips
  the startup routine the version check lives in. See [Context Mode store and
  wiring](THREAT_MODEL.md#context-mode-store-and-wiring) in the threat model.
- **A `context-mode` entry in your own opencode config is dropped, and riotbox
  says so.** opencode loads a local plugin file and an npm plugin of the same
  name as two separate plugins, so leaving both in place would register the
  eleven `ctx_*` tools twice and fire every hook twice. When
  `RIOTBOX_CONTEXT_MODE=1`, `context-mode` and `context-mode@<version>` are
  filtered out of the `plugin` array of the generated `opencode.jsonc` and a
  warning on stderr names what was dropped and why. Your host config is not
  modified, and with the toggle off nothing is filtered — the entry is then your
  own plugin choice.
- Context Mode runs on its own pinned Node 22 inside the image on the Claude
  path, independent of whichever Node versions the build mirrored from your host.
  **The opencode path does not use it**: the plugin runs under opencode's
  embedded bun, and upstream's `bun:sqlite` adapter means the native SQLite
  addon that forced the pinned Node is never loaded there.
- **Two degradations are specific to opencode, and neither is a riotbox bug:**
  - *Weaker session-resume attribution.* opencode has no `SessionStart` hook
    upstream — the adapter cites issues #14808 and #5409 for it. The adapter
    compensates with plugin-init cleanup and a resume snapshot injected into the
    system prompt, but continuity across sessions is not as strong as on Claude
    Code, where `SessionStart` replays the store directly.
  - *`opencode --pure` turns it off entirely.* That flag runs opencode without
    external plugins, so the shim never loads and nothing engages. RiotBox warns
    on stderr when it sees `--pure` with `RIOTBOX_CONTEXT_MODE=1` and then
    continues unchanged — `--pure` is your explicit instruction, not riotbox's to
    override.
- `riotbox doctor` reports the agent as well as the image. Ask for Context Mode
  with an agent that has no support in riotbox and the check passes with a
  message saying the session will run with the feature off, rather than reporting
  a bare `[ok]` that says nothing about the agent you selected.
- Wiring is removed again the first time a session starts without the toggle, or
  with a different `--agent`, so a session directory never outlives the feature
  holding hooks that point at a binary that is gone, or one agent's wiring while
  another agent runs.

**Mutually exclusive with `RIOTBOX_HEADROOM=1`.** Both reduce context, at
different layers; the combination is unmeasured, so the launcher refuses the pair
rather than shipping an unsupported configuration. Headroom compresses payloads in
flight and is unconditional; Context Mode keeps output out of the transcript
entirely but relies on the model's cooperation for the `Bash` path.

The toggle accepts only the literal `1` — anything else disables the feature
(`riotbox doctor` flags unrecognized values).

> **Licence note:** Context Mode is [Elastic Licence
> 2.0](https://github.com/mksglu/context-mode/blob/main/LICENSE) — source-available,
> not OSI open source, unlike everything else in the image. It is pulled from npm
> onto your machine at `riotbox build` time and is not redistributed in the rpm/deb
> packages. See
> [`docs/dev/decisions/context-mode-adoption.md`](docs/dev/decisions/context-mode-adoption.md)
> for the full evaluation, including what was and was not measured.

## CodeGraph code intelligence

[CodeGraph](https://github.com/colbymchenry/codegraph) is a pre-built knowledge graph of
every symbol, call edge, and dependency in a project. Agents answer structural questions
("how does X reach Y?") from one query instead of a grep-and-read loop, which is where
most of the token spend on a large codebase goes. It runs entirely locally.

RiotBox ships it in the image (pinned version, telemetry permanently off) and wires its
MCP server at session start into every agent CodeGraph detects. Building the index is a
one-time step per project, and RiotBox does not do it for you:

```sh
riotbox shell ~/code/myproject
# inside the container:
codegraph init
```

The container prints a reminder for any project that has no index yet. After `init`,
nothing else is needed — the index lives in `.codegraph/` at the project root, and
CodeGraph brings it up to date at session start and watches for changes for the rest of
the session. On an ordinary read-write project mount it therefore persists across
restarts through the same bind mount as your code; the overlay and `:O` cases below are
the exceptions.

Details worth knowing:

- **Shell scripts are not indexed.** CodeGraph covers 28 languages — TypeScript,
  JavaScript, Python, Go, Rust, Java, C#, C/C++, Ruby, PHP, Swift, Kotlin, and so on —
  but Bash is not among them. `codegraph init` on a shell-only project reports
  `No files found to index` and leaves an empty index, which is why RiotBox's own
  codebase gains nothing from it. Check the
  [supported languages](https://github.com/colbymchenry/codegraph#supported-languages)
  before indexing.
- **Telemetry is off in three independent ways**: `DO_NOT_TRACK=1` from the entrypoint
  (which also disables CodeGraph's update check), `CODEGRAPH_TELEMETRY=0` in the image,
  and a stored opt-out written at build time.
- **The index is never committed.** CodeGraph writes a `.codegraph/.gitignore` that
  ignores the whole directory, and RiotBox's managed `.git/info/exclude` block lists
  `.codegraph/` as well.
- **Session wiring lives in the session directory.** `codegraph install` runs at every
  session start and writes into the session's `~/.claude/settings.json`: an
  `mcp__codegraph__*` permissions entry and a `UserPromptSubmit` hook that runs
  `codegraph prompt-hook` on every prompt. It also appends a marker-fenced block to
  `~/.claude/CLAUDE.md` and `~/.config/opencode/AGENTS.md`; `CLAUDE.md` is re-synced from
  the host every launch, as is `AGENTS.md` whenever you have a host `~/.config/opencode`,
  so those blocks do not pile up. None of it reaches your host configuration.
  `settings.json` is the exception — RiotBox never syncs it in either direction, so wiring
  written by an earlier image would outlive that image and keep invoking `codegraph
  prompt-hook` on every prompt after you roll back to one without CodeGraph. The first
  session that starts with no `codegraph` on `PATH` therefore strips that hook and the
  `mcp__codegraph__*` entry back out and reports what it removed, leaving your own hooks
  and permissions untouched. You never have to run `codegraph uninstall` from an image
  that no longer ships it. See [THREAT_MODEL.md](THREAT_MODEL.md) for the full analysis.
- **The index contains your source.** It stores verbatim code and symbol names — treat
  `.codegraph/` with the same sensitivity as the project itself.
- **In overlay mode**, the index is written into the overlay rather than your project and
  is treated as a rebuildable cache rather than a change: it never appears in `riotbox
  overlay-diff` and never blocks the next session. Because it lives in the session
  directory there, `riotbox session-remove` and `riotbox session-reset` delete it. See
  [Overlay mode](#overlay-mode-podman-only) for what `overlay-accept` and
  `overlay-reject` do with it.
- **Only a `.codegraph/` at the project root is treated as a cache.** If you index a
  subdirectory of a mounted project, that index counts as an ordinary change everywhere —
  it shows up in `overlay-diff` and will hold up the next overlay session. The filter is
  anchored deliberately: matching at any depth would let anything under a directory named
  `.codegraph` reach your project through `overlay-accept` without ever appearing in the
  review you ran first.
- **On unowned project directories** (podman `:O` mounts — see [Unowned project
  directories](#unowned-project-directories)), all writes are ephemeral, so the index is
  discarded when the container exits and `codegraph init` runs again next session.

## Overlay mode (podman-only)

Overlay mode mounts your project read-only and uses fuse-overlayfs to capture all changes in a separate layer. The host project is never modified directly.

```sh
# Enable for a single session
RIOTBOX_OVERLAY=1 riotbox shell .

# Enable permanently
echo 'RIOTBOX_OVERLAY=1' >> ~/.config/riotbox/config
```

After the session exits, review and apply or discard:

```sh
riotbox overlays          # List pending overlays
riotbox overlay-diff      # See what changed
riotbox overlay-accept    # Apply changes to your project
riotbox overlay-reject    # Discard all changes
```

A [CodeGraph](#codegraph-code-intelligence) index (`.codegraph/`) is rebuildable derived
data, not a change to review, so it is excluded from `overlay-diff`, from the file counts
in `riotbox overlays`, from the session exit summary, and from the check that refuses to
start a new session while changes are pending. Rebuilding an index therefore never locks
you out. `overlay-accept` still copies it through to your project alongside the changes
you accepted; an overlay containing *only* an index counts as no changes at all, so both
`overlay-accept` and `overlay-reject` report nothing to do and the index simply stays in
the overlay for the next session. One consequence: such an overlay is invisible to
`riotbox overlays`, including its disk usage, so a large index can sit in the session
directory unreported — `riotbox session-remove` clears it.

> Overlay mode requires podman. Docker is not supported due to differences in how it handles bind-mounted overlays.

### Unowned project directories

When `riotbox` is pointed at a directory you do not own (e.g. a tree under `/usr/src`, a coworker's checkout, a shared-storage clone), the launcher automatically substitutes podman's `:O` overlay mount for that path. This bypasses the SELinux relabel that ordinary bind mounts require — the host source is never modified.

Two consequences:

- **Writes are ephemeral.** Anything the container writes to an unowned path lands in an in-memory overlay layer that is discarded when the container exits. To persist changes, copy or clone the source to a location you own first.
- **Podman only.** Docker has no per-mount overlay equivalent. If you run under Docker and any project path is unowned, the launcher refuses to start with an error naming the offending path.

The check is per-mount: a multi-project set with a mix of owned and unowned directories works — owned paths use the normal `:z` mount and keep persistent writes, only the unowned ones go ephemeral. When `RIOTBOX_OVERLAY=1` is set alongside an unowned path, the launcher emits a short warning naming the affected paths so the persistence delta is visible.

## What could go wrong

The agent runs autonomously with full write access to your project directory and passwordless sudo inside the container. This is powerful but comes with real risks:

- **The agent can delete your entire project and start over.** It may decide your codebase is too messy to fix and `rm -rf` everything. This has happened.
- **The agent can rewrite git history.** Force-pushes, rebases, and `git reset --hard` are all available.
- **The agent can install arbitrary packages** via dnf, npm, pip, cargo, etc. These run inside the container and can't affect the host, but they can affect the project.
- **The agent can make sweeping refactors** that look correct but subtly break things. Always review changes before merging.
- **Multiple riotbox runs on the same project can conflict** if run concurrently without separate branches.

### Built-in protections

RiotBox includes several layers of protection, but none are foolproof:

- **Local bare backup**: Before every `run`, all refs and tags are pushed to a bare clone at `~/.local/share/riotbox/backups/<project>.git`. This backup lives outside the container's mount tree — the agent cannot access or modify it. Even if the agent deletes every file and rewrites all history, the backup is intact.
- **Checkpoint tags**: A git tag (`riotbox-checkpoint/<timestamp>`) is created on the current HEAD before each run. Tags survive history rewrites inside the container.
- **Session branches**: On `shell` sessions, the container offers to create a `riotbox/<id>` branch. The agent works there; on exit the branch is fast-forward merged back so the full commit history lands seamlessly on your branch. See [Session branches](#session-branches).
- **Git repo bootstrapping**: If a project directory isn't a git repo, RiotBox offers to create one so the checkpoint mechanism has something to protect. Empty repos (no commits yet) are handled gracefully — see [Initializing a git repo](#initializing-a-git-repo).
- **Managed `.git/info/exclude` block**: Before each checkpoint commit, RiotBox injects a managed block into the project's `.git/info/exclude` file that excludes common runtime artifacts — `.headroom/`, `.codegraph/`, `.claude/settings.local.json`, `CLAUDE.local.md`, `venom.log`, and `venom.*.log` — so they're never swept into history. This file is per-clone and never reaches collaborators (it lives in `.git/`, which is not tracked). You can add your own exclusion patterns anywhere outside the `>>> riotbox managed excludes <<<` markers; RiotBox only ever touches content between them.
- **Git guardrails**: Inside the container, `receive.denyNonFastForwards` and `receive.denyDeletes` are enabled to prevent the most destructive git operations.
- **Container isolation**: The agent can't access your SSH keys, cloud credentials, or anything outside the mounted directories.

### Recovery

If the agent makes a mess, you have several recovery options:

```sh
# Fetch everything from the backup into your project
cd /path/to/my-project
git fetch ~/.local/share/riotbox/backups/my-project.git --all --tags
git reset --hard riotbox-checkpoint/<timestamp>

# Or clone a fresh copy from the backup
git clone ~/.local/share/riotbox/backups/my-project.git my-project-restored
```

### Session branches

When you start an interactive session (`riotbox shell`) against a single-repo workspace, the container prompts you to create a session branch:

```
  Git repo detected on branch 'main'.
  Create session branch 'riotbox/20260309-143022-a1b2c3d4'? [Y/n]
```

If you say yes, the agent works on `riotbox/<id>` instead of your current branch. On clean exit, the session branch is fast-forward merged back so all commits land directly on your branch with their original messages and timestamps:

```
  [session-branch] Session complete. Merging riotbox/... → main...
  [session-branch] 7 commit(s) to fast-forward.
  [session-branch] Fast-forward complete. 7 commit(s) on main, session branch removed.
```

**If the fast-forward fails** (the base branch has diverged since the session started): the session branch is preserved and a recovery hint is printed. No data is lost.

**If the container is hard-killed** (SIGKILL, OOM): teardown doesn't run, but the session branch persists on disk and can be merged manually:

```sh
git checkout main
git merge --ff-only riotbox/<id>
```

**Controlling session branch behavior** via environment variable:

| Value              | Behavior                                      |
|--------------------|-----------------------------------------------|
| *(unset)*          | Prompt at session start (default for `shell`) |
| `SESSION_BRANCH=1` | Auto-create, no prompt                        |
| `SESSION_BRANCH=0` | Skip silently (default for `run`)             |

```sh
SESSION_BRANCH=1 riotbox shell   # always create a session branch
SESSION_BRANCH=0 riotbox shell   # never create one
```

Session branching is automatically disabled for `riotbox run` (non-interactive) since those runs are scripted and already checkpoint before starting.

### Initializing a git repo

Checkpoint protection needs a git repo. RiotBox handles the two "missing repo" cases so a session never errors out:

- **Empty repo (no commits yet):** Starting in a freshly `git init`'d directory is fine. There's nothing to back up until the first commit, so the checkpoint step prints `empty git repo (no commits yet) — nothing to checkpoint` and the session continues. (If the directory has uncommitted files, the checkpoint commits them and tags that first commit as usual.)

- **Not a git repo:** In an interactive session (`shell`, `resume`), RiotBox asks before creating one:

  ```
    /path/to/project is not a git repository.
    Create one so your work can be checkpointed? [Y/n]
  ```

  Answer yes (the default) and the directory is initialized, any existing files are committed, and a checkpoint tag is created. Answer no and the session continues without checkpoint protection (you'll see the no-protection warning).

**Controlling repo creation** via environment variable:

| Value                | Behavior                                                                                       |
|----------------------|------------------------------------------------------------------------------------------------|
| *(unset)*            | Prompt on an interactive terminal (default Yes); skip without creating on non-interactive runs |
| `RIOTBOX_GIT_INIT=1` | Always create the repo, no prompt                                                              |
| `RIOTBOX_GIT_INIT=0` | Never create; warn that there's no checkpoint protection                                       |

```sh
RIOTBOX_GIT_INIT=1 riotbox run "scaffold a new project" ./new-dir   # init non-interactively
RIOTBOX_GIT_INIT=0 riotbox shell ./scratch                          # never touch the dir
```

Non-interactive callers (`riotbox run`, CI, scripts) never block on the prompt: with `RIOTBOX_GIT_INIT` unset they skip creation rather than create a repo in your directory without consent.

### Recommendations

- **Always use git repos.** The checkpoint and backup mechanisms are your primary safety net.
- **Push to a remote before running the agent.** Belt and suspenders.
- **Review changes before merging.** Use `git diff riotbox-checkpoint/<tag>..HEAD` to see everything the agent did.
- **Use branches.** Run the agent on a feature branch, not main. Session branching automates this.

## Security model

### What's exposed to the container

| Resource                                 | Access                       | Notes                                         |
|------------------------------------------|------------------------------|-----------------------------------------------|
| Project directory                        | read-write bind mount (`:z`) | Your code — the agent needs full access       |
| Session data (`~/.local/share/riotbox/`) | bind mount (`:z`)            | Isolated per project set                      |
| `~/.claude/.credentials.json`            | nested bind mount (RW)       | OAuth token refreshes must write back to host |
| `~/.claude.json`                         | file copy into session dir   | Each container gets a writable snapshot       |
| RiotBox config (`~/.config/riotbox/`)    | bind mount (`:z`)            | `plugins.conf`, `config`, `mounts.conf`       |
| Host plugins (`~/.claude/plugins/`)      | read-only bind mount         | Merged into session at startup                |
| User scripts (`~/bin`)                   | read-only bind mount         | Available but not writable                    |
| User-defined mounts                      | read-only bind mount         | From `~/.config/riotbox/mounts.conf`          |
| Package caches                           | named volumes                | Shared across containers, not with host       |
| Network                                  | enabled                      | The agent needs npm/PyPI/crates.io etc.       |

### What's NOT exposed

`~/.ssh`, `~/.gnupg`, `~/.kube`, `~/.aws`, `~/.claude` (host conversations), cloud credentials, and anything not explicitly listed above (unless added to `mounts.conf`). The `.dockerignore` also blocks secrets (`.env`, `*.pem`, `*.key`, etc.) from being baked into the image.

### Other design choices

- **Sudo**: the container user has passwordless `sudo`. The agent often needs to `dnf install` build dependencies, and the container is disposable. This does **not** grant any host privileges.

- **UID/GID mapping**: the container user's UID and primary GID match your host UID and GID. The image is built per-host-user via `--build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g)` so the baked-in llm entry already carries the correct UID/GID for the building user — this is the load-bearing alignment that keeps podman's keep-id /etc/passwd rewrite from producing an inconsistent state.
  At runtime, `--userns=keep-id:uid=$(id -u),gid=$(id -g)` and `--user $(id -u):$(id -g)` are passed explicitly as belt-and-suspenders for cases where an image is used by a different host user than the one that built it. `fuse-overlayfs` is required for acceptable performance on large images.

- **SELinux**: project and session bind mounts use `:z`. Package caches use named volumes to avoid relabeling overhead. `.claude.json` is copied rather than mounted to avoid `:z` relabeling issues on 600-permission files; `.credentials.json` is bind-mounted RW inside the session directory (a nested mount that avoids the relabeling problem).

- <a id="build-time-config-collection"></a>**Tool configs** (`.npmrc`, `.editorconfig`, etc.) are copied at build time — not mounted — so edits inside the container don't affect the host. Auth tokens are stripped from `.npmrc`, `pip.conf`, and `cargo/config.toml` before baking into the image. Use `mounts.conf` to supply live credentials at runtime.

- **Nested containers**: `RIOTBOX_NESTED=1` is a privileged mode for running podman-in-podman; default mode keeps a tighter profile. The flag set is:

  - `--userns=keep-id:uid=$(id -u),gid=$(id -g),size=65536` — widens the keep-id mapping so the inner container has a subordinate uid range to carve from, while the outer process still owns its bind-mounted host paths (project dirs and session dir keep their host ownership). Explicit `uid=` and `gid=` are required: podman's default `keep-id` fills the inner GID slot from host_uid, which silently
    misaligns the in-container `/etc/subgid` for users whose host UID and primary GID differ.
  - `--security-opt label=disable` — SELinux confinement off (the default container_t policy denies inner-to-inner transitions).
  - `--security-opt unmask=ALL` — removes every default OCI mask AND readonly path on `/proc` and `/sys`. Inner crun writes `/proc/sys/net/ipv4/ping_group_range` and mounts a fresh `/proc`; narrower targets (verified) do not work.
  - `--cap-add=SYS_ADMIN` — inner crun calls `sethostname` and `mount` during setup; the cap is bounded by the outer userns.
  - `--device /dev/fuse`, `--device /dev/net/tun` — outer storage and pasta networking.

  Inside the container, entrypoint runs `nested-podman-setup.sh` which: (a) writes **v3** file capabilities on `newuidmap`/`newgidmap` via `setcap -n $(id -u) cap_setuid/setgid+ep` — v2 caps don't apply when the running process isn't root in the host's userns, which is why setuid-via-setcap silently no-ops without the `-n` flag; (b) writes `/etc/sub{u,g}id` as up to two ranges that cover the
  outer's mapped uids minus uid 0 (kernel restriction) and minus the user's own uid (newuidmap restriction); (c) overrides `~/.config/containers/storage.conf` to use the `vfs` driver, since nested overlay/fuse-overlayfs makes inner crun fail on `mkdir /run/secrets`. Only used when explicitly requested via `nested-run`/`nested-shell` or `RIOTBOX_NESTED=1`.

- **Socket mode**: `RIOTBOX_SOCKET=1` bind-mounts the invoking user's rootless `podman.sock` (at `$XDG_RUNTIME_DIR/podman/podman.sock`, or `/run/user/$(id -u)/podman/podman.sock` when `XDG_RUNTIME_DIR` is unset) and sets `CONTAINER_HOST` so the in-container `podman` is a thin remote client of the host engine. The rootful socket `/run/podman/podman.sock` is deliberately not considered — with
  `--userns=keep-id` it would be unreachable from the in-container user. This shares image cache and registry credentials across sessions but grants the container effective root on the host (anyone with API access to the socket can `podman run --privileged -v /:/host alpine chroot /host`). Mutually exclusive with `RIOTBOX_NESTED=1`.

## Development

### Additional prerequisites

The following are only needed if you want to run the linters or tests locally (outside the container):

- [task](https://taskfile.dev) — drives the maintainer build/test/lint/release targets
- [shellcheck](https://www.shellcheck.net/) — shell script linter (`dnf install ShellCheck` or `brew install shellcheck`)
- [hadolint](https://github.com/hadolint/hadolint) — Dockerfile linter (`brew install hadolint` or download from [releases](https://github.com/hadolint/hadolint/releases))
- [venom](https://github.com/ovh/venom) — integration test runner (downloaded automatically inside the test container)

### Tasks

```sh
task check          # run all quality gates (lint + test + venom lint)
task lint           # shellcheck + hadolint
task test           # integration tests (builds test container, runs venom suites)
task test:direct    # run venom directly on host (skip container build)
task test:lint      # structural lint of .venom.yml test suites
task test:list      # list available test suites
```

The `check` target executes all three gates in parallel: `lint` (shellcheck and hadolint), `test` (venom integration suites in a container), and `test:lint` (structural validation of venom test files).

For quick iteration on a single suite — or when working in an agent sandbox without the test image built — use `task test:direct -- tests/<suite>.venom.yml` (or `scripts/venom-run.sh tests/<suite>.venom.yml` if you prefer to skip task). The wrapper runs venom directly on the host and routes all output (logs and result files) into `.test-output/`. Do **not** run `venom run` from the repo root
yourself: venom writes `venom.log` to CWD on every invocation (and rotates earlier runs to `venom.N.log`) with no flag to redirect it, so a bare invocation litters the working tree.

### Releasing

Releases are tag-driven. Bump the version, push the tag, and CI builds and publishes the packages:

```sh
task release:bump -- <ver>   # writes VERSION, commits, tags v<ver>
git push --follow-tags       # push the commit and the v<ver> tag together
```

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml), which builds the rpm and deb with a pinned [`nfpm`](https://nfpm.goreleaser.com/) (v2.46.3) and publishes them alongside a `SHA256SUMS` checksum file via `gh`. The three artifacts (`riotbox-<ver>-1.noarch.rpm`, `riotbox_<ver>_all.deb`, `SHA256SUMS`) attach to the GitHub release for the tag.

## Podman setup

Rootless podman requires `fuse-overlayfs` for this project. Without it, `--userns=keep-id` triggers a full ID-mapped layer copy on the ~8 GB image, which hangs indefinitely.

### Required: install fuse-overlayfs

```sh
sudo dnf install fuse-overlayfs
```

### Required: configure podman storage

Create `~/.config/containers/storage.conf`:

```toml
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "metacopy=on"
```

Then reset storage (this clears cached images — you'll need to rebuild):

```sh
podman system reset --force
riotbox build
```

### Recommended: containers.conf

Create `~/.config/containers/containers.conf`:

```toml
[containers]
init = false
```

This disables catatonit (podman's default init process), which segfaults on EL10 (`catatonit-0.2.1-3.el10`). The RiotBox image has its own entrypoint that handles signal forwarding.

### Optional: enable metacopy at the kernel level

For faster overlay operations, enable metacopy in the kernel:

```sh
# Enable now
echo "Y" | sudo tee /sys/module/overlay/parameters/metacopy

# Persist across reboots
echo "options overlay metacopy=on" | sudo tee /etc/modprobe.d/overlay.conf
```

## Troubleshooting

When something breaks, the first thing to try is `riotbox doctor` — it walks every host prerequisite (podman, fuse-overlayfs, image build, credentials, plugin/skill dirs) and prints a fix hint per failure. By default every check runs even if earlier ones failed, so a single invocation surfaces every problem at once; set `RIOTBOX_DOCTOR_FIRST_FAIL=1` to short-circuit at the first failure. The exit code is the FIRST failure encountered (0 on full pass). The same checks run at the end of `./setup.sh`, so a fresh install is self-verifying.

Other knobs:

| Env var                       | Effect                                            |
|-------------------------------|---------------------------------------------------|
| `RIOTBOX_DOCTOR_QUIET=1`      | Print only failures (still shows the fix hint)    |
| `RIOTBOX_DOCTOR_JSON=1`       | Emit one JSON line per check (machine-readable)   |
| `RIOTBOX_DOCTOR_FIRST_FAIL=1` | Stop at the first failure                         |
| `IMAGE_NAME=<tag>`            | Probe a tag other than `riotbox`                  |
| `RIOTBOX_CONTEXT_LEDGER=DIR`  | Where `ctx-stats` records/reads Context Mode runs |

### Container startup hangs

**Symptom**: `riotbox .` or `podman run` hangs indefinitely.

**Likely causes**:

1. **Missing fuse-overlayfs** — `--userns=keep-id` without fuse-overlayfs triggers a full ID-mapped layer copy on the ~8 GB image. Install fuse-overlayfs and configure storage.conf (see [Podman setup](#podman-setup)).
1. **SELinux relabeling** — bind-mounting large directories with `:z` causes recursive `chcon`. This was the original cause with cache directories (now using named volumes). If you add custom bind mounts, avoid `:z` on large trees.
1. **catatonit segfault** — check `journalctl --user -xe` for catatonit crashes. Set `init = false` in containers.conf.

**Diagnosis**: run with increasing complexity to isolate the issue:

```sh
# Bare minimum — does the image work?
podman run --rm -it localhost/riotbox echo hello

# Add userns — does ID mapping work?
podman run --rm -it --userns=keep-id localhost/riotbox echo hello

# Add project mount — does SELinux allow it?
podman run --rm -it --userns=keep-id -v $PWD:/workspace:z localhost/riotbox echo hello

# Full mount set — which mount causes the hang?
podman run --rm -it --userns=keep-id $(scripts/detect-mounts.sh) localhost/riotbox echo hello
```

### Claude Code hangs on startup

**Symptom**: container starts, but `claude` shows a blank screen or hangs.

**Likely causes**:

1. **Telemetry/update checks** — Claude Code tries to reach external services on startup. The entrypoint sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DO_NOT_TRACK=1`, and `DISABLE_AUTOUPDATER=1` to prevent this. If you're running claude directly (not via the entrypoint), set these manually.
1. **Auth file write failure** — Claude Code writes back to `~/.claude.json` on startup. If the file is read-only or on a read-only mount, Claude hangs in a retry loop. Auth files are now copied into the session directory to avoid this.
1. **Missing directories** — Claude Code expects `~/.claude/debug/` and `~/.claude/plugins/cache/` to exist. The entrypoint creates these, but if permissions are wrong they may silently fail. Check with `ls -la ~/.claude/` inside the container.

**Diagnosis**: check the debug log inside the container:

```sh
cat ~/.claude/debug/latest
```

### "Not logged in" inside the container

**Symptom**: Claude Code starts but says you're not logged in.

**Cause**: auth credentials aren't reaching the container. Before each run, RiotBox copies `~/.claude.json` into the session directory and bind-mounts `~/.claude/.credentials.json` into it.

**Check**:

- Verify the files exist on the host: `ls -la ~/.claude.json ~/.claude/.credentials.json`
- Verify the session directory is writable: `ls -la ~/.local/share/riotbox/`
- If the session directory is owned by a numeric UID (e.g., 525287), a previous run without `--userns=keep-id` left it with wrong ownership. Fix with: `sudo chown -R $(id -u):$(id -g) ~/.local/share/riotbox/`

### Context Mode does not appear to do anything

**Symptom**: `RIOTBOX_CONTEXT_MODE=1` is set, `riotbox doctor` passes, and the session shows no sign of the feature.

**Cause**: three different things look identical from outside. Work through them in order — each one has its own signal.

**Check**:

- **Did the wiring land?** A wired session says so once at startup — `  [context-mode] hooks wired; store at <dir>/context-mode.` on stdout under `--agent=claude`, `  [context-mode] opencode plugin shim wired at <path>.` on stderr under `--agent=opencode`. If neither appears, wiring gave up, and every give-up path explains itself on **stderr** as `[context-mode] WARN:` — a stream an autonomous run usually discards. Re-run capturing it: `RIOTBOX_CONTEXT_MODE=1 riotbox run "…" 2>/tmp/rb.err; grep context-mode /tmp/rb.err`. Most common causes: the selected agent has no Context Mode support in riotbox (the warning names it), the session config could not be written, or — on opencode — `--pure` was on the command line, which disables external plugins outright.
- **Is the exit report zero rather than absent?** `this run 0 B kept out · 8.0 KB hook log on disk` means the hooks ran and withheld nothing — the feature engaged and saved nothing. The hook-log figure is disk volume, not tokens. `bytesAvoided` only moves when the model actually routes large output through the sandbox tools; a session of small tool results has nothing to redirect. **No report at all** is the different problem, and it points back to the wiring check above.
- **Do not read `riotbox doctor` as proof the session works.** Its probe runs the image with `--entrypoint /usr/bin/bash`, which bypasses `container/entrypoint.sh` — the file where the per-session wiring actually happens. A green check proves the image ships a working `context-mode`, and that the agent you selected has Context Mode support at all, and nothing else about your session.
- **Compare against `context-mode statusline` and expect disagreement.** Upstream's headline divides `eventDataBytes` by 4 and calls the result saved tokens, so it reports a saving for a session that saved nothing. RiotBox reports `bytesAvoided` alone.

### Session directory owned by wrong UID

**Symptom**: `Permission denied` errors writing to `~/.local/share/riotbox/`.

**Cause**: a previous container run without `--userns=keep-id` (or with broken userns) caused files to be created with a subordinate UID. The mount-projects.sh script detects this and exits with an error message. Fix manually:

```sh
sudo chown -R $(id -u):$(id -g) ~/.local/share/riotbox/
```

### Build fails with permission denied

**Symptom**: `mkdir: cannot create directory '/home/llm/.cache/...': Permission denied` during build.

**Cause**: the multi-stage Containerfile copies security tools and installs semgrep as root, which creates directories under `/home/llm/` with root ownership. The Containerfile includes a `chown -R llm:llm /home/llm` step after these installs. If you modify the Containerfile and add root-stage installs after this chown, you'll hit this error. Always ensure the chown runs after all root-stage operations.

### IPv6 warnings in system journal

**Symptom**: `NetworkManager` logs IPv6 permission errors when containers start.

**Cause**: IPv6 is disabled on the host but podman's network stack creates veth interfaces that trigger NetworkManager's IPv6 configuration. These are cosmetic warnings and do not affect container operation.
