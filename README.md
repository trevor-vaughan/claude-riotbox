# RiotBox - Letting your coding agent run wild

______________________________________________________________________

> 🤖 LLM/AI WARNING 🤖
>
> This project was largely written by an AI coding agent. It has been reviewed and tested, but use in production at your own discretion.
>
> 🤖 LLM/AI WARNING 🤖

______________________________________________________________________

Container-based isolation for running AI coding agents autonomously against your projects. The container ships [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [opencode](https://opencode.ai/) and [Pi](https://pi.dev/) and mirrors your host dev environment (nvm, uv, Go, Rust, Ruby) so the agent has the same toolchain you do, but runs isolated from your credentials and secrets.

> **Security:** This project has an AI-generated [threat model](THREAT_MODEL.md) covering the container isolation boundary, auth handling, mount surface, and nested container mode. Read it before use.

## Why did I build this?

Claude has [Sandboxing](https://code.claude.com/docs/en/sandboxing), but I wanted the opposite of what that does. I wanted unbridled insanity, the ability to install whatever it needed, and the ability to map in multiple projects easily for complex coordinated development while I was sleeping.

I also use CentOS/RHEL and wanted something that would work natively in that environment.

Finally...it was fun!

## How it works

1. **`scripts/build.sh`** introspects your local environment (nvm, uv, Go, Rust/rustup, Ruby/RVM, UID, tool configs) and passes them as build args.
1. The **Containerfile** uses a multi-stage build: a `tools` stage downloads standalone binaries (trivy, grype, syft, task, venom), and the `runtime` stage assembles the final CentOS Stream 10 image with all toolchains. The agent CLIs are installed last — opencode via its [installer](https://opencode.ai/install), Pi from the lockfile pi.dev publishes for each release, then Claude Code via the [official installer](https://claude.ai/install.sh) — for
   optimal layer caching.
1. At runtime your project directory is bind-mounted into the container. Auth credentials are synced into an isolated session directory: `~/.claude/.credentials.json` is bind-mounted read-write (so token refreshes write back to the host), and `~/.claude.json` is copied so each container gets a writable snapshot without host contention.
1. **A single generic wrapper** (`container/agent-wrapper.sh`) shadows the real agent binaries via per-agent symlinks under `~/.riotbox/bin/`. The wrapper detects which agent it's running as from its own filename, looks up that agent's manifest at `agents/<name>/manifest.sh`, and applies the manifest's flag-injection rules. The RiotBox autonomy prompt lives at `/etc/claude-code/CLAUDE.md`
   (managed-policy path read by Claude) and at `~/.config/opencode/AGENTS.md` and `~/.pi/agent/AGENTS.md` (placed at runtime by each agent's setup hook). Selection happens via `--agent=claude|opencode|pi` (default `claude`); see `riotbox agents` to list the registered set.

## Prerequisites

- [Podman](https://podman.io/) or Docker (podman preferred, auto-detected)

- [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) (required for podman — see [Podman setup](#podman-setup))

- One of:

  - `ANTHROPIC_API_KEY` environment variable, **or**
  - `~/.claude.json` with OAuth tokens (created by running `claude` on the host and completing the OAuth flow)

- `flock` (from util-linux; installed on most Linux systems, and a dependency of the rpm and deb packages) — serializes the host-side config sync of concurrent launches of one project

- For a rootless install from a checkout: Go 1.26.4 or newer for `./install.sh --build`, or curl, tar, sha256sum and [cosign](https://github.com/sigstore/cosign) 2.6.2+ (or 3.0.4+) for `./install.sh --binary`. The rpm and deb packages need neither.

- [git-filter-repo](https://github.com/newren/git-filter-repo) (required for `reown` — `pip install git-filter-repo`)

- (Optional) nvm, uv, Go, rustup, RVM installed locally — the build mirrors whatever it finds

## Install

RiotBox installs as a normal application that puts a `riotbox` command on your PATH. Pick one of three paths:

```sh
# System package (rpm — Fedora/RHEL/CentOS)
sudo dnf install ./riotbox-<ver>-1.<arch>.rpm      # arch: x86_64 or aarch64

# System package (deb — Debian/Ubuntu)
sudo apt install ./riotbox_<ver>_<arch>.deb        # arch: amd64 or arm64

# Rootless (no sudo) — see ./setup.sh below for the guided variant
./install.sh --build     # compile riotbox-core with your Go toolchain
./install.sh --binary    # or download the signed release binary
```

**Layouts.** The two install models differ only in where files land:

|                               | App tree                                                    | CLI symlink            | Config dir                                               |
|-------------------------------|-------------------------------------------------------------|------------------------|----------------------------------------------------------|
| **rpm / deb** (system)        | `/opt/riotbox`                                              | `/usr/bin/riotbox`     | `/etc/riotbox/{config,mounts.conf,egress.conf}`          |
| **rootless** (`./install.sh`) | `$XDG_DATA_HOME/riotbox` (default `~/.local/share/riotbox`) | `~/.local/bin/riotbox` | `$XDG_CONFIG_HOME/riotbox` (default `~/.config/riotbox`) |

The `riotbox` dispatcher is self-locating, so it works from either tree without extra configuration.

**Rootless: `--build` or `--binary`.** `riotbox-core`, a small compiled helper the launcher calls, computes session keys, moves data an older release left behind, and checks for running containers. The rpm and deb ship it prebuilt; a checkout does not have it, so `install.sh` has to be told how to get it. It will not pick for you, because one way needs a Go toolchain and the other downloads code from the network.

- `--build` compiles it with the `go` on your PATH, which must be at least the version on the `go` line of `go.mod`. The build runs with `GOTOOLCHAIN=local`, so an older Go fails and names the version it needs instead of downloading a newer toolchain. No network access is needed.
- `--binary` downloads `riotbox-core_<ver>_linux_<arch>.tar.gz`, `checksums.txt` and `checksums.txt.sigstore.json` from the GitHub release that `VERSION` names (x86_64 and aarch64 only). cosign verifies that `checksums.txt` was signed by this repository's release workflow at tag `v<ver>`; then `sha256sum` checks the archive against its line in that file. The app tree is touched only after both checks pass. `VERSION` only changes in release commits, so a branch ahead of `v<ver>` still says `<ver>`, and the `v<ver>` binary would compute keys by that release's rules. A git checkout therefore must be exactly the commit tagged `v<ver>`, with no changes to tracked files that are installed or that riotbox-core is built from; otherwise `--binary` refuses before downloading anything. A tree that is not a git checkout (an unpacked source tarball) is accepted as is. Use `--build` everywhere else.

Either way, launches and the session and overlay commands refuse a `riotbox-core` that is missing or whose version is not the install's `VERSION`, saying how to fix it, and `riotbox doctor` reports that as `riotbox-core matches this install` (exit code 25).

**Upgrading a rootless install.** Update the checkout, then run `./install.sh --build` or `./install.sh --binary` again. It replaces the app tree and `riotbox-core` and leaves your config, sessions and backups alone. `./setup.sh` also works: it notices when the installed version differs from the checkout's, or the installed `riotbox-core` does not match, prints `riotbox installed but out of date: <reason>`, and offers to reinstall.

**Checking a downloaded package.** The rpm and deb are not GPG-signed, so `dnf`/`apt` check no signature when you install the file. To confirm a package came from this repository's release workflow, verify `checksums.txt` with cosign and then the package against it, as described in [Verifying a release by hand](docs/dev/riotbox-core.md#verifying-a-release-by-hand).

**Config precedence** (highest to lowest):

```
env  >  $XDG_CONFIG_HOME/riotbox  >  /etc/riotbox  >  built-in defaults
```

This applies to the host-side settings the launcher reads: `config` (sourced by the launcher) and `mounts.conf` (read by mount detection). A value in your user config overrides the system `/etc/riotbox` default, and an explicit environment variable overrides both. Plugins are configured per-user only (`$XDG_CONFIG_HOME/riotbox/plugins.conf` or the `RIOTBOX_PLUGINS` env var) — they are applied
inside the container, where host `/etc/riotbox` is not visible, so there is no system-wide plugin layer. `egress.conf` is read from both places and combined; see [Egress proxy](#egress-proxy).

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

At the install step it asks whether to build `riotbox-core` here or download the signed release binary (`[b/r]`). Pass the answer up front to skip that question:

```sh
./setup.sh --build              # compile riotbox-core (needs Go)
./setup.sh --binary             # download the signed release binary
./setup.sh --yes --build        # accept every default, no prompts
./setup.sh --build --no-image   # skip building the container image
```

`--yes` needs `--build` or `--binary`, and an unknown option is an error. `--no-image` was called `--no-build`, which still works but is deprecated. `RIOTBOX_SETUP_YES=1` in the environment does the same as `--yes`, and `RIOTBOX_SETUP_NO_IMAGE=1` the same as `--no-image`. The old `RIOTBOX_SETUP_NO_BUILD` is still read.

### Manual setup

If you prefer to set things up yourself:

1. Install the `riotbox` command:

   ```sh
   ./install.sh --build         # symlink → ~/.local/bin/riotbox (default)
   ./install.sh --build ~/bin   # pick a different directory for the symlink
   ```

   Use `--binary` instead of `--build` to download the signed release
   binary; exactly one of the two is required (see
   [Rootless: `--build` or `--binary`](#install)).

   The app tree always lands in `$XDG_DATA_HOME/riotbox` (default
   `~/.local/share/riotbox`); only the entrypoint symlink's directory is
   configurable.

   Re-running `./install.sh` never overwrites your files in
   `$XDG_CONFIG_HOME/riotbox`. When a newer version of `config`,
   `mounts.conf`, `plugins.conf`, or `egress.conf` ships, the installer writes it beside
   yours as `<name>.new` (for example `config.new`) and prints the `diff`
   command to review it. Merge what you want, then delete the `.new` file.

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

Start from the main checkout, not a linked `git worktree`. A worktree's `.git`
file points at the main repository, which is not mounted into the container, so
git does not work there. RiotBox warns and asks `Continue in the current
directory? [y/N]` (default No); without a TTY it warns and continues.

## Using opencode

RiotBox ships with [opencode](https://opencode.ai/) installed alongside Claude Code. Pick the agent per command with the `--agent` flag:

```sh
# Run opencode against the current directory
riotbox --agent=opencode run "fix the build"

# Resume the last opencode session
riotbox --agent=opencode resume

# Open a shell with every agent binary on PATH (use any)
riotbox shell
```

Default is `claude` if `--agent` is omitted. You can persist a default in `~/.config/riotbox/config` by uncommenting the `RIOTBOX_AGENT` line.

> Want to add another agent (aider, goose, cursor-agent, codex, …)? See [`docs/dev/adding-an-agent.md`](docs/dev/adding-an-agent.md). The agent registry at `agents/registry.sh` is the single source of truth — adding an agent is a manifest plus a Containerfile install line, no edits to dispatch sites or wrappers.

### Opencode auth

1. **`opencode auth login` on the host** (recommended) — credentials at `~/.local/share/opencode/auth.json` are bind-mounted RW into the container. OAuth token refreshes write back to the host file.
1. **Provider env vars** — direct API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.) and Claude Code routing vars (`CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`, `AWS_PROFILE`, etc.) are passed through automatically when set on the host. See `~/.config/riotbox/config` for the full default list and how to extend it.
1. **Cloud SDK credential files** — `GOOGLE_APPLICATION_CREDENTIALS` (Vertex), `AWS_SHARED_CREDENTIALS_FILE` (Bedrock), `KUBECONFIG`, and `AWS_CONFIG_FILE` are auto-mounted **read-only** at a fixed in-container path and the env var is rewritten to that path. Configure via `RIOTBOX_CREDFILE_VARS`.

If `CLAUDE_CODE_USE_VERTEX` is set on the host but `GOOGLE_APPLICATION_CREDENTIALS` is unset, the launcher additionally checks for `~/.config/gcloud/application_default_credentials.json` (the file `gcloud auth application-default login` writes) and prompts before bind-mounting it. Answer `n` if you'd rather plumb credentials yourself; the launcher will skip the mount and print a notice. The
prompt is TTY-only — non-interactive launches always skip with a notice.

Long-lived AWS access keys (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) are **not** passed through by default — use a profile + credentials file instead. SSH agent forwarding is also out of scope.

### Opencode config

Your host `~/.config/opencode/` (agents, commands, themes, `opencode.json`, `opencode.jsonc`) is copied into the session's state dir (`~/.local/share/riotbox-state/<session>/opencode-config/`) at every launch; sessions of the same project that are already running see the refreshed copy. The container then merges `opencode.json` and `opencode.jsonc` into a single `opencode.jsonc` (jsonc wins on key conflict) and forces these keys to RiotBox values regardless of host input:

- `permission = "allow"` — the container is RiotBox; per-tool permission prompts are pointless inside it.
- `share = "disabled"` — no session telemetry from the container.
- `autoupdate = false` — the image pins opencode at build time.
- `instructions` includes `~/.config/opencode/AGENTS.md` — the RiotBox autonomy prompt is always loaded.

A banner comment in the generated `opencode.jsonc` records these forced keys. To change anything else (model, theme, agents, commands, etc.), edit your host `opencode.json` or `opencode.jsonc`; the next launch picks up the change.

### Opencode plugins

Plugins listed in your `opencode.jsonc` `plugin` array (npm packages or git URLs) are installed by opencode itself via `bun install` the first time you run a session. The install output (`node_modules/`, `package.json`, `package-lock.json`, `bun.lock`, `.gitignore`) is **not** copied from your host — those files are platform-specific and opencode's own `.gitignore` marks them disposable. Instead
the install lands in `~/.cache/opencode`, which RiotBox keeps in a persistent named volume (`riotbox-cache-opencode`). The cold install takes ~15s; later sessions resolve plugins from the warm cache in ~2s, offline. Because the plugins are built inside the container, their native dependencies always match the container platform regardless of your host OS.

## Using pi

RiotBox also ships the [Pi](https://pi.dev/) coding agent:

```sh
riotbox --agent=pi run "fix the build"   # headless: pi -p -- "<prompt>"
riotbox --agent=pi resume                # continue the last session for this project
riotbox shell                            # interactive: run `pi` at the prompt
```

Pi core tracks the latest release, like opencode and Claude Code: each image build installs whatever is current from the exact lockfile pi.dev publishes for that release, and `riotbox update` picks up a newer one. These extensions are pinned and preinstalled, giving Pi the equivalents of Claude Code's Task, AskUserQuestion and TodoWrite tools:

| Extension | Provides |
|---|---|
| `pi-subagents@0.77.0` | `subagent` tool — delegate work to child agents |
| `@juicesharp/rpiv-ask-user-question@2.13.8` | `ask_user_question` tool — structured questions instead of guesses |
| `@juicesharp/rpiv-todo@2.13.8` | `todo` tool and `/todos` |

Pi runs without approval prompts and trusts every project: a project's `.pi/` settings, extensions, skills, prompt templates and MCP servers load without a prompt. As with the other agents, the container is the security boundary.

Pi is not wired for [headroom](#headroom-context-compression-opt-in) (headroom has no Pi wrapper). It is wired for [Context Mode](#context-mode-opt-in) and [git-ai](#ai-authorship-attribution-git-ai).

### Pi auth

1. **Run `pi` on the host and `/login`** — `~/.pi/agent/auth.json` (and `mcp-auth.json` for MCP OAuth) is bind-mounted read-write, so token refreshes write back to the host. Without a host `auth.json` there is no bind: a `/login` inside the container is saved in the session's state directory (`~/.local/share/riotbox-state/<session>/pi-agent/auth.json`), so it lasts for that project set only and never reaches the host. Once a host `auth.json` exists, its bind mount takes precedence over the session copy.
1. **Provider env vars** — the same eight provider keys as opencode (see `~/.config/riotbox/config`) are forwarded automatically. Pi supports many more providers; forward their keys with `RIOTBOX_PASSTHROUGH_EXTRA_VARS`, e.g. `RIOTBOX_PASSTHROUGH_EXTRA_VARS="NVIDIA_API_KEY"`. They are not forwarded by default because the passthrough list is shared: every key it holds reaches every agent's container.

### Pi config

At every launch RiotBox copies these from your host agent directory (`$PI_CODING_AGENT_DIR`, else `~/.pi/agent`) into the session: `settings.json`, `models.json`, `mcp.json`, `keybindings.json`, `AGENTS.md`, `SYSTEM.md`, `APPEND_SYSTEM.md`, `skills/`, `prompts/` (Pi's `/` commands), `themes/`, `extensions/`. Symlinks are followed. An entry you delete on the host disappears from the session at the next launch. Pi's own state in the session — sessions, `trust.json`, the model catalog cache, and a `/login` made when there is no host `auth.json` — is kept between runs and never copied from the host. Changes Pi makes inside the container to the synced files (for example a model picked with `/model`, which writes `settings.json`, or edits under `skills/`, `prompts/` or `extensions/`) are replaced at the next launch; edit the host copy instead.

The sync runs on every launch whichever `--agent` you pick, so without a host Pi directory every launch prints one line, `Notice: <dir> not found on host — pi will use the container baseline.` It is harmless. A `PI_CODING_AGENT_DIR` containing whitespace breaks the session's mount flags; keep it to a path without spaces.

A host `AGENTS.md` takes the place of RiotBox's autonomy prompt, as it does for opencode; without one the session gets RiotBox's template. A `RIOTBOX_PROMPT` override beats both. The container then forces these `settings.json` keys:

- `packages` — the preinstalled extensions above (plus Context Mode when `RIOTBOX_CONTEXT_MODE=1`). Host entries are dropped with a notice: local paths name host directories, and npm/git entries would install unpinned code at startup. Put extensions you want in the container in `extensions/` instead.
- `defaultProjectTrust = "always"`, `enableInstallTelemetry = false`, `enableAnalytics = false`.

The `pi` command also runs with `PI_TELEMETRY=0` and `PI_SKIP_VERSION_CHECK=1`. Pi's model catalog refresh from pi.dev stays on, like opencode's models.dev fetch.

`riotbox tokscale` always counts Pi usage in RiotBox sessions. For your native Pi sessions on the host it relies on tokscale, which looks for them through `PI_CONFIG_DIR`, not `PI_CODING_AGENT_DIR`. If you relocated your Pi directory, native usage is missed unless you also set `PI_CONFIG_DIR`; the value tokscale expects has not been verified.

## Commands

| Command                               | Description                                                                                                                                 |
|---------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `riotbox build`                       | Introspect host environment and build the container image                                                                                   |
| `riotbox rebuild`                     | Force a clean rebuild with no layer cache                                                                                                   |
| `riotbox update`                      | Re-pull LLM CLI tools — opencode, Pi core, Claude Code, plugins to latest; Pi's extensions, headroom, CodeGraph, Context Mode at pinned versions (large re-download) |
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
| `riotbox session-remove [key/path]`   | Remove a session — its session and state dirs — by key or project path (or `--all`)                                                         |
| `riotbox session-reset [all] [force]` | Delete the current dir's session and state dirs, pending overlays too ([see](#session-state-directory)); `all`: every one; `force`: no prompt |
| `riotbox session-migrate [project...]` | Retry moving the current dir's old session data where an upgrade's move failed ([see](#upgrading-from-a-release-that-kept-state-in-the-session-directory)) |
| `riotbox overlays`                    | List sessions with pending overlay data (podman-only)                                                                                       |
| `riotbox overlay-diff [project...]`   | Show overlay changes vs host project(s); name every project of a multi-project session ([see](#overlay-mode-podman-only))                   |
| `riotbox overlay-accept [project...]` | Apply overlay changes to host project(s)                                                                                                    |
| `riotbox overlay-reject [project...]` | Discard overlay changes                                                                                                                     |
| `riotbox checkpoints [dir...]`        | List the pre-session snapshots RiotBox holds for a project (read-only; defaults to the current directory) — see [Recovery](#recovery)       |
| `riotbox checkpoint-tag <ts> [dir]`   | Promote snapshot `<ts>` to a real tag `riotbox-snapshot/<ts>` that ordinary git commands can see                                            |
| `riotbox checkpoint-prune [dir...]`   | Delete snapshot refs; needs one selector: `--keep <N>`, `--older-than <N>d`, or `--legacy` (old `riotbox-checkpoint/*` tags)                |
| `riotbox audit "<task>" [dir]`        | Read-only session for inspecting untrusted code (workspace mounted RO)                                                                      |
| `riotbox install-hooks [global]`      | Install the pre-push hook that blocks container-identity commits ([details](#reclaiming-authorship))                                        |
| `riotbox agents`                      | List registered agents (riotbox name + binary)                                                                                              |
| `riotbox tokscale [args...]`          | Unified [tokscale](https://github.com/IvGolovach/tokscale) usage across your native agent home + every riotbox session, offline (no telemetry); args pass through to tokscale                     |
| `riotbox ctx-stats [args...]`         | Context Mode savings recorded across sessions, read on the host from the run ledger — see [Context Mode](#context-mode-opt-in)               |
| `riotbox git-ai [args...]`            | Unified [git-ai](https://usegitai.com/) usage merged across every session store plus your own `~/.git-ai` — see [AI-authorship attribution](#ai-authorship-attribution-git-ai)                     |
| `riotbox repair-notes [--all]`        | Reattach orphaned git-ai attribution notes to the commits that replaced them after a history rewrite — see [AI-authorship attribution](#ai-authorship-attribution-git-ai) |
| `riotbox egress <list\|groups\|allow\|deny\|strict\|reload>` | Show or change a running `RIOTBOX_EGRESS=1` session's allowlist without restarting it — see [Egress proxy](#egress-proxy) |
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
- [`git-ai`](https://github.com/git-ai-project/git-ai) v1.7.5 — AI-authorship attribution via git notes, pinned per-arch and SHA256-verified (**on by default**, see [AI-authorship attribution](#ai-authorship-attribution-git-ai))
- [`bun`](https://github.com/oven-sh/bun) — JS/TS runtime, pinned and SHA256-verified. It is here for Context Mode's `ctx_execute` sandbox, which cannot run TypeScript snippets without it; it is on `PATH` and usable directly. Context Mode's Claude hooks do **not** use it — they run the image's pinned Node.
- [`jsonschema`](https://github.com/sourcemeta/jsonschema) — JSON Schema validator, linter and formatter CLI, pinned and SHA256-verified. It replaces the `python3-jsonschema` library the image used to carry.

**Diagram validation:**

- `plantuml` — UML diagram generation and validation
- `mmdc` ([mermaid-cli](https://github.com/mermaid-js/mermaid-cli)) — Mermaid diagram rendering

**Containers:**

- podman, fuse-overlayfs, slirp4netns (for nested container support)

**Forge CLIs** (only in the `riotbox-gh-glab` image — see [GitHub and GitLab](#github-and-gitlab-the-riotbox-gh-glab-flavor)):

- [`gh`](https://github.com/cli/cli) — GitHub CLI
- [`glab`](https://gitlab.com/gitlab-org/cli) — GitLab CLI

## Plugins

Claude Code [plugins](https://docs.anthropic.com/en/docs/claude-code/plugins) are managed by `container/plugin-setup.sh`, which runs at every container startup. Plugins are loaded in order of precedence (lowest to highest):

1. **Pre-staged defaults** — baked into the image at build time (defined in the `Containerfile`). Copied into the session on first run.
1. **Marketplace plugins** — installed from `~/.config/riotbox/plugins.conf` (one plugin name per line) or the `RIOTBOX_PLUGINS` environment variable (comma-separated). Already-installed plugins are skipped to avoid spawning Node.js on every startup.
1. **Host plugins** — your host `~/.claude/plugins/` directory is bind-mounted read-only at `~/.host-plugins` and merged into the session with highest precedence. Host plugin paths are rewritten to the container's filesystem automatically.

**One plugin does not follow that order: `context-mode`.** When `RIOTBOX_CONTEXT_MODE=1` and riotbox has registered a Context Mode tree of the image's own for the session, your host copy is skipped in favour of it, and riotbox prints nothing to say so. With the toggle off, on an image that carries no such tree, or where that registration did not go through, your host copy is used and enabled like any other plugin — see [Context Mode](#context-mode-opt-in) for why the image's copy has to win when it exists.

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

**Startup steps that can take a while** — copying plugins, installing one from a marketplace — report how long they have been running. A first start against a fresh session directory can spend minutes inside a single install, and the counter is what distinguishes that from a wedged session:

```text
  [plugins] Installing superpowers... 12s
  [plugins] Installing superpowers... done (14s)
```

The live counter only appears on a terminal, and only once a step has run for more than two seconds — quick steps look exactly as they always did. Piped or captured output gets the start and completion lines without the redraw, so logs stay readable. A step that fails prints `failed` with the elapsed time and replays the command's output; a failed plugin install is still not fatal to the session.

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
2. **`scripts/mount-projects.sh`** — per-launch mounts: the project bind, the session directory mount, the state-directory mounts (headroom, git-ai, overlay), and the per-agent contributions from `agents/<name>/manifest.sh::host_sync` (credentials nest, opencode config copy and auth, Pi config copy and auth, host plugins, host `~/.claude/{skills,agents,…}` copies, statusline script copy).

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
| `~/.local/share/riotbox-state/<session>/headroom/`  | `~/.headroom`                 | bind mount (`:z`), when `RIOTBOX_HEADROOM=1` |
| `~/.local/share/riotbox-state/<session>/git-ai/`    | `~/.git-ai`                   | bind mount (`:z`), when `RIOTBOX_GIT_AI` is unset, empty or `1` |
| `~/.local/share/riotbox-state/<session>/overlay/<name>/` | `/mnt/overlay[/<name>]`  | bind mount (`:z`), when `RIOTBOX_OVERLAY=1` (owned projects) |
| `~/.claude/.credentials.json`                       | `~/.claude/.credentials.json` | nested bind mount (`:z`, read-write) |
| `~/.claude.json`                                    | copied into session dir       | file copy                            |
| `~/.claude/{skills,agents,commands,output-styles}/` | copied into session dir       | file copy (symlinks dereferenced)    |
| `~/.claude/statusline-command.sh`                   | copied into session dir       | file copy (chmod +x enforced)        |
| `~/.claude/plugins/`                                | `~/.host-plugins`             | bind mount (read-only, `:z`)         |
| `~/.config/opencode/`                               | copied into state dir (`opencode-config/`), mounted at `~/.config/opencode` | file copy (symlinks dereferenced) |
| `~/.local/share/riotbox-state/<session>/opencode-data/` | `~/.local/share/opencode` | bind mount (`:z`)                    |
| `~/.local/share/opencode/auth.json`                 | same path in container        | bind mount (rw, when present)        |
| `~/.pi/agent/` allowlist (see [Pi config](#pi-config)) | copied into state dir (`pi-agent/`), mounted at `~/.pi/agent` | file copy (symlinks dereferenced) |
| `~/.pi/agent/{auth.json,mcp-auth.json}`             | same path in container        | bind mount (rw, when present)        |

RiotBox sessions are isolated from your host `~/.claude` — it is never mounted directly. `.credentials.json` is bind-mounted read-write so OAuth token refreshes write directly back to the host file (rotating refresh tokens require this). `.claude.json` is copied so each container gets a writable snapshot without host contention.

The headroom, git-ai and overlay mounts and the opencode and Pi copies come from the session's state directory, `~/.local/share/riotbox-state/<session>/`, not from the session directory — see [Session state directory](#session-state-directory), which also covers upgrading from an older release and going back.

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
# A scratch directory the session is meant to write back to
# .cache/mytool:rw
EOF
```

Each line is a path relative to `$HOME` (or absolute with `/`). Mounts are **read-only by default** — the container can read your live tokens but cannot modify the host files. This is the recommended way to provide private registry credentials at runtime, since auth tokens are [stripped from configs at build time](#other-design-choices) and never baked into image layers.

An entry can end in `:rw` to mount that one path read-write, or `:ro` to be explicit about the default:

| Entry | Result |
|-------|--------|
| `.npmrc`             | Read-only (the default) |
| `.npmrc:ro`          | Read-only, said out loud |
| `.cache/mytool:rw`   | Read-write |

Only lowercase `:rw` and `:ro` are recognised; anything else is read as part of the path, which then does not exist and is skipped. A typo can therefore drop a mount or leave it read-only — it can never widen one.

Weigh `:rw` before you use it. The agent in the container is autonomous, and a read-write entry is a direct hole to that path on your host, outside the git checkpoint that protects `/workspace`. Keep credentials and configs read-only; reach for `:rw` when a session is meant to produce something — a shared cache, an output directory. RiotBox prints one line to stderr at launch counting how many paths are mounted read-write, and `riotbox mounts` lists every mount with its podman flags — `:ro,z` for read-only, a bare `:z` for read-write.

Two guard rails apply:

- `RIOTBOX_READONLY=1` overrides every `:rw` entry back to read-only and lists the downgraded paths on stderr, so a read-only session is read-only everywhere.
- A `:rw` entry that resolves to your home directory, any ancestor of it, or `/` is refused with a warning. That covers `~/`, `.`, `./`, `..` and `/` — a writable mount of any of them would hand the agent the run of your host.

Entries in your file are **added to** the system ones in `/etc/riotbox/mounts.conf`, not merged with them. Listing a path the system file already mounts produces two mounts of the same container destination, which podman rejects outright — so a user entry cannot re-mount a system entry at a different mode.

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
| `XDG_DATA_HOME`   | `~/.local/share/riotbox/`, `~/.local/share/riotbox-state/` | Session dirs and git backups; per-session state mounted into the container |

## Session state directory

A session owns two directories on your host:

- `~/.local/share/riotbox/<session>/`, the **session directory**, mounted read-write at `~/.claude`. It holds Claude Code's files and `.projects`, the project list `riotbox session-list` shows.
- `~/.local/share/riotbox-state/<session>/`, the **state directory** (mode 0700). It holds every other directory RiotBox creates for the session to mount, one subdirectory each: `headroom/`, `git-ai/`, `overlay/<name>/`, `opencode-config/`, `opencode-data/` and `pi-agent/`. Host files mounted in place (`.credentials.json`, the opencode and Pi `auth.json` files, `~/.claude/plugins/`) and the [Context Mode ledger](#context-mode-opt-in) are not in it.

`<session>` is the session key `riotbox session-list` shows: a readable part, then `-` and 16 hex characters that are a hash of the project set's real paths. For one project the readable part is its path with each `/` turned into `-` (`/home/you/src/app` → `home-you-src-app-ccf7e90bf413702b`); for several it is the first project's directory name and how many more there are (`app-2more-…`). The hash makes the key unique to the set, so two projects whose paths differ only by a `-` where the other has a `/` (`/t/a-b/app` and `/t-a/b/app`) get separate sessions. A key that would exceed 255 bytes loses the front of its readable part. A project named twice, directly or through a symlink, is one project: mounted once and keyed as if named once.

Container names are not session keys and are not deterministic. Each launch's container is `riotbox-<project>-<8 random hex>`, or `riotbox-<first project>-<n>more-<hash>-<8 random hex>` for a set, so any number of sessions of one project or set can run side by side. Don't script against a name. Find a session's containers by its label instead: `podman ps --filter label=riotbox.session=<session>`.

The container can change anything in the session directory, including swapping an entry for a symlink to somewhere else on your host. It cannot reach the state directory itself, only the subdirectories that are mounted, so it cannot redirect a mount. The host-side steps of a launch — copying your Claude, opencode and Pi config, writing `.projects`, creating each mount and moving old data across — never write through a link a session planted; they replace it, with a warning where RiotBox did not expect one. Host commands that read what a session wrote (`riotbox session-list`, `riotbox overlays`, `riotbox overlay-accept`, `riotbox git-ai`, `riotbox tokscale`) treat it as untrusted; see [THREAT_MODEL § Session state directory](THREAT_MODEL.md#session-state-directory).

Launches of one project sync your config one at a time, which is why RiotBox needs `flock`. If a launch stops with `Error: <entry> in <dir> changed during sync (…); aborting.`, something modified that entry while the launch was replacing it — most likely a running session of the same project writing to its config. Nothing was written through a link; launch again.

**Removing sessions.** `riotbox session-remove` and `riotbox session-reset` delete the state directory together with the session directory, and `riotbox session-list` counts both in a session's size. That deletes the session's unaccepted overlay changes, Pi session history, headroom memory, opencode data and git-ai store, and neither command checks for pending overlay changes first: run `riotbox overlays` before you remove or reset a session. Both act only on directories RiotBox marked as sessions (they hold `.projects`, or their state directory holds the project record a launch writes, so a session launched by this release or later cannot hide by replacing its own `.projects`), and `session-remove` takes a key only as a single name, so `--all` leaves `backups/` and a rootless install's app tree alone; both share `~/.local/share/riotbox/` with the sessions.

**Avoid using a directory that contains your RiotBox data as a project**, such as `$HOME` or `~/.local`. The project is mounted read-write, and with it `~/.local/share/riotbox/`, `~/.local/share/riotbox-state/` and the Context Mode ledger: every session's files, the git backups and, on a rootless install, the RiotBox scripts that run on your host. RiotBox refuses only `/` as a project. For any other project that contains one of these directories, every launch and `riotbox mounts` print `WARN: project <dir> contains RiotBox data:` on stderr, list the directories it contains, and carry on. The check uses real paths, so a data directory you symlinked to another disk is caught when the project contains the link or its target. A project inside the data directory gets no warning.

### Upgrading from a release that kept state in the session directory

Before your first launch or `riotbox overlays` after upgrading, exit every session the older release started. This is required when the two directories are on different disks (see below), where a session still writing would race the copy.
Stop running opencode sessions of a project before its first launch after upgrading: that launch moves opencode's [Context Mode stores](#context-mode-opt-in) between two mounts by copying, which would race a session still writing them.

Older releases kept `.config-opencode`, `.local-share-opencode`, `.pi-agent`, `headroom`, `git-ai` and `overlay` inside the session directory. Each session moves them into its state directory once, at its first launch after the upgrade or at the first `riotbox overlays`, `riotbox overlay-diff`, `riotbox overlay-accept` or `riotbox overlay-reject` for it, and prints `Notice: moved <old> to <new>` per entry. After that RiotBox never looks at those old paths again, so nothing a session leaves there later is picked up. A later release that moves something else gets the same one-time move for that entry.

- An old entry that is a symlink or not a directory is removed with a warning, never followed.
- If both an old and a new copy exist, RiotBox warns, naming both, and leaves both; it never merges them. Every later launch repeats a one-line notice until you resolve it (see below). The session uses the new copy. Move anything you need out of the old one, then delete it.
- If a move fails, RiotBox does not retry it on its own. The warning says so, names `riotbox session-migrate`, and prints the `mv -T -- <old> <new>` that does the same move by hand, which is useful when the cause is not obvious. The old data stays where it was; the new directory may be empty, or partly copied if the move crossed disks, and later launches write to it. If it exists when you run the `mv`, move it aside first.
- After either of those, every launch and overlay command prints one line while the old directory still holds anything, with the `riotbox session-migrate` command for the session's projects: `Notice: legacy data is still at <old>; once the cause is fixed, run riotbox session-migrate <projects>.`, or, when the new directory holds data too, `Notice: two copies of legacy session data need resolving, <old> and <new>; run riotbox session-migrate <projects> to see how.` The notice stops, and RiotBox forgets the entry, once the old directory is gone or empty (podman leaves empty directories there, which hold nothing to recover).
- `riotbox session-migrate`, run from the project's directory (or with every project of a multi-project session, as for `overlay-diff`; run from one member, it prints the whole-set command), retries only those failed moves, once each, after you have fixed the cause. It refuses while any session of the project is running or starting, and when the container engine cannot say whether one is: exit every session of the project first, and do not launch one until it has finished, since a launch that starts at the same moment can slip past that check. The launch that left a move undone went on to create the new directory; while that is still empty, the retry moves the old one over it. A move that works is never tried again; one that fails again keeps its notice and prints the warning above. When both copies hold data it cannot merge them: it prints the `diff -rq <old> <new>` to compare them; delete one side (deleting the old one keeps the new one) and run it again. See the recovery steps below for reading the diff. It prints `Nothing to migrate.` when nothing is pending, and exits 1 while any move is still stranded or it refused. It moves whatever is in the old directory by then, which a running session could write to, so look at what it holds before you run it.
- For `opencode-config` (refreshed from your host at every launch), `pi-agent` once Pi has written to it, and `overlay` in overlay mode, the new directory is rarely empty by the time you retry, so a retry usually means resolving two copies with the `diff -rq` steps. That is expected, not a bug.
- RiotBox checks that the session directory is writable before it moves anything, so a session directory left owned by another user (`ERROR: … is not writable`, fixed with the `chown -R` it prints) stops the launch before any move is attempted.
- Until a session has been launched once, or had `riotbox overlays`, `overlay-diff`, `overlay-accept` or `overlay-reject` run for it (each runs the full move, not only `overlay`), `riotbox tokscale` and `riotbox git-ai` do not see its old opencode, Pi and git-ai data.

**When the two directories are on different filesystems** — for example because you replaced `~/.local/share/riotbox-state`, a session's directory in it, or `~/.local/share/riotbox` with a symlink to another disk — the move copies the whole tree and then deletes the old one, so it is not atomic. If it is interrupted, both copies exist and either may be incomplete: stopped while copying, the new copy is missing files (and may hold one cut short); stopped while deleting, the old one is. The next run warns that both exist and leaves them, and the session runs on the new copy, possibly incomplete. To recover, exit every session of that project and compare the two:

```sh
diff -rq <old> <new>
```

- Only `Only in <old>` lines (and perhaps one `differ` line): the new copy is incomplete. If no session has run on it since, replace it: `rm -rf <new> && mv -T <old> <new>`; otherwise merge as in the last case.
- No output, or only `Only in <new>` lines: the old copy is the incomplete one, or holds nothing the new one lacks. Delete it: `rm -rf <old>`.
- Both kinds, or `differ` lines you cannot explain (the session may have changed files in the new copy since): merge what the new copy lacks without overwriting anything, check the differing files by hand, then delete the old copy: `cp -a --update=none <old>/. <new>/` (with GNU coreutils older than 9.3, use `cp -a --no-clobber` instead).

### Upgrading from a release without hashed session keys

Releases before this one keyed a session by its project paths alone, so projects whose paths differ only by `-` for `/` shared one session. Each session moves to its new key once, at the first launch, `riotbox overlay-diff`, `overlay-accept`, `overlay-reject`, `riotbox session-migrate`, or `riotbox session-remove`/`session-reset` by path for its project set, and prints `Notice: moved <old> to <new>`. Until then `riotbox session-list` shows it under its old key, and `riotbox session-remove <old key>` removes it.

- A session is looked up under the old key of the projects as you named them and, if you named one twice, also under the old key of each named once, so `riotbox /a /a` finds the session `riotbox /a` made.
- A session moves only to the project set it belongs to: the set this release recorded for it, or, for a session an older release left (which has no record), the set its `.projects` names. The notice then ends with `(matched by its .projects: an older RiotBox left no record)`.
- If an old session belongs to another project set that had the same old key, it stays where it is and the launch warns, naming that set; the launched set starts a fresh session, and later launches no longer warn. `overlay-diff`, `overlay-reject` and `session-remove` by path create nothing, so they warn each time until the set has been launched. Launching the other set moves the old session to it.
- Nothing moves, with a warning, when the old state directory's `projects` record exists but cannot be read, or when a session without a record has a name ending in `-` and 16 hex characters (a name a current session can have, so its `.projects` is not trusted). A session whose `.projects` cannot be read or names nothing stays where it is with a one-line notice. Move such a session by hand if it is yours.
- The move refuses while a container that mounts the old session's directories read-write is running, including one the older release started (it set no `riotbox.session` label), and when the container engine cannot say whether one is: exit that session and launch again. Without the label, a container counts only when it mounts one of those directories or something inside them, so a toolbox or distrobox container that mounts `/` does not block it. A mount is matched both with and without resolving symlinks, so a directory swapped for a link after the container started still counts.
- If a move fails, the command stops with the reason; fix it and run the command again, which finishes the move.
- If both the old and the new directory exist, RiotBox warns, naming both, and uses the new one; it never merges them. Move what you need out of the old one, then delete it.
- `riotbox ctx-stats --by-project` groups by session key, so a project's runs from before the upgrade are listed under its old key.

### Going back to an older release

Exit every RiotBox session, then move each session's state back where an older release looks for it, and give the session the key an older release computes for its projects:

```sh
data="${XDG_DATA_HOME:-$HOME/.local/share}"
unrenamed=""
old_key() { # $1: a state dir's projects file, one path per line
	n="$(grep -c . "$1")"
	if [ "$n" -eq 1 ]; then
		sed 's|/|-|g; s|^-||' "$1"
		return
	fi
	first="$(LC_ALL=C sort "$1" | head -n 1)"
	first="$(basename "$first" | sed 's/[^a-zA-Z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
	hash="$(LC_ALL=C sort "$1" | sed 's|/|-|g; s|^-||' | paste -sd'+' - | tr -d '\n' | sha256sum | cut -c1-8)"
	echo "$first-$((n - 1))more-$hash"
}
for ST in "$data"/riotbox-state/*/; do
	[ -d "$ST" ] || continue
	ST="${ST%/}"
	S="$data/riotbox/${ST##*/}"
	if [ ! -d "$S" ]; then
		echo "NO SESSION DIR: $ST" >&2
		continue
	fi
	K=""
	if [ -f "$ST/projects" ]; then
		K="$(old_key "$ST/projects")"
	elif printf '%s\n' "${ST##*/}" | grep -qE -- '-[0-9a-f]{16}$'; then
		echo "NO RECORD: $ST" >&2
		continue
	fi
	for pair in opencode-config:.config-opencode opencode-data:.local-share-opencode \
	            pi-agent:.pi-agent headroom:headroom git-ai:git-ai overlay:overlay; do
		if [ -e "$ST/${pair%%:*}" ]; then
			mv -T "$ST/${pair%%:*}" "$S/${pair#*:}" || echo "NOT MOVED: $ST/${pair%%:*}" >&2
		fi
	done
	rm -f "$ST/.migrated" "$ST/.migrate.lock" "$ST/.sync.lock" "$ST/projects"
	rmdir "$ST" || echo "NOT EMPTY: $ST" >&2
	if [ -n "$K" ] && [ "$S" != "$data/riotbox/$K" ]; then
		if ! mv -T "$S" "$data/riotbox/$K"; then
			echo "NOT RENAMED: $S -> $K" >&2
			unrenamed="$unrenamed|$S|"
		fi
	fi
done
for S in "$data"/riotbox/*/; do
	S="${S%/}"
	case "$unrenamed" in *"|$S|"*) continue ;; esac
	if [ -f "$S/.projects" ] && [ ! -e "$data/riotbox-state/${S##*/}" ] &&
		printf '%s\n' "${S##*/}" | grep -qE -- '-[0-9a-f]{16}$'; then
		echo "NO RECORD: $S" >&2
	fi
done
rm -f "$data/riotbox-state/.migrate.lock"
```

Check the output. `mv -T` refuses to replace a non-empty directory, so `NOT MOVED` means the older path already holds data (an older release recreated it); compare the two and keep what you need. `NOT EMPTY` names a state directory with something left in it; empty it and remove it yourself, because an older release's `session-remove` does not know about `riotbox-state/`. `NO SESSION DIR` names a state directory whose session directory is already gone; nothing can move back into it, so look through it and delete it. `NO RECORD` names a session under a new key that no launch of this release has recorded its projects for (an overlay command moved it); launch it once with this release, exit, and run the script again. `NOT RENAMED` means a session directory already exists under the older key, which happens when two project sets shared it: the older release can only use one of them, so keep the one you want under that key. Running this release again moves everything forward again.

opencode's [Context Mode stores](#context-mode-opt-in) now live in `opencode-data/context-mode`, so they move back as `.local-share-opencode/context-mode`. An older release does not read them there: it kept them in its opencode config copy, which it rebuilds at every launch. Under an older release, opencode's Context Mode starts without that history; this release finds it again. Headroom memory does the same: this release keeps it in the state directory's `headroom/`, while an older release looks for it in `.headroom/` in the working directory, so under an older release it starts empty.

## Agent wrapper

Inside the container, each agent binary is shadowed by a single generic wrapper (`container/agent-wrapper.sh`) that injects the agent's autonomy flags (Claude Code: `--dangerously-skip-permissions`; opencode: `--auto`; Pi has no approval prompts to switch off, so nothing is injected) — this is safe here because the container **is** RiotBox. The agent can't escape to the host, and the mounted project directory has a git checkpoint for easy rollback.

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

`install-hooks` also sets **`notes.rewriteRef`**, which is what keeps [git-ai attribution](#ai-authorship-attribution-git-ai) alive through the rewrites this workflow depends on. git carries notes across `rebase` and `commit --amend` on its own, but only for the refs that key names — and it defaults to `refs/notes/commits`, leaving `refs/notes/ai` out. Rebase before reowning, as most people do, and every attribution note is orphaned before `reown` runs, where nothing can recover it. The value written is the glob:

```sh
git config --global notes.rewriteRef 'refs/notes/*'
```

Use the glob rather than `refs/notes/ai`: setting this key **replaces** git's default instead of adding to it, so naming only the git-ai ref would silently stop carrying your own `git notes` across rebases. An existing value that already covers `refs/notes/ai` is left alone; any other existing value is appended to, never overwritten. `reown` warns if it finds the key unset in a repo that has attribution notes.

## AI-authorship attribution (git-ai)

RiotBox ships [git-ai](https://usegitai.com/) and wires it into every session
automatically — unlike every other feature in this file, it is **on by default**:

| Variable | Effect |
|---|---|
| `RIOTBOX_GIT_AI` | AI-authorship attribution via git-ai (**on by default**; set `0` to disable) |

The check is a strict `1` comparison — enabled when unset or exactly `1`, and
**any other value disables it, including `RIOTBOX_GIT_AI=true`.** Every other
RiotBox flag uses the same strict compare; adding truthy parsing for one feature
would make git-ai the odd one out.

What lands where:

- Attribution lands in **`refs/notes/ai`** in your repo — not `refs/notes/git-ai`.
  Because the repo is bind-mounted, the notes reach the host with the rest of your
  commits; nothing extra has to be shared.
- **Notes are keyed by commit SHA, so every history rewrite has to carry them.**
  Two mechanisms cover the two rewrites in the usual workflow, and both are
  needed: `notes.rewriteRef` (set by [`riotbox install-hooks`](#reclaiming-authorship))
  covers your `rebase`, and `riotbox reown` remaps them itself across its
  `filter-repo` pass — filter-repo is neither `rebase` nor `amend`, so git's own
  machinery never fires for it. Without the config, a rebase orphans every note
  before `reown` can help.
- **What goes wrong beyond that.** `notes.rewriteRef` only carries notes across
  `rebase` and `commit --amend`. A cherry-pick, a squash, a `reset --soft` and
  recommit, or a rebase whose `--exec` amends each commit orphans the note
  anyway — as does any rewrite done where no git-ai daemon was running to
  re-derive it. **`riotbox repair-notes`** reattaches what content alone can
  still prove:

  ```sh
  riotbox repair-notes            # repair the current branch
  riotbox repair-notes --all      # every local branch and tag
  ```

  It matches in order: an identical tree, then an identical `git patch-id`,
  then per-file byte identity for a squash. A match that is not unique is
  refused and reported rather than guessed — it will not pick a side of a tie
  for you. No line range is ever recomputed: a file's entries transpose only
  where the blob is byte-identical on both sides of the rewrite, which is what
  keeps the recorded line numbers true, and files that churned contribute
  nothing and read `unknown`. It never overwrites a commit that already
  carries a note, because the in-session daemon re-derives notes from its own
  checkpoint store and does that better than any reconstruction here. It
  exits non-zero if any orphan is left unrepaired, so it is usable from a
  script. Progress for each pass goes to stderr and the plan goes to stdout,
  so redirecting stdout captures just the plan.
- `git ai stats`, `git ai blame`, `git ai log`, and `git ai show-prompt` need nothing
  but the repository — they read the notes straight out of it, so no store has to be
  shared. The **binary** is a different matter: RiotBox installs git-ai into the
  image, never onto the host, so these verbs run there only if you have installed
  git-ai on the host yourself. Until you do, the host answers every one of them with
  `git: 'ai' is not a git command` — which looks like missing attribution and is not.
- The daemon's own analytics store (`~/.git-ai` in-container, bind-mounted from
  `~/.local/share/riotbox-state/<session>/git-ai`) is **session-local**, so a bare
  `git ai usage` on the host reports on the host's own store and sees no session at
  all. **`riotbox git-ai`** closes that gap — it merges every session store plus
  your own `~/.git-ai` into one report:

  ```sh
  riotbox git-ai                 # merged summary, last 30 days
  riotbox git-ai --period 7d     # narrow the window
  riotbox git-ai --json          # the merged document
  riotbox git-ai --list          # which stores exist, and what can read them
  ```

  Each store is read through a temporary `HOME` holding a **copy**, never the
  store itself. Reading is not read-only for git-ai — it creates its metrics DB
  and caches a pricing catalogue under `$HOME/.git-ai` — so reading in place
  would make every report mutate the sessions it reports on, archived ones
  included. Reflink makes the copy near-free where the filesystem supports it,
  and only one store is copied at a time. Stores are still read where they live
  rather than registered anywhere, so a `riotbox session-reset` drops that
  session from the report.

  The read also runs with **no network** (`unshare -rn`, the same rule
  [`riotbox tokscale`](#commands) applies). git-ai fetches a models.dev pricing
  catalogue at runtime and offers no setting to stop it — see the note below.
  Every row already carries its cost priced at the time it was written, so
  removing the network leaves every reported figure identical.

  Each store records the git-ai release that wrote it in `.riotbox-version`, and
  that release is the correct reader for its SQLite files, so stores are grouped by
  version. A group with no matching binary is **named and skipped** rather than read
  with a mismatched one, as is a store with no stamp at all. Resolution order per
  group is `$GIT_AI_BIN`, a previously cached binary, a matching `git-ai` on `PATH`,
  then a one-time download verified against the release `SHA256SUMS`. Set
  `RIOTBOX_GIT_AI_NO_FETCH=1` to refuse that download.

  A session store and its stamp are written by the container, so the report does
  not trust them. A stamp that is not a regular file holding a plain version
  number (`1.7.5`, say) gets the store skipped with `has an invalid
  .riotbox-version`, and a store that contains a symlink is skipped with
  `contains a symlink`; the private copy is checked again after copying, in case
  a running session changed the store meanwhile. git-ai reads that copy with an
  empty `config.json`. The text report prints as `?` every character from a store
  that a terminal acts on or that makes text read differently from its bytes:
  C0 and C1 controls, DEL, bidirectional-text controls, zero-width characters
  and the Unicode line and paragraph separators.

  `git ai analyze` has no `--json`, so there is nothing machine-readable to merge; it
  stays a per-session command.
- RiotBox disables telemetry, version checks, auto-updates, and daemon log upload
  before the daemon ever starts. **That is not the same as offline.** git-ai also
  fetches a [models.dev](https://models.dev) pricing catalogue at runtime, into
  `~/.git-ai/internal/models_dev_pricing.json`, and exposes no config key to
  disable it — the four settings above do not cover it. Commit and token figures
  do not depend on it: each usage row stores the cost computed from the release's
  *embedded* price table when the row was written. `riotbox git-ai` reads with the
  network removed for this reason; a session container does not.

**Prompts are kept out of the note.** The `authorship/3.0.0` schema carries a
`prompts` object alongside `sessions`, and git-ai can populate it with your
prompt text — the transcript's `user_message` values. The note is the one git-ai
artifact that travels with the repository, so a prompt embedded there is
conversation content a later `git push` could publish without anyone deciding
to. RiotBox therefore pins both `prompt_storage` and `default_prompt_storage` to
`local`, the mode that keeps prompts out of the note. The second key matters
because it is the fallback upstream applies to repositories absent from
`include_prompts_in_repositories`; pinning only the first leaves that path on
whatever upstream ships.

Two honest limits. Upstream offers no `off` — the modes are `default`, `notes`
and `local` — so this keeps prompts out of the shared artifact rather than
stopping capture; prompts may still reach the session-local store, which is
disposable and wiped by `riotbox session-reset`. And
`exclude_prompts_in_repositories` is deliberately **not** used: upstream's help
describes other keys as globs and this one only as "Repos", so there is no
evidence a `*` entry matches anything, and a setting that looks protective while
matching nothing is worse than none.

Independently of all this, `refs/notes/*` is **not pushed by default** — `git
push` ignores it absent explicit configuration — so notes stay in your clone
unless you push them deliberately.

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
- Cross-session memory is on. Memory and the rest of headroom's state
  persist per project set in the session's state directory
  (`~/.local/share/riotbox-state/<session>/headroom`) and are shared by all
  agents of that project set. RiotBox sets `HEADROOM_MEMORY_DB_PATH` because
  headroom would otherwise keep its memory in `.headroom/` in the working
  directory.
- Headroom writes nothing into your project. RiotBox starts `headroom proxy`
  itself and points the agent at it, instead of using `headroom wrap`,
  because `wrap claude` writes `.claude/settings.local.json` and lock, marker
  and hook entries into the working directory.
- Failure learning (headroom's `--learn`) is off. It writes what it learns
  into the project (`CLAUDE.local.md` for Claude, `AGENTS.md` for opencode),
  and headroom has no setting to send it anywhere else.
- Model inference is fully offline — the compression models are baked into
  the image at build time.
- Wired for `--agent=claude` and `--agent=opencode`. Other agents, including
  `--agent=pi` (headroom has no Pi support), print a warning and run
  uncompressed.
- For Claude, RiotBox exports `ANTHROPIC_BASE_URL` (or, on Vertex or Azure AI
  Foundry, `ANTHROPIC_VERTEX_BASE_URL` / `ANTHROPIC_FOUNDRY_BASE_URL`) for the
  launch, keeps on-demand tool loading on with `ENABLE_TOOL_SEARCH=true`
  unless you set it, and registers headroom's MCP retrieve tool at user
  scope in the session's `~/.claude.json`. The same two values go in as
  `--settings` for background sessions (`/bg`, `claude --bg`): Claude Code's
  daemon often runs those in a worker that does not inherit the launch's
  environment. If you pass your own `--settings`, RiotBox merges the routing
  into its `env` (your keys win) and hands claude the result as a private
  file in the container's `/tmp`, so the settings' secrets stay out of the
  process list. If it cannot read that file or JSON, claude
  gets it unchanged and a notice says background sessions of that launch
  reach the API directly. A value your user, project or local
  `settings.json` sets in `env` is left to that file, as it was before:
  with `ANTHROPIC_BASE_URL` there, for example, the launch goes to your
  gateway rather than through headroom.
- For opencode, RiotBox starts the proxy and then hands off to
  `headroom wrap opencode --no-proxy`, which routes the providers through it
  via `OPENCODE_CONFIG_CONTENT` and writes nothing into the project.
- If the proxy does not start, RiotBox warns and runs the agent uncompressed.
  If something other than headroom already listens on the proxy port
  (`HEADROOM_PORT`, default 8787 — `wrangler dev` uses it too), RiotBox
  leaves it alone and starts the proxy on the next free port.
- If the proxy dies mid-session, the agent gets connection errors until you
  relaunch it.
- Each container tracks the proxies it started in its own `/tmp`. If you
  share the host's `/tmp` between containers (for example with
  `RIOTBOX_EXTRA_ARGS`), they stop recognising their own proxies and each
  launch may start another one.
- If you set a provider `baseURL` yourself in `opencode.json(c)`, headroom
  routes that provider through the proxy anyway and riotbox prints a notice
  naming it. Your endpoint still receives the traffic — the proxy forwards
  upstream — but the request goes through the proxy first.
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

### Headroom leftovers from older releases

Older releases let headroom write into a single-project checkout (in overlay
mode, into the overlay). Nothing current writes these; remove what you find:

- `.headroom/`, headroom's memory. The first headroom launch of each session
  prints, once, the commands to delete it, to copy it into the state
  directory (after exiting every session), or, if it was committed, to
  untrack it and add it to `.gitignore`. RiotBox never moves or deletes it
  itself, and `overlay-accept` never copies one from the overlay into the
  project.
- `.claude/settings.local.json` entries from `headroom wrap claude`: a
  `SessionStart` hook whose command mentions `headroom-wrap-selfheal` (it
  runs `/home/llm/.local/bin/headroom wrap selfheal`, so a `claude` run on the
  host in that project tries to run it at startup), and, after a session was
  killed, `env.ANTHROPIC_BASE_URL` pointing at `127.0.0.1` and
  `env.ENABLE_TOOL_SEARCH`. Delete those entries, or the whole file if it
  holds nothing else.
- `.claude/.headroom_wrap_settings.lock`, `.claude/.headroom_wrap_marker.json`
  and `.claude/.headroom_wrap_owners.json`: delete them.
- A headroom block (between headroom's marker comments) in `CLAUDE.local.md`
  or `AGENTS.md`, written by failure learning: delete the block, or the file
  if headroom created it.

## Egress proxy

Opt-in. By default a session has the same network access as any rootless
podman container. With `RIOTBOX_EGRESS=1` it gets its own
[Envoy](https://www.envoyproxy.io/) proxy, and that proxy is its **only** way
out: the agent can open HTTPS connections to the hosts on an allowlist and to
nothing else.

```bash
RIOTBOX_EGRESS=1 riotbox run "<task>"
# or persist it in ~/.config/riotbox/config:
: "${RIOTBOX_EGRESS:=1}"
```

`RIOTBOX_EGRESS` must be unset, empty, `0` or `1`; any other value (such as
`true`) stops the launch with an error rather than running without the proxy.

The first egress launch pulls the Envoy image (pinned by digest;
`RIOTBOX_EGRESS_IMAGE` overrides it). Inside the session, `HTTPS_PROXY` and
`HTTP_PROXY` (and their lowercase forms) point at the proxy. If you forward
your own `HTTP_PROXY`, `HTTPS_PROXY` or `NO_PROXY` by name, the session gets
egress's value instead. When the proxy injects keys (see
[API keys](#api-keys)), the same goes for `NODE_EXTRA_CA_CERTS`,
`SSL_CERT_FILE`, `CURL_CA_BUNDLE` and `REQUESTS_CA_BUNDLE` (see
[Known limits](#known-limits)).

### What the launch refuses

Egress mode needs podman: the agent and its proxy run on podman networks. The
launch stops, before creating anything, with a message naming the conflict
when egress mode is combined with:

- docker;
- `RIOTBOX_SOCKET=1` (with the host's podman socket the agent could start a
  container that bypasses the proxy);
- `RIOTBOX_NETWORK=none`;
- `RIOTBOX_EXTRA_ARGS` containing `--privileged`, `--cap-add`, `--network`,
  `--net`, `--pod`, `--userns`, `--rootfs`, `--volumes-from` or
  `--init-path`, in any
  spelling (`--flag value` or `--flag=value`);
- `RIOTBOX_EXTRA_ARGS` mounts (`-v`, `--volume`, `--mount`) whose host source
  is a Unix socket, or a directory (or a path that does not exist yet) that
  is, lies under, or contains your runtime directory (`/run/user/<uid>`, and
  `$XDG_RUNTIME_DIR` when set to an absolute path), where the rootless podman
  socket lives. A regular file there, such as a credential file a secret
  manager keeps under `$XDG_RUNTIME_DIR`, is allowed. A `--mount` with `volume-opt=`,
  `type=glob` or a quoted value is refused because it cannot be checked;
- the same mount check for the mounts RiotBox builds itself: `mounts.conf`
  entries, project directories and credential files (`RIOTBOX_CREDFILE_VARS`).
  The error names which one. A `mounts.conf` entry such as
  `/run/user/1000/podman/podman.sock` or `/run/user/1000/bus` stops the launch
  rather than being dropped; remove it, or run without `RIOTBOX_EGRESS=1`.

It also stops when any of those mounts is a file inside the proxy's state
directory, `${XDG_DATA_HOME:-~/.local/share}/riotbox-egress/`, or a `:O`
mount whose `upperdir=` or `workdir=` is in or above it.

Every session's allowlist lives in that directory, and the agent runs as
you, so a mount that reaches it (`riotbox ~`, a `mounts.conf` entry for
`~/.local/share`) would let the agent rewrite its own allowlist. The launch
mounts an empty directory over it wherever such a mount puts it in the
container (`/workspace/.local/share/riotbox-egress` for `riotbox ~`), so the
agent sees nothing there and cannot write to it. `riotbox ~` keeps working.
With `RIOTBOX_NESTED=1`, a project or mount that contains the egress state
is refused: nested mode lets the agent remove that mask. Mount a narrower
directory, or drop nested or egress mode.

It also stops when the agent's manifest has no `egress_hosts` verb (see
[docs/dev/agent-contract.md](docs/dev/agent-contract.md#agent_name_egress_hosts)):
a proxy that blocks the agent's own API is no use. Nested mode
(`RIOTBOX_NESTED=1`) is allowed.

When the proxy injects API keys (see [API keys](#api-keys)), the launch also
stops, once the proxy is up (it then removes it), when `RIOTBOX_EXTRA_ARGS`
would put a value of its own in an injected variable: `-e`/`--env` setting
one with `NAME=…`, any `--env-file`, or any `--secret` with `type=env`. So it
does for a `--pid` other than `private` (`--pid=host`, `--pid container:…`,
`--pid ns:…`, either spelling): the launcher keeps the real keys in its own
environment for the session, and an agent sharing the host's PID namespace
could read them there.

### What is allowed

Unless strict mode is on, the allowlist is the union of:

- `@registries`, the package registries: the groups `@npm`, `@pypi`, `@go`,
  `@crates` and `@github` (see [Groups](#groups)).
- `@agent`: the running agent's own API hosts, and only that agent's.
  Claude: `api.anthropic.com`, `claude.ai`, `platform.claude.com`,
  `console.anthropic.com`, and `mcp-proxy.anthropic.com`, which carries the
  connectors you added on claude.ai (Gmail, Drive and the like) and so lets
  the agent use those accounts; put `-mcp-proxy.anthropic.com` in your
  `egress.conf` to keep them out. opencode and Pi: the API host of each provider
  whose key they pass through (opencode also `models.dev`). Vertex and
  Bedrock hosts are not included; add them yourself if you use them.
- What `/etc/riotbox/egress.conf` (system) and
  `${XDG_CONFIG_HOME:-~/.config}/riotbox/egress.conf` (yours) allow. Both
  are read, not one instead of the other. `./install.sh` seeds yours, and
  the rpm and deb install the system one, from a commented template that
  explains the format; in short:

  ```ini
  strict                    # optional, before any section: only what the files list
  [group mirrors]           # your own group: host, host:port or *.domain lines
  mirror.corp.example:8443
  [allow]                   # lines before any section are [allow] lines too
  example.com               # port 443
  example.com:8443          # that port only
  *.example.com             # any subdomain at any depth, not example.com itself
  @agent                    # the agent's own API hosts (needed under strict)
  @containers               # every host of a group
  @mirrors
  -pypi.org                 # remove an entry another line, file or group allows
  -@npm                     # remove every host of a group
  ```

A removal (`-entry`, `-@group`) in either file wins over every addition,
including the hosts a group adds, and it must match the entry exactly:
`-*.example.com` does not remove `a.example.com`. Everything not on the list
is refused with `403`, and so is all plain HTTP. Only names are accepted,
never IP addresses. A bad line stops the launch, and every
`riotbox egress` command that reads the file, with
`<file>:<line>: <reason>`, for example: an invalid entry or group name, an
unknown section or setting, a `strict` after the first section, an `@name`
that no file or built-in defines, an empty group, a group defined twice in
one file, a `-` or `@` line in a group, or `[group agent]`.

#### Strict mode

`strict` (or `strict = on`) before the first section of an `egress.conf`
drops the implicit `@registries` and `@agent`: the session reaches only
what the files list. List `@agent` yourself, or the agent cannot reach its
own API. When strict mode leaves out any of the agent's hosts, the launch
warns, without refusing, after the proxy is up:

```text
WARNING: strict mode does not allow the agent's own API hosts (api.anthropic.com, claude.ai, console.anthropic.com, mcp-proxy.anthropic.com, platform.claude.com); add @agent
```

`strict = off` in your file turns off a `strict` in the system file. A
session's own setting (`riotbox egress strict`, below) beats yours, which
beats the system file's; with none of them, strict mode is off.

#### Groups

`riotbox egress groups` lists every group, its hosts, and where its
definition comes from. A `[group NAME]` in either file replaces the
built-in group of that name (yours beats the system file's), and every
`@NAME` in either file uses the result. `@registries` follows too, so a
`[group pypi]` pointing at your mirror replaces pypi in the default
allowlist. A group you define lists hosts, not other groups. `@agent` is
reserved. The built-in groups, and the OS groups (from `os/<ID>/`, source
`os` in `riotbox egress groups`):

| Group | Hosts |
|---|---|
| `@npm` | registry.npmjs.org |
| `@pypi` | pypi.org, files.pythonhosted.org |
| `@go` | proxy.golang.org, sum.golang.org, vuln.go.dev |
| `@crates` | index.crates.io, static.crates.io |
| `@github` | github.com, api.github.com, codeload.github.com, `*.githubusercontent.com` |
| `@registries` | `@npm`, `@pypi`, `@go`, `@crates`, `@github` |
| `@agent` | the running agent's API hosts (above) |
| `@search` | www.google.com, www.bing.com, duckduckgo.com, search.brave.com, api.search.brave.com |
| `@docs` | developer.mozilla.org, docs.python.org, go.dev, pkg.go.dev, docs.github.com, docs.rs, stackoverflow.com, `*.stackexchange.com`, `*.readthedocs.io` |
| `@wikipedia` | `*.wikipedia.org`, `*.wikimedia.org` |
| `@rubygems` | rubygems.org |
| `@maven` | repo.maven.apache.org, repo1.maven.org |
| `@gitlab` | gitlab.com, registry.gitlab.com |
| `@containers` | registry-1.docker.io, auth.docker.io, production.cloudfront.docker.com, quay.io, `*.quay.io`, ghcr.io, pkg-containers.githubusercontent.com |
| `@forges` | `@github`, `@gitlab`, bitbucket.org, api.bitbucket.org, codeberg.org, gitea.com, git.sr.ht, hg.sr.ht, dev.azure.com, git.launchpad.net, code.launchpad.net |
| `@centos` (os) | mirror.stream.centos.org, dl.fedoraproject.org (EPEL) |
| `@fedora` (os) | dl.fedoraproject.org |
| `@rhel` (os) | cdn-ubi.redhat.com, cdn.redhat.com |
| `@debian` (os) | deb.debian.org, security.debian.org |
| `@ubuntu` (os) | archive.ubuntu.com, security.ubuntu.com, ports.ubuntu.com |
| `@arch` (os) | geo.mirror.pkgbuild.com, fastly.mirror.pkgbuild.com |
| `@os` | every OS group above in one name (opt-in; empty when no OS plugin is installed) |
| `@huggingface` | huggingface.co, `*.hf.co` |

Built-in groups can change between releases as vendors move their hosts;
if you need a fixed set, define your own group. `@search` and `@docs` let
the agent send data out through search queries and Q&A sites: allow them
only when you accept that. `@forges` is not part of `@registries`: allow it
to clone from or push to those forges over HTTPS.

#### Package managers in a session

Stock package-manager configs do not work behind the proxy: dnf's mirror
lists hand out third-party mirrors, many over plain HTTP, and Debian and
Ubuntu fetch over plain HTTP. So when an egress session starts, RiotBox
points the distro's package manager at that distro's own HTTPS mirrors, the
hosts of its OS group. Allow the group, and `sudo dnf install` works:

```bash
riotbox egress allow @centos     # the RiotBox image: CentOS Stream 10, with CRB and EPEL
```

(or uncomment `@centos` in your `egress.conf`). `@fedora`, `@rhel`,
`@debian`, `@ubuntu` and `@arch` do the same for those distros, and `@os`
allows every distro's mirrors at once (the union of the OS groups; opt-in,
like each of them, and not part of `@registries`; with no OS plugin installed
it is empty and allows nothing). Debian and Ubuntu also need
`ca-certificates` in the image, or the rewrite is refused and apt keeps its
plain-HTTP sources. If a rewrite fails, the session still
starts and prints a `WARNING: egress:` line. A distro with no plugin
(Rocky, Alma, Mint) keeps its stock mirrors, which the proxy may refuse.
Outside egress mode nothing is changed. How plugins work and how to add one:
[docs/dev/os-contract.md](docs/dev/os-contract.md).
`@centos` is no longer built in: a session saves the OS groups when it
starts, so restart any egress session started before this release, or
`riotbox egress reload` fails for it while its own allowlist or your
`egress.conf` names `@centos`.

### Changing a running session

`egress.conf` is read when a session starts. To change a session without
restarting it:

```bash
riotbox egress list                     # running sessions: start, owner, projects, log, strict, injected keys, allowlist
riotbox egress groups                   # every group, its hosts and where it is defined
riotbox egress allow api.example.com    # allowed now
riotbox egress allow @pypi              # every host of a group
riotbox egress deny api.example.com     # new connections refused; open ones stay up
riotbox egress allow --save x.example   # ...and record it in your egress.conf
riotbox egress strict --enable          # only what egress.conf lists, from now on
riotbox egress strict --disable         # off for this session, whatever egress.conf says
riotbox egress strict --clear           # back to what egress.conf says
riotbox egress reload                   # re-read egress.conf into every running session
```

An `allow` or `deny` lasts until the session ends and wins over the conf
files, so it can re-allow something a conf file removes. Within a session
the latest `allow` or `deny` of a host wins: `allow @pypi` then
`deny pypi.org` leaves `files.pythonhosted.org` allowed and `pypi.org`
refused. A group is kept as its name, so `reload` picks up a changed group.
If you delete a `[group NAME]` the session allowed or denied, every
`reload`, `allow`, `deny` and `strict` for that session fails until you
drop it: `riotbox egress deny --session <name> @NAME` removes the session's
line for it and applies the rest (the error says so; `--save` refuses).
`--save` also writes the entry or `@group` to your `egress.conf`, at the
end of its last `[allow]` section (a new `[allow]` section at the end of a
file that has sections but none of them `[allow]`; a bare last line in a
file without sections), replacing any earlier line for it, so a saved allow undoes a
saved deny in your `egress.conf` (a removal in the system `egress.conf`
still wins). `strict --save` writes `strict = on` or `strict = off` near the
top of your `egress.conf`, replacing one already there, and
`strict --clear --save` removes it. `strict --enable`, and `strict --clear`
when a conf file is strict, print the warning above when the agent's hosts
are left out. `deny` of a host that a wildcard still matches says which
wildcard. Connections already open are never cut by `allow`, `deny`,
`strict` or `reload`.

With more than one session running, `allow` and `deny` refuse and list
them; name one with `--session <name>`. The launch prints the name:

```text
egress: session riotbox-proj-1a2b3c4d; change what it may reach with: riotbox egress allow --session riotbox-proj-1a2b3c4d <entry>
```

`riotbox egress list` shows it too, with what tells sessions of one project
apart: when each started, the PID of the launch that owns it, and its
project dirs (`unknown` for what was not recorded, such as the projects of
a session an older release started):

```text
riotbox-proj-1a2b3c4d
  started: 2026-10-24 14:03:11 CEST
  owner:   PID 41235
  project: /home/me/proj
  log:     /home/me/.local/share/riotbox-egress/riotbox-proj-1a2b3c4d/log/access.log
  strict:  off (default)
  inject:  ANTHROPIC_API_KEY → api.anthropic.com
  allow:   api.anthropic.com
```

`strict:` says whether strict mode is on and where that comes from:
`session`, `user conf`, `system conf` or `default` (`unknown` for a session
an older release started). `inject:` names each key the proxy injects and
its host, never its value (see [API keys](#api-keys)). A project or
injection record that cannot be read shows as `project: unreadable` or
`inject:  unreadable`, with the reason on stderr.

`reload` without `--session` reloads every running session.
`riotbox egress --help` has the details; a command with wrong arguments
prints an `ERROR:` line saying what is wrong, usually followed by the
usage, and exits 2.

### Finding what was blocked

Each request is logged as a line of JSON in
`${XDG_DATA_HOME:-~/.local/share}/riotbox-egress/<session>/log/access.log`.
When a session ends, RiotBox removes its proxy and prints
`egress: N denied request(s), see <log>` if anything was refused. A later
egress launch deletes a session's logs once they have gone 7 days unused.

If RiotBox itself is killed, its proxy is left behind until the next
egress launch removes it; that cleanup never touches a session that is
still running. Pressing Ctrl-C while the proxy is being removed does not
interrupt the removal.

A refused request's `403` carries an `x-riotbox-egress: denied <host[:port]>`
header and a short text body. For HTTPS it names the session and the
`riotbox egress allow` command to run, and asks the agent to stop and ask
you; for plain HTTP it says to use HTTPS, since allowing the host will not
help. The host in that text is whatever the agent asked for: check it
before you allow it. Most clients drop the body for HTTPS (curl prints only
`CONNECT tunnel failed, response 403`), so the agent's system prompt
(Claude, opencode and Pi) also says that such a failure is the allowlist,
not the network, and to ask you to allow the host instead of looking for a
way around it.

### API keys

In egress mode an API key RiotBox knows does not enter the container. There
is nothing to turn on: export the key as you do today. The agent sees the
placeholder `riotbox-egress-placeholder` in its variable, and the session's
proxy puts the real key on each request to that provider's API host,
replacing whatever the agent sent:

| Variable | Host |
|---|---|
| `ANTHROPIC_API_KEY` | `api.anthropic.com` |
| `OPENAI_API_KEY` | `api.openai.com` |
| `OPENROUTER_API_KEY` | `openrouter.ai` |
| `GEMINI_API_KEY` | `generativelanguage.googleapis.com` |
| `GROQ_API_KEY` | `api.groq.com` |
| `MISTRAL_API_KEY` | `api.mistral.ai` |
| `DEEPSEEK_API_KEY` | `api.deepseek.com` |
| `XAI_API_KEY` | `api.x.ai` |

The agent can still *use* a key through the proxy (and spend its quota), but
it cannot read it or copy it out. A host must still be allowed: denying it
refuses it, key or not. `riotbox egress list` names each injected variable
and its host.

To do this the proxy terminates TLS for those hosts, and only those, with
certificates from a CA made for the session: valid for 30 days, able to
vouch for nothing but those hosts, and whose private key is never written
anywhere. The CA's certificate is at `/run/riotbox-egress/ca.crt` in the
session. `NODE_EXTRA_CA_CERTS` makes Claude Code, opencode and Pi trust
it, and `SSL_CERT_FILE`, `CURL_CA_BUNDLE` and `REQUESTS_CA_BUNDLE` point
curl and Python, headroom included, at the image's CA bundle plus the
session CA. git is
not pointed at it; it does not need it. Every other host stays a tunnel the
proxy cannot read.

A key still enters the container, and the launch names it, when no row
above knows it (any other forwarded variable whose name ends in `KEY`,
`TOKEN`, `SECRET` or `PASSWORD`), when its base URL (`ANTHROPIC_BASE_URL`,
`OPENAI_BASE_URL`) is set to anything but `https://<the provider's host>`,
or when it is not visible ASCII:

```text
egress: these keys still enter the container: ANTHROPIC_AUTH_TOKEN (not injectable: not in the provider table)
```

That line covers the variables RiotBox forwards. One you add yourself
with a bare `-e NAME` in `RIOTBOX_EXTRA_ARGS` also enters the container, but
is not named.

With `RIOTBOX_HEADROOM=1`, an `ANTHROPIC_BASE_URL` on `localhost` or a
loopback address does not count as elsewhere: headroom replaces it in the
session and sends requests on to Anthropic through the proxy. A base URL set
in an agent's own config file, or with `-e` in `RIOTBOX_EXTRA_ARGS` (not in
the environment RiotBox forwards), is not seen at launch: the key is still
injected for the provider's host, and the agent sends the placeholder to the
other URL and fails to authenticate there.
OAuth logins (Claude Code's `/login`, opencode's and Pi's `auth.json`) are
unchanged and still live in the container.

Keys are read once, when the session starts: `riotbox egress reload` does
not re-read them, so to rotate a key, start a new session. The session's
certificates expire after 30 days, so a session running longer loses its
provider APIs until it is restarted. Claude Code asks once, in an
interactive session, whether to use the API key it finds in its
environment: that is the placeholder; approve it.

The keys are kept, for the proxy alone, in
`<runtime>/riotbox-egress/<session>/secrets/` (mode 0700, files 0600), where
`<runtime>` is `$XDG_RUNTIME_DIR`, or else `/run/user/<uid>`: whichever is
first a directory you own, mode 0700, on tmpfs. So they are kept on tmpfs
and never written to persistent disk, unless the system swaps them out (use encrypted swap), and the egress launch refuses any agent mount of that
directory or of one holding it, so a broad project such as `riotbox ~`
cannot expose them. It is deleted
when the session ends; if RiotBox is killed, the next egress launch deletes
it once the session has been idle for an hour, and tmpfs empties at logout
or reboot anyway. The proxy runs with core dumps off, so a crash does not
write them out either.

A login session provides that directory. Without one (for example under
`su`, `sudo -i` or a cron job), a launch with a key to inject stops before
creating anything:

```text
riotbox-core: egress: credential injection needs a private tmpfs runtime dir ($XDG_RUNTIME_DIR or /run/user/<uid>) so keys never reach disk; none found — unset the keys to run without injection, or start the session from a login session (…why each was refused…)
```

With no key to inject, egress mode needs no runtime directory.

The launcher itself keeps the real keys in its environment for the session:
it is a host process, and the agent cannot see it (see the `--pid` refusal
above).

### Known limits

- Tools that ignore `HTTPS_PROXY` get no network at all.
- The session has no DNS: no name resolves inside it except the proxy's,
  so `nslookup`, `dig` and anything else that resolves a name itself fail.
  The proxy resolves the hosts it allows. Containers that nested podman
  (`RIOTBOX_NESTED=1`) starts inherit no working resolver either: they can
  use the proxy, but cannot resolve names themselves.
- `sudo dnf install` works once `@centos` is allowed (the template has it,
  commented out; see [Package managers in a session](#package-managers-in-a-session)):
  the image's sudoers keeps the proxy variables across `sudo`. An image
  built before this release has neither that nor the OS rewrite, so dnf
  keeps its stock mirrors, which the proxy refuses, and nothing warns:
  rebuild it.
- dnf in a session no longer checks repository metadata against its mirror
  list's checksum; packages are still GPG-checked, and fetched over TLS from
  the distro's own mirror.
- Git over SSH does not work; use HTTPS remotes.
- Nested podman (`RIOTBOX_NESTED=1`) needs `@containers` (or your
  registries) allowed; the template has it, commented out.
- An allowed name can resolve to a private or loopback address; the proxy
  checks names, not addresses. The agent can then reach whatever the proxy's
  network can: your LAN, the host itself, link-local metadata addresses.
  Keep wildcards narrow.
- The proxy does not look inside HTTPS, except to the injected keys' hosts,
  so data can still be sent to any allowed host.
- Credentials other than the injected API keys (see [API keys](#api-keys))
  still enter the agent container as they do without egress mode.
- When the proxy injects keys, a CA of your own forwarded through
  `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE` or
  `REQUESTS_CA_BUNDLE` (a corporate or TLS-inspection CA) is replaced by the
  session's, so it is not trusted: networks that inspect TLS are not
  supported in that mode. Without injected keys those variables reach the
  session unchanged.
- A project that holds the egress state root
  (`${XDG_DATA_HOME:-~/.local/share}/riotbox-egress`, for example
  `riotbox ~`) gets an empty mask over that root (see
  [Egress proxy](#egress-proxy)), so the agent cannot rewrite a session's
  allowlist through it. The injected keys are not under that root in any
  case: they are on the runtime tmpfs.
- `RIOTBOX_EXTRA_ARGS` is your own configuration and is trusted. The checks
  above catch mistakes; they are not a sandbox for it. Two gaps are known: a
  mounted directory that happens to contain a Unix socket elsewhere than
  your runtime directory, and a named volume you created earlier with a bind
  option.

How it works: [docs/dev/egress.md](docs/dev/egress.md).

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

**All three agents are supported, and the paths have little in common.**
Upstream reaches Claude Code through hooks and an MCP server, opencode
through a TypeScript plugin that runs inside the agent process, and Pi through
a Pi package whose extension runs inside Pi and bridges to the MCP server;
there is no shared shape to abstract over. On Claude the image stages
upstream's own marketplace plugin and the session registers it — riotbox
writes no Claude wiring at all. On opencode riotbox generates a plugin file,
from `agents/opencode/context-mode.sh`. On Pi riotbox adds the installed
`context-mode` package to `settings.json` `packages`, from
`agents/pi/context-mode.sh`. `container/context-mode-setup.sh` drives the
per-session part without naming any agent — see
[`docs/dev/agent-contract.md`](docs/dev/agent-contract.md#optional-verbs-context-mode)
for the contract. An agent with no support runs with the feature off after a
warning naming it.

| | `--agent=claude` | `--agent=opencode` | `--agent=pi` |
|---|---|---|---|
| Where the support comes from | upstream's marketplace plugin, staged in the image at a pinned ref and registered against the session in place | one generated plugin file, `~/.config/opencode/plugins/riotbox-context-mode.js` | upstream's Pi package: the installed `context-mode` package root, listed in `~/.pi/agent/settings.json` `packages` |
| Where the code runs | a short-lived hook process per matched tool call, plus an MCP child process | in-process, inside opencode's own embedded bun | in-process, inside Pi, plus an MCP child process the extension starts on the first prompt |
| How the `ctx_*` tools arrive | over MCP, named `mcp__plugin_context-mode_context-mode__ctx_*` | eleven native opencode tools the plugin registers directly — no MCP server at all | native Pi tools the extension registers and forwards to that MCP child |
| Where interception happens | a `PreToolUse` matcher in the plugin's `hooks/hooks.json` | `tool.execute.before`, enforced in-process | Pi's `tool_call` event, enforced in-process; at context-mode v1.0.169 only `bash` calls are routed |
| Slash commands | `/context-mode:*`, one per bundled skill | none — opencode has no equivalent surface | `/ctx-stats` and `/ctx-doctor` |
| Store | `~/.claude/context-mode` | `~/.local/share/opencode/context-mode` | `~/.pi/agent/context-mode` |

What changes when enabled:

- `WebFetch` is redirected to Context Mode's own fetch tools, which store the
  response and return a summary. Large `Bash` output gets a routing suggestion
  rather than a hard redirect, so savings there depend on the model taking it.
- **`WebSearch` is not intercepted on Claude Code.** At the pinned version it
  appears in no alternative of the `PreToolUse` matcher in the plugin's
  `hooks/hooks.json`, and a `PreToolUse` hook only runs for the tools its
  matcher names — so search results still land in the transcript in full.
  **opencode has no matcher at all**: routing is decided in-process inside
  `tool.execute.before`. On both agents the intercepted set is upstream's
  decision. On Claude a change to it fails the image build — the staged
  `hooks.json` is compared against `container/context-mode-hooks-expected.json`,
  so a bump that drops a tool has to be looked at rather than discovered in a
  session. On opencode there is no such check, and a version bump can change what
  routes without riotbox noticing until a session does.
- **On Claude Code you get `/context-mode:*` slash commands and Context Mode's
  bundled skills.** Both come from the plugin and neither is in the npm package,
  so a riotbox session used to have the hooks and the MCP tools and nothing
  else. There is no `commands/` directory upstream — the commands *are* the eight
  skills under `skills/`, which `.claude-plugin/plugin.json` declares with
  `"skills": "./skills/"`. `/context-mode:ctx-stats`, `/context-mode:ctx-search`,
  `/context-mode:ctx-doctor` and the rest surface the same operations as the
  `ctx_*` MCP tools without having to ask the model to call one. Type `/` in a
  Claude session to list them. opencode has no equivalent: its `ctx_*` tools are
  registered in-process and there is no skill or command surface to attach.
- **`/context-mode:ctx-upgrade`, `context-mode upgrade` and the `ctx_upgrade`
  tool do not work inside riotbox, by design.** The slash command is listed with
  the rest because the plugin ships it; it simply cannot do its job here. All
  three git-clone upstream's `main` over the installed tree, and the plugin is
  pinned to the image at a version the build asserted its contracts against.
  `RIOTBOX_NETWORK=none` forbids the fetch outright, and the staged tree carries
  an interpreter rewrite and an offline dependency install that a fresh clone
  would undo — leaving every hook to spend 120 seconds in `npm install` and
  fail anyway. The version is a property of the image, so moving it is a
  maintainer change plus a `riotbox rebuild`, not something a session can do.
  The recipe is in the `Containerfile`, immediately above the
  `CONTEXT_MODE_PLUGIN_REF` ARG.
- The FTS5 store lives under a directory of the agent that wired it —
  in-container `~/.claude/context-mode` for Claude Code (on the host
  `~/.local/share/riotbox/<session>/context-mode`), opencode's data directory
  `~/.local/share/opencode/context-mode` for opencode and `~/.pi/agent/context-mode`
  for Pi (on the host under `~/.local/share/riotbox-state/<session>/opencode-data/`
  and `pi-agent/`). It holds verbatim tool
  output — treat it with the same sensitivity as your session transcripts.
  `riotbox session-remove` deletes it along with the rest of the session.

  The location is per agent rather than shared, which is a deliberate cost: a
  session directory reused with a different `--agent` starts from an empty store,
  because recall does not cross from one agent's store to another's. Only one
  agent's *wiring* exists in a session directory at a time — starting a session
  with a different `--agent` strips the others' on the way in — but the stores
  themselves stay until the session is removed.
- **Two stores, both kept with the session.** `content/` holds the parked tool
  output; `sessions/` holds continuity — what the session did, and the snapshot
  `PreCompact` writes so an autocompact does not lose the thread. Both persist for
  the project set, so `riotbox resume` and a fresh run on the same projects pick up
  what the last one learned.

  opencode's stores sit in its data directory rather than its config directory
  because a launch replaces the config copy whenever you have a host
  `~/.config/opencode/`. A host `~/.config/opencode/context-mode/` is not copied
  in, and neither is `~/.config/opencode/memory/`, upstream's default home for
  opencode's auto-memory: it holds memory from every project on the host. Each
  session's auto-memory lives in `~/.local/share/opencode/context-mode/memory`
  instead, kept with the session's other stores. One case loses out: if your
  own opencode config loads context-mode as a plugin and RiotBox's Context Mode
  is off, upstream still reads and writes `~/.config/opencode/memory/`. That
  session starts with none of your host's auto-memory, and with a host
  `~/.config/opencode/`, what it writes there is discarded at the next launch.
  Sessions created by an earlier RiotBox kept them at
  `~/.config/opencode/context-mode`. Only sessions whose host has no
  `~/.config/opencode/` still have them: with a host config dir, the first
  launch after upgrading replaces the config copy before the container starts,
  as every launch did before, so those stores are lost. Where they survive, the
  first start after upgrading moves them across. It moves nothing, and warns,
  when both locations already hold stores (the session uses the new one) or
  when a `.db-wal` or `.db-shm` file shows another opencode session of the
  project may have the store open. A crashed session leaves those files behind
  for good; the warning then gives two recovery commands. Don't delete the
  `-wal` file: it can hold committed data.
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
- **Starting a session needs no network, on any agent.** On Claude the plugin
  is cloned at a pinned ref and has its dependencies installed at image build
  time, and the session only writes a registry entry naming that path; on
  opencode riotbox generates the plugin file itself; on Pi the `packages` entry
  is the absolute path of the copy installed in the image, so Pi never installs
  it from npm. No path runs `context-mode upgrade`, which clones upstream and overwrites the installed
  tree with whatever is on `main`. On opencode the same reasoning is why the
  generated plugin file re-exports the copy
  **vendored in the image, by absolute path**, instead of riotbox adding
  `"plugin": ["context-mode"]` to the opencode config: an npm plugin entry makes
  opencode `bun install` the package from the registry at every startup, which
  needs network (`RIOTBOX_NETWORK=none` forbids it) and floats the version off
  the pin the image build asserts against.

  One outbound request remains on the Claude and Pi paths, and it is not RiotBox's: the
  MCP server GETs `https://registry.npmjs.org/context-mode/latest` at startup to
  warn about newer versions. It carries no payload, fails soft, and — unlike
  headroom and CodeGraph — has no off switch; `RIOTBOX_NETWORK=none` is what
  suppresses it. Pi's extension starts the same MCP server as a child, so it
  makes the same request. The opencode path has no counterpart, because it starts no
  server: the plugin imports the server module with
  `CONTEXT_MODE_EMBEDDED_PLUGIN_TOOLS=1`, which is exactly the flag that skips
  the startup routine the version check lives in. See [Context Mode store and
  wiring](THREAT_MODEL.md#context-mode-store-and-wiring) in the threat model.
- **A `context-mode` plugin installed on your host is skipped on Claude, and
  riotbox does *not* say so.** Host plugins otherwise win every merge (see
  [Plugins](#plugins)), but a host Context Mode tree has been through neither the
  interpreter rewrite nor the offline dependency install the staged one has, so
  every hook would spend 120 seconds in `npm install` and fail. The skip is
  narrow: it applies only when `RIOTBOX_CONTEXT_MODE=1` *and* riotbox has
  actually registered the tree the image staged for that session. With the toggle
  off, on an image built before the staging layer, or where that registration did
  not go through — an unreadable staged tree, or a plugin registry file riotbox
  could not parse — your host copy is copied in and enabled as usual, and is then
  the only Context Mode the session has, which riotbox leaves alone. Unlike
  the opencode case below, nothing is printed either way; check
  `~/.local/share/riotbox/<session>/.claude/plugins/installed_plugins.json` if you
  need to know which tree a session is running.
- **A `context-mode` entry in your own opencode config is dropped, and riotbox
  says so.** opencode loads a local plugin file and an npm plugin of the same
  name as two separate plugins, so leaving both in place would register the
  eleven `ctx_*` tools twice and fire every hook twice. When
  `RIOTBOX_CONTEXT_MODE=1`, `context-mode` and `context-mode@<version>` are
  filtered out of the `plugin` array of the generated `opencode.jsonc` and a
  warning on stderr names what was dropped and why. Your host config is not
  modified, and with the toggle off nothing is filtered — the entry is then your
  own plugin choice. On Pi a `context-mode` entry in your host `packages` is
  dropped with every other host package (see [Pi config](#pi-config)), whatever
  the toggle says.
- Context Mode runs on its own pinned Node 22 inside the image on the Claude
  path, independent of whichever Node versions the build mirrored from your host.
  **The opencode path does not use it**: the plugin runs under opencode's
  embedded bun, and upstream's `bun:sqlite` adapter means the native SQLite
  addon that forced the pinned Node is never loaded there. Pi runs on its own
  pinned Node, the same version today, so the extension loads the addon built
  for it.
- **`ctx_execute` runs TypeScript because the image ships [bun](https://github.com/oven-sh/bun).**
  Without it upstream reports `TypeScript: not available (install bun, tsx, or
  ts-node)` and TS snippets do not run at all. The version is pinned and the
  download is checked against a SHA256 — see [Pre-installed
  tools](#pre-installed-tools). This is separate from the bun opencode embeds:
  the hooks on the Claude path do not use either, they run the pinned Node.
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
- Two separate removals keep a reused session directory honest. The **plugin
  registration** is rebuilt from whatever the image stages at every session start
  and taken out the first time a session starts without the toggle, so a session
  does not carry a registration pointing at a plugin tree an image rebuild took
  away. **Wiring riotbox authored** — the opencode shim, and the hook stanzas and
  MCP entry a pre-plugin release wrote into Claude's `settings.json` and
  `.claude.json` — is stripped on that same session start, and starting with a
  different `--agent` strips the other agent's, so a session directory never holds
  hooks that point at a binary that is gone, or one agent's wiring while another
  agent runs.

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

RiotBox ships it in the image (pinned version, telemetry permanently off) and leaves it
at that — the MCP server is not registered, because it conflicts with Context Mode and
`codegraph explore` answers the same questions from the shell. Building the index is a
one-time step per project, and RiotBox does not do it for you:

```sh
riotbox shell ~/code/myproject
# inside the container:
codegraph init
```

The container prints a reminder for any project that has no index yet. After `init`,
query it from the shell:

```sh
codegraph explore "how does the launcher decide which mounts to pass?"
```

The index lives in `.codegraph/` at the project root. Because nothing runs in the
background on its behalf, it is brought up to date when you run CodeGraph again rather
than continuously. On an ordinary read-write project mount it persists across restarts
through the same bind mount as your code; the overlay and `:O` cases below are the
exceptions.

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
- **RiotBox registers no MCP server, and cleans up after the images that did.** Releases
  before this one ran `codegraph install` at every session start, which wrote an
  `mcp__codegraph__*` permission and a `UserPromptSubmit` hook running `codegraph
  prompt-hook` into the session's `~/.claude/settings.json`, plus an `mcpServers` entry
  into the session `.claude.json`. RiotBox never syncs `settings.json` in either
  direction, so that wiring outlives the image that wrote it — and because the CLI is
  still installed, a surviving MCP entry does not fail quietly; it starts a second code
  intelligence server alongside Context Mode. Every session now strips both back out and
  reports what it removed. Both strips match only the exact shapes the installer wrote,
  so a hook, permission, or `codegraph` server you narrowed yourself is left alone. What
  they cannot do is tell the installer's shape from an identical one you wrote: a
  `codegraph` server left at CodeGraph's own default, or the bare `mcp__codegraph__*`
  wildcard, goes with the rest — and goes again on every session start, not just the
  first, so re-adding it unchanged will not make it stick. Give it a shape of its own if
  you want one to survive: an extra argument on the server entry, or a permission naming
  a single tool rather than the wildcard. You never have to run `codegraph uninstall`.
  See [THREAT_MODEL.md](THREAT_MODEL.md) for the full analysis.
- **The index contains your source.** It stores verbatim code and symbol names — treat
  `.codegraph/` with the same sensitivity as the project itself.
- **In overlay mode**, the index is written into the overlay rather than your project and
  is treated as a rebuildable cache rather than a change: it never appears in `riotbox
  overlay-diff` and never blocks the next session. Because it lives in the session's
  state directory there, `riotbox session-remove` and `riotbox session-reset` delete it. See
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

## GitHub and GitLab (the riotbox-gh-glab flavor)

A second image, `riotbox-gh-glab`, adds the `gh` and `glab` CLIs (from EPEL).

```sh
# Build it. Tags riotbox-gh-glab; the base riotbox image is untouched.
RIOTBOX_GH_GLAB=1 riotbox build

# From a repo checkout, the same thing:
task build:gh-glab
```

The base image and the flavor share every layer but the last, so if you already have
`riotbox` built this takes about a minute rather than the usual 15–60.

Run it by pointing `IMAGE_NAME` at the flavor:

```sh
IMAGE_NAME=riotbox-gh-glab riotbox shell
```

Prefer the environment over `~/.config/riotbox/config` for this one. A forcing
`IMAGE_NAME=riotbox-gh-glab` in that file does reach the launch — but not the
check in front of it. `riotbox` verifies the tag exists before `launch.sh`
sources the config, so the check always runs against `riotbox` while the
container runs on the flavor. That splits two ways, both bad:

- The base image is missing but the flavor is built: `riotbox shell` stops with
  `ERROR: Image 'riotbox' not found. Run 'riotbox build' first.` — a tag you
  never asked for, blocking a launch that did not need it.
- The flavor is missing but the base is built: the check passes, and the
  failure comes from podman or docker complaining about `riotbox-gh-glab`,
  without riotbox's build hint.

The `: "${IMAGE_NAME:=riotbox-gh-glab}"` default form the config file uses
elsewhere does nothing at all here — `riotbox` has already set `IMAGE_NAME` by
the time the file is read, so `:=` never assigns.

`riotbox doctor` is the exception: its preflight reads the config before it
reads the variable, so a forcing assignment there does probe the flavor. From
the environment it works the same way:

```sh
IMAGE_NAME=riotbox-gh-glab riotbox doctor
```

### Refreshing and removing the flavor

`riotbox rebuild`, `riotbox update` and `task container:clean` all default to the
base `riotbox` tag. The build verbs need `RIOTBOX_GH_GLAB=1`, the same knob the
first build took; `container:clean` needs the tag:

```sh
# Re-pull the LLM CLI tools in the flavor (same knob as the build)
RIOTBOX_GH_GLAB=1 riotbox update
RIOTBOX_GH_GLAB=1 task update       # from a repo checkout

# Rebuild it from scratch
RIOTBOX_GH_GLAB=1 riotbox rebuild

# Delete the flavor image, leaving the base one alone
IMAGE_NAME=riotbox-gh-glab task container:clean

# Without a checkout, go through your container runtime directly
podman rmi riotbox-gh-glab          # or: docker rmi riotbox-gh-glab
```

### Getting your tokens into the session

`gh` and `glab` authenticate with tokens from the environment, and those have to
reach the container. They are deliberately **not** forwarded by default — that would
push your forge credentials into every riotbox session, including ones with no forge
tooling and no reason to hold a token.

```sh
# ~/.config/riotbox/config
RIOTBOX_PASSTHROUGH_EXTRA_VARS="GITHUB_TOKEN GITLAB_TOKEN GITLAB_HOST"
```

| Variable | Used by | Notes |
|---|---|---|
| `GITHUB_TOKEN` | `gh` | `gh` prefers `GH_TOKEN` when both are set |
| `GITLAB_TOKEN` | `glab` | |
| `GITLAB_HOST` | `glab` | host or URL of a self-managed instance, e.g. `gitlab.example.com`; defaults to `gitlab.com` |

### `gh` and `glab` themselves

Both are on `PATH` and read their own environment variables (`GITHUB_TOKEN`,
`GITLAB_TOKEN`, `GITLAB_HOST`), so once those are passed through they work with no
further setup.

> **A word on prompt injection.** Pointing an autonomous agent at issues, pull
> requests and merge requests means feeding it text written by anyone who can open
> one. Treat what the CLIs print — issue bodies, PR comments — as untrusted input,
> and use a token scoped no wider than the work needs. See
> [Security model](#security-model).

Earlier images also offered `enable_github_mcp` and `enable_gitlab_mcp`. They were
removed in favor of the CLIs, which models already know and which cost no context
until used. Any server entry they wrote into a session's Claude Code or opencode
config is removed automatically at the next session start, with a note on stderr.
A server you configured yourself is left alone unless it exactly matches what
riotbox wrote: an unmodified `github-mcp-server stdio` entry, or a GitLab
`/api/v4/mcp` entry whose only header is a bearer token variable reference
(`Bearer ${VAR}` for Claude Code, `Bearer {env:VAR}` for opencode). To keep such
a server, change what riotbox matches on: add an argument, an environment
variable or a header, or use a literal token. Other fields, such as a timeout,
do not count.

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

`overlay-diff`, `overlay-accept` and `overlay-reject` take the projects the session was
launched with: none when you launched from the project directory, the path you gave, or,
for a multi-project session (`riotbox ~/src/app ~/src/lib`), every path of the set in any
order. Each project of a set keeps its own overlay. `overlay-diff` shows them one after
another under an `Overlay diff for: <project>` header. `overlay-accept` and `overlay-reject`
handle each project in turn, each with its own checks and prompt, then print one result line
per project (`applied`/`discarded`, `unchanged` when it had nothing to apply, `declined`,
`failed`, or `interrupted` when Ctrl-C stopped it). If you decline a project or its accept fails, that project's changes stay
pending, untouched, and the other projects still go ahead. Declining is not a failure. The
exit status is 0 when every project was handled (declined included), 1 when a project
failed or the projects could not be resolved, and 130 on Ctrl-C, which stops the remaining
projects after printing the results so far (the interrupted one keeps its changes). The
launch that refuses to start while changes are pending prints these three commands with
every path of the session, and so does `riotbox overlays` (shell-quoted, so you can paste
them). One project of a set on its own is refused with the command for the whole set. Two
projects with the same directory name (`a/app` and `b/app`) cannot be mounted together, and
the overlay commands refuse that set.

Each launch records its project set in the session's state directory
(`~/.local/share/riotbox-state/<session>/projects`), which no container can reach. The overlay
commands, `riotbox overlays` and the launch's hints take project paths only from that
record, never from the session directory's `.projects` (which the session can rewrite), and
the overlay commands refuse a project list that differs from it, since a session's changes
must only reach the projects it was launched with. A session last launched by an older RiotBox has no record. `riotbox overlays`
shows its project as unknown, without commands, and `overlay-accept` refuses until you
launch the set once with `RIOTBOX_OVERLAY=1`. That launch records the set and, since changes
are pending, stops before starting a session. `overlay-diff` and `overlay-reject` work
without the record. A launch that replaces a record naming a different set warns. If a
launch finds pending changes but no record, and the session's `.projects` names a different
set, it warns that the changes may belong to that set, which it shows but never offers as a
command. It still records the set you launched, and keeps that record while the changes are
pending. If the changes came from the other set, reject them as the recorded set (or accept
them as it, if they suit those projects), or delete
`~/.local/share/riotbox-state/<session>/projects` and launch the right set to record it.

The overlay is written by the session, so `overlay-accept` treats it as untrusted:

- `overlay-accept` and `overlay-reject` refuse while a RiotBox container that has this
  overlay mounted read-write is still running, or when the container engine cannot say whether one
  is. Exit that session first. Other sessions on the same project (normal mode, or a
  directory inside it) do not block; `overlay-accept` names the ones that have the project
  mounted read-write, because they can change it while you review. `overlay-diff` still
  runs, with a note that the overlay can change while you read it. Every running container
  is checked by what it mounts, so a session an older RiotBox started, which has no
  `riotbox.session` label, blocks too. Without the label, a container blocks only when it
  mounts the overlay itself or something inside it, so a toolbox or distrobox container that
  mounts `/` does not block; `overlay-accept` still names it in its warning, since it can
  change the project while the apply runs.
- A symlink in the overlay is listed as `LINK  path -> target` and applied as a symlink,
  never followed. Applying a file over a symlink in your project replaces the link.
  Applied files lose any setuid/setgid bit.
- The accept stops before changing anything if an entry would be written through a
  symlinked directory in your project, if an entry's type differs from what is in the
  project in a way it cannot apply safely (a file over a directory, a directory over a
  file or a symlink), if a name contains a control character (the review shows it
  escaped), if a whiteout is malformed, or if the overlay holds a FIFO, socket or device.
- Everything is checked again after you confirm. If the overlay or the project changed
  since the review, nothing is applied; run `overlay-accept` again to see the current
  changes. Validating every entry twice is deliberate; with the apply it costs roughly
  25 ms per entry (about 5 seconds for 200 files). A change another session makes to the project while the apply itself runs is
  not detected.
- If an accept is killed before it finishes, its changes stay in
  `overlay/<name>.accepting.<pid>` in the session's state dir. `riotbox overlays` lists
  it with the command that puts it back, and a new overlay session refuses to start until
  you do.
- If a session replaces the overlay's `upper` or `work` directory with a symlink or a file,
  the next overlay launch refuses and prints the `riotbox overlay-reject` command for the
  session's projects. That command removes the link or file itself, never what it points
  at, puts an empty directory back, and discards any changes as usual; after it the launch
  works again.

`riotbox overlays` exits 0 when it lists pending overlays, 1 when there are none, and 2
when it could not adopt overlay data left by an older RiotBox.

A [CodeGraph](#codegraph-code-intelligence) index (`.codegraph/`) is rebuildable derived
data, not a change to review, so it is excluded from `overlay-diff`, from the file counts
in `riotbox overlays`, from the session exit summary, and from the check that refuses to
start a new session while changes are pending. Rebuilding an index therefore never locks
you out. `overlay-accept` still copies it through to your project alongside the changes
you accepted; an overlay containing *only* an index counts as no changes at all, so both
`overlay-accept` and `overlay-reject` report nothing to do and the index simply stays in
the overlay for the next session. One consequence: such an overlay is invisible to
`riotbox overlays`, including its disk usage, so a large index can sit in the session's
state directory unreported — `riotbox session-remove` clears it.

A `.headroom/` at the top of the overlay is headroom memory that an older RiotBox let
headroom write into the overlay (see [Headroom](#headroom-context-compression-opt-in)).
It is hidden from the same places as an index. Unlike an index, it never reaches your
project: `overlay-accept` neither copies it nor deletes a `.headroom/` of yours, and both
`overlay-accept` and `overlay-reject` leave it in the overlay. `overlay-diff` counts the
hidden files in a closing note. The one-time headroom notice prints the commands to
delete it or move it to where headroom memory is kept now.

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

- **Local bare backup**: Before every read-write session (`run`, `shell`, `resume`, and the `nested-`/`socket-` variants), every branch, tag, git-notes ref and checkpoint snapshot is pushed to a bare clone under `~/.local/share/riotbox/backups/`. Notes are included because [git-ai attribution](#ai-authorship-attribution-git-ai) lives in `refs/notes/ai`, which is outside git's default push refspec and so exists in only one place on disk otherwise; like branches and tags they are force-pushed, since a `riotbox reown` legitimately rewrites them. The store is named after the project's full path with each `/` turned into `-`, so `/home/you/work/my-project` is backed up to `home-you-work-my-project.git` and two projects that share a basename never share a store. It is cloned with `--no-hardlinks --dissociate`, so it shares no objects with the project, and it lives outside the container's mount tree — the agent cannot access or modify it. Even if the agent deletes every file and rewrites all history, the backup is intact.
- **Checkpoint snapshots**: Before each session RiotBox writes a snapshot of the project — tracked, staged, unstaged and untracked files alike — to `refs/riotbox/checkpoints/<timestamp>`. It is built in a throwaway index and sealed with `git commit-tree`, so **nothing is committed to your branch, no tag is created, and your working tree, index and HEAD are left exactly as they were.** Because the ref lives outside `refs/heads` and `refs/tags`, it never appears in `git tag`, never affects `git describe`, and is never published by `git push --tags` (or `git push --all`). One place git does surface it: `--all` means every ref under `refs/`, so `git log --all`, `gitk --all` and any GUI defaulting to all refs show the snapshot *commits* — undecorated, with no ref name attached, because no branch or tag points at them. Nothing in git names the snapshots, which is what `riotbox checkpoints` is for. See [Recovery](#recovery).
- **Session branches**: On `shell` sessions, the container offers to create a `riotbox/<id>` branch. The agent works there; on exit the branch is fast-forward merged back so the full commit history lands seamlessly on your branch. See [Session branches](#session-branches).
- **Git repo bootstrapping**: If a project directory isn't a git repo, RiotBox offers to create one so the checkpoint mechanism has something to protect. Empty repos (no commits yet) are handled gracefully — see [Initializing a git repo](#initializing-a-git-repo).
- **Managed `.git/info/exclude` block**: Before each snapshot, RiotBox injects a managed block into the project's `.git/info/exclude` file so three classes of file are never swept into a snapshot or pushed to the backup:
  - **Runtime artifacts** — `.headroom/`, `.codegraph/`, `.lola/`, `.claude/settings.local.json`, `CLAUDE.local.md`, `venom.log`, `venom.*.log`.
  - **Dependency and build trees** — `node_modules/`, `.venv/`, `venv/`, `__pycache__/`, `target/`, `.next/`, `.nuxt/`, `vendor/`, `.gradle/`, `.m2/`, `Pods/`, `.terraform/`, `*.egg-info/`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`. These are reproducible from a lockfile and cost real time and disk: one unignored `node_modules` measured 3.4 s and an 83 MB backup on *every* launch, against 70 ms and 8 KB with it excluded. `dist/` and `build/` are deliberately **not** excluded — they are real source directories often enough that guessing would be worse.
  - **Secrets** — `.env`, `.env.*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `.npmrc`, `.netrc`, `*.p12`, `*.pfx`. A snapshot is copied to the off-host backup, so a credential the project forgot to gitignore would otherwise be copied out of the project on every launch.

  These patterns affect **untracked files only**. Anything you have already committed keeps being snapshotted with its edits — a tracked `vendor/lib/dep.go` or a deliberately committed `.env` template is captured exactly as before. Nothing in the list can drop committed work out of the safety net.

  This file is per-clone and never reaches collaborators (it lives in `.git/`, which is not tracked). You can add your own exclusion patterns anywhere outside the `>>> riotbox managed excludes <<<` markers; RiotBox only ever touches content between them.
- **Per-file size cap on untracked files**: An untracked file larger than **10 MB** is left out of the snapshot, because it would otherwise be hashed and copied into the backup on every launch. Tracked files are never capped — they are already in git, so re-snapshotting one costs nothing. Every skipped file is reported by name and size on stderr; that report is **not** silenced by `RIOTBOX_CHECKPOINT_QUIET`, because it names data that is deliberately left unprotected:

  ```
    WARNING: my-project: snapshot skipped 1 untracked file(s) over 10 MB:
               fixtures/dump.iso        (1.4 GB)
             These are NOT in the snapshot and NOT in the backup.
             Add them to .gitignore, or `git add` them to include them.
             Raise the limit with RIOTBOX_SNAPSHOT_MAX_MB.
  ```

  A skipped file **is not protected**: it stays on disk in the project the agent is handed read-write, and no copy of it exists in the checkpoint or the backup. Set `RIOTBOX_SNAPSHOT_MAX_MB` to change the threshold (for example `RIOTBOX_SNAPSHOT_MAX_MB=500`), or `git add` the file so it is tracked and therefore always captured.
- **Git guardrails**: Inside the container, `receive.denyNonFastForwards` and `receive.denyDeletes` are enabled to prevent the most destructive git operations.
- **Container isolation**: The agent can't access your SSH keys, cloud credentials, or anything outside the mounted directories.

### Recovery

Every read-write session starts by snapshotting the whole project — tracked,
staged, unstaged and untracked files — into
`refs/riotbox/checkpoints/<timestamp>`, in the project repo and in the bare
backup. Recovery is finding the right snapshot and putting it back. The
commands below need **git 2.23 or newer** for `git restore`.

**1. Find the snapshot.** No git command lists these refs by name, so ask
RiotBox:

```sh
cd /path/to/my-project
riotbox checkpoints
```

```
Project: /path/to/my-project
  Snapshots (in refs/riotbox/checkpoints — no branch, no tag, so git tag, git describe
  and git push never show them; git log --all shows the commits, unnamed):
    20260804-144825  2 files    refs/riotbox/checkpoints/20260804-144825
  Restore one into the working tree (HEAD and your branches do not move):
    git -C /path/to/my-project restore --source=<ref> -- .
  See what it would change first (git diff never looks at untracked files,
  so a file the snapshot captured that is untracked today shows as a deletion):
    git -C /path/to/my-project diff <ref>
```

The middle column says how much each snapshot holds, and it is decided from the
snapshot itself, so it does not change meaning as you keep committing:

- `clean` — the tree was clean, so the ref points straight at the commit HEAD
  was on. Nothing uncommitted was captured, because there was nothing to
  capture.
- `initial` — the snapshot has no parent: it was taken on a repo with no
  commits yet, so it holds uncommitted work and nothing else.
- `N files` — the number of paths that differ between the snapshot and the
  commit it was taken on: how much uncommitted work it is holding.

The paths it names are always the worktree top level, even when you run
`riotbox checkpoints` from a subdirectory — `restore ... -- .` is relative to
the directory `git -C` puts it in, so a hint naming a subdirectory would
quietly restore only that subtree.

**2. See what the snapshot would change.**

```sh
git diff refs/riotbox/checkpoints/20260804-144825
```

This diffs the snapshot against your current working tree. One thing to know:
`git diff` never looks at untracked files, so a file that the snapshot captured
and that is untracked in your tree today shows up as a deletion even when it is
sitting on disk.

**3. Put the files back** — the non-destructive option:

```sh
git restore --source=refs/riotbox/checkpoints/20260804-144825 -- .
```

This overwrites your working-tree files with the snapshot's and recreates the
ones that are missing, including files that were only ever untracked. It does
**not** move HEAD or any branch, does not touch the index, and does not delete
files created after the snapshot — so anything the agent added is still there
for you to review and remove.

**4. Or reset the branch to the snapshot** — the destructive option:

```sh
git reset --hard refs/riotbox/checkpoints/20260804-144825
```

This throws away everything since and makes the snapshot commit your branch
tip, so its whole tree becomes committed history — including files that were
merely untracked when the snapshot was taken. Prefer step 3 unless you want the
branch moved.

**If the repository itself is gone**, restore from the bare backup. Snapshot
refs live outside `refs/heads` and `refs/tags`, so they need an explicit
refspec: a plain `git clone`, a default `git fetch`, and `git fetch --tags` all
bring back branches and tags and **zero** snapshots.

```sh
# Find your store — it is the project's full path with '/' turned into '-'.
# /home/you/work/my-project → home-you-work-my-project.git
ls ~/.local/share/riotbox/backups/

# Into the existing project:
git fetch ~/.local/share/riotbox/backups/home-you-work-my-project.git \
    'refs/riotbox/checkpoints/*:refs/riotbox/checkpoints/*'

# Or into a fresh clone — the clone brings the branches, the fetch brings the snapshots:
git clone ~/.local/share/riotbox/backups/home-you-work-my-project.git my-project-restored
cd my-project-restored
git fetch ~/.local/share/riotbox/backups/home-you-work-my-project.git \
    'refs/riotbox/checkpoints/*:refs/riotbox/checkpoints/*'
```

Then go back to step 1 — `riotbox checkpoints` now lists the recovered
snapshots.

**Keeping one around.** `riotbox checkpoint-tag <timestamp>` promotes a
snapshot to a real tag, `riotbox-snapshot/<timestamp>`, when you want ordinary
git commands to see it. That tag *is* a real tag: until you delete it, it
appears in `git tag`, it changes what `git describe --tags` reports, and
`git push --tags` publishes it. `riotbox checkpoint-prune` deletes snapshots
when you no longer want them; it needs an explicit selector (`--keep <N>`,
`--older-than <N>d`, or `--legacy`), it never writes to the backup store, and
it marks any ref the store has no copy of before asking you to confirm.

### Upgrading from checkpoint tags

Earlier versions of RiotBox committed uncommitted work to your branch and
tagged it `riotbox-checkpoint/<timestamp>`. If you used one of those versions:

- **`riotbox build` is required.** `container/session-branch.sh` is baked into
  the image and sourced by the entrypoint, so upgrading the package alone
  leaves the old copy running inside the container.
- **Old `riotbox-checkpoint/*` tags are inert but not harmless.** Nothing
  creates or reads them any more, and they still change what
  `git describe --tags` reports. `riotbox checkpoints` lists them separately;
  `riotbox checkpoint-prune --legacy` removes them all.
- **Old `checkpoint:` commits in your history are left alone.** They are
  ordinary commits on your branch and RiotBox never rewrites your history;
  removing them is yours to do, or not.
- **Backups made before this change were cloned with hardlinks**, so they share
  object files with the project the agent is handed read-write and are not
  actually isolated from it. RiotBox does not re-clone a store that already
  exists, so force a fresh one:

  ```sh
  # 1. Pull any snapshots that exist only in the old store back into the project
  git -C /path/to/my-project fetch ~/.local/share/riotbox/backups/home-you-work-my-project.git \
      'refs/riotbox/checkpoints/*:refs/riotbox/checkpoints/*'
  # 2. Move the old store aside (do not delete it until step 4 checks out)
  mv ~/.local/share/riotbox/backups/home-you-work-my-project.git \
     ~/.local/share/riotbox/backups/home-you-work-my-project.git.hardlinked
  # 3. Relaunch — the next checkpoint clones a fresh, fully isolated backup
  riotbox shell /path/to/my-project
  # 4. Confirm the new store has your branches and snapshots, then remove the old one
  git -C ~/.local/share/riotbox/backups/home-you-work-my-project.git for-each-ref
  ```

- **Backup stores have moved** from `<basename>.git` to the path-derived name
  above. When RiotBox can prove an old basename store belongs to the project it
  is backing up — the store's recorded origin URL is that project — it renames
  it in place and says so. When it cannot, it leaves it alone: on a basename
  collision that store is some other project's history.

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

**If the working tree still has uncommitted edits** that checking out the base branch would overwrite: the switch back is refused, so the merge is skipped and the session branch stays checked out. The container says so and prints the resolution (`git stash`, switch, `git merge --ff-only`, `git stash pop`). This one is sticky — until you resolve it, later sessions just continue on that branch, because setup sees it is already a session branch and neither creates nor merges a new one. Untracked scratch files and edits to files that are identical on both branches do not trigger this; git only refuses when the checkout would destroy work.

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

- **Empty repo (no commits yet):** Starting in a freshly `git init`'d directory is fine. A repo with no commits *and* no files has nothing to capture, so the checkpoint step prints `empty git repo (no commits yet) — nothing to checkpoint` and the session continues. If the directory does have files in it, they are snapshotted as a parentless commit in `refs/riotbox/checkpoints/<timestamp>` — still nothing committed to a branch and no tag created, so the repo has no commits and no branch when the session starts, exactly as you left it.

- **Not a git repo:** In an interactive session (`shell`, `resume`), RiotBox asks before creating one:

  ```
    /path/to/project is not a git repository.
    Create one so your work can be checkpointed? [Y/n]
  ```

  Answer yes (the default) and the directory is initialized and immediately snapshotted to `refs/riotbox/checkpoints/<timestamp>`; nothing is committed to a branch and no tag is created. Answer no and the session continues without checkpoint protection (you'll see the no-protection warning).

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
- **Review changes before merging.** Run `riotbox checkpoints` for the pre-session snapshot, then `git diff refs/riotbox/checkpoints/<timestamp>` to see everything the agent did — committed and uncommitted alike.
- **Use branches.** Run the agent on a feature branch, not main. Session branching automates this.

## Security model

### What's exposed to the container

| Resource                                 | Access                       | Notes                                         |
|------------------------------------------|------------------------------|-----------------------------------------------|
| Project directory                        | read-write bind mount (`:z`) | Your code — the agent needs full access       |
| Session data (`~/.local/share/riotbox/`) | bind mount (`:z`)            | Isolated per project set                      |
| Session state (`~/.local/share/riotbox-state/<session>/`) | one bind mount (`:z`) per subdirectory | Never mounted whole, so the container cannot replace a mount source |
| `~/.claude/.credentials.json`            | nested bind mount (RW)       | OAuth token refreshes must write back to host |
| `~/.claude.json`                         | file copy into session dir   | Each container gets a writable snapshot       |
| opencode and Pi auth files (`~/.local/share/opencode/auth.json`, `~/.pi/agent/auth.json`, `~/.pi/agent/mcp-auth.json`) | bind mount (RW), when present | Token refreshes write back; mounted whichever `--agent` runs |
| Pi config allowlist (`~/.pi/agent/`)     | file copy into state dir     | See [Pi config](#pi-config); nothing flows back |
| RiotBox config (`~/.config/riotbox/`)    | bind mount (`:z`)            | `plugins.conf`, `config`, `mounts.conf`, `egress.conf` |
| Host plugins (`~/.claude/plugins/`)      | read-only bind mount         | Merged into session at startup                |
| User scripts (`~/bin`)                   | read-only bind mount         | Available but not writable                    |
| User-defined mounts                      | read-only bind mount by default | From `~/.config/riotbox/mounts.conf`; per-entry `:rw` opt-in |
| Package caches                           | named volumes                | Shared across containers, not with host       |
| Network                                  | enabled; with `RIOTBOX_EGRESS=1`, only through a per-session allowlisting proxy | The agent needs npm/PyPI/crates.io etc. See [Egress proxy](#egress-proxy) |

### What's NOT exposed

`~/.ssh`, `~/.gnupg`, `~/.kube`, `~/.aws`, `~/.claude` (host conversations), cloud credentials, and anything not explicitly listed above (unless added to `mounts.conf`). The `.dockerignore` also blocks secrets (`.env`, `*.pem`, `*.key`, etc.) from being baked into the image.

### Other design choices

- **Sudo**: the container user has passwordless `sudo`. The agent often needs to `dnf install` build dependencies, and the container is disposable. This does **not** grant any host privileges.

- **UID/GID mapping**: the container user's UID and primary GID match your host UID and GID. The image is built per-host-user via `--build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g)` so the baked-in llm entry already carries the correct UID/GID for the building user — this is the load-bearing alignment that keeps podman's keep-id /etc/passwd rewrite from producing an inconsistent state.
  At runtime, `--userns=keep-id:uid=$(id -u),gid=$(id -g)` and `--user $(id -u):$(id -g)` are passed explicitly as belt-and-suspenders for cases where an image is used by a different host user than the one that built it. `fuse-overlayfs` is required for acceptable performance on large images.

- **SELinux**: project and session bind mounts use `:z`. Package caches use named volumes to avoid relabeling overhead. `.claude.json` is copied rather than mounted to avoid `:z` relabeling issues on 600-permission files; `.credentials.json` is bind-mounted RW inside the session directory (a nested mount that avoids the relabeling problem).

- **Tool configs** (`.npmrc`, `.editorconfig`, etc.) are copied at build time — not mounted — so edits inside the container don't affect the host. Auth tokens are stripped from `.npmrc`, `pip.conf`, and `cargo/config.toml` before baking into the image. Use `mounts.conf` to supply live credentials at runtime. Your `~/.gitignore_global` is copied the same way, and the image's git config sets `core.excludesFile` to it, so your global ignores apply inside the container. If you have none, the image gets [`container/gitignore_global`](container/gitignore_global) instead: OS and editor junk, `.env`, and per-user agent state. Your `~/.gitconfig` is never copied; the container's `~/.gitconfig` is baked by the Containerfile and commits as `LLM (riotbox)` so `reown` and the pre-push guard can recognise them.

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
- [Go](https://go.dev/dl/) 1.26.4 or newer (the `go` line of `go.mod`) — builds `riotbox-core` and runs its tests and linter. The Go dev tools (Ginkgo, ginkgoleaf, golangci-lint, GoReleaser) are pinned in `go.mod` and run through `go tool`, so they need no separate install
- [shellcheck](https://www.shellcheck.net/) — shell script linter (`dnf install ShellCheck` or `brew install shellcheck`)
- [hadolint](https://github.com/hadolint/hadolint) — Dockerfile linter (`brew install hadolint` or download from [releases](https://github.com/hadolint/hadolint/releases))
- [venom](https://github.com/ovh/venom) — integration test runner (downloaded automatically inside the test container)
- python3 — renders the errors-only Venom summary for `MODE=llm` (standard library only)
- `setpriv` (util-linux) — **only when running the suites as root.** One case in `tests/doctor-context-mode.venom.yml` extracts the `riotbox doctor` probe body and runs it, and that body tests `[ -w ]` against a 0555 directory — a test root passes whatever the mode, so as uid 0 the case drops to uid 65534 with `setpriv` rather than skipping and reporting coverage it did not get. It fails loudly if `setpriv` is missing. Run the suites as an unprivileged user and this is not needed at all; `dnf install util-linux` (or `apk add util-linux` on Alpine) if you must run them as root. CI covers that path rather than leaving it to whoever happens to be root: the `test` job re-runs this one suite as uid 0 (`task test:as-root`), and `tests/Containerfile.test` installs `util-linux` for it.

### Tasks

```sh
task check          # run all quality gates (lint + test + venom lint)
task lint           # shellcheck + hadolint + golangci-lint
task test           # build riotbox-core, run the Go suites, then the venom suites in the test container; MODE=llm for errors-only output
task go:build       # build libexec/riotbox-core from the Go sources
task go:test        # Go (Ginkgo) suites only; MODE=llm for errors-only output
task go:lint        # golangci-lint only
task fmt            # format Go code (alias for go:fmt: golangci-lint's gofmt + goimports)
task test:direct    # run venom directly on host (skip container build)
task test:as-root   # re-run a suite as uid 0 in the container (see below)
task test:lint      # structural lint of .venom.yml test suites
task test:egress-e2e  # egress proxy suite against this host's real podman (pulls Envoy; needs the internet)
task test:list      # list available test suites
task clean          # remove build output: .test-output/, dist/, configs/, libexec/riotbox-core, .task/
```

The `check` target executes all three gates in parallel: `lint` (shellcheck and hadolint), `test` (venom integration suites in a container), and `test:lint` (structural validation of venom test files).

For quick iteration on a single suite — or when working in an agent sandbox without the test image built — use `task test:direct -- tests/<suite>.venom.yml` (or `scripts/venom-run.sh tests/<suite>.venom.yml` if you prefer to skip task). The wrapper runs venom directly on the host and routes all output (logs and result files) into `.test-output/`. Do **not** run `venom run` from the repo root
yourself: venom writes `venom.log` to CWD on every invocation (and rotates earlier runs to `venom.N.log`) with no flag to redirect it, so a bare invocation litters the working tree.

`MODE=llm` (on `task test`, `task test:run` and `task test:direct`) replaces the Venom console output with an errors-only summary: each failing test case with its suite file, case name and the failure text from the XML results, then one totals line. Passing cases print nothing. `MODE=human`, the default, prints Venom's own output. Both modes save the full console output to `.test-output/venom-output.log` and keep Venom's exit code.

The test tasks (`go:test`, `test:run`, `test:as-root`, `test:direct`) isolate git from your own configuration: they set `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null` and a fixed `RiotBox Tests <riotbox-tests@invalid>` author and committer, and `run-tests.sh` passes the same variables into the test container. A case that needs its own global config or identity sets it explicitly.

`task test:as-root -- tests/<suite>.venom.yml` runs a suite as uid 0 inside the test container instead of as `testuser` (equivalently, `TEST_AS_ROOT=1 task test -- tests/<suite>.venom.yml`). It exists for the one case in `tests/doctor-context-mode.venom.yml` whose `setpriv` privilege drop is only reached when the runner is already root — see the `setpriv` prerequisite above. Pass a single suite; it is coverage for that branch, not a second full test pass. It reuses the same image, dropping `--userns=keep-id` so that container uid 0 maps to your own host uid: `.test-output/` artifacts stay yours and a later ordinary `task test` is unaffected. That mapping is a podman property — under docker the run would leave `.test-output/` owned by real root.

### Releasing

Releases are tag-driven. Bump the version, push the tag, and CI builds and publishes the packages:

```sh
task release:bump           # prompts for the version, writes VERSION and CHANGELOG.md, commits, tags
git push --follow-tags      # push the commit and the v<ver> tag together
```

`release:bump` reads the current version and offers the next one:

```console
$ task release:bump
Current version: 0.5.0
New version [0.5.1]:
✅ Released v0.5.1 — run 'git push --follow-tags' when ready
```

The default in brackets comes from [git-cliff](https://git-cliff.org) reading the [Conventional Commits](https://www.conventionalcommits.org) since the last `v*` tag. Press Enter to take it, or type any higher semantic version — `1.0.0` included — to override. While the major version is 0, a `BREAKING CHANGE` bumps the minor and a `feat` bumps the patch, so the prompt never proposes 1.0.0 on its own; reaching 1.0 is something you type. Those rules live in the `[bump]` block of [`cliff.toml`](cliff.toml).

`task release:bump -- 0.6.0` skips the prompt, which is what you want in a script.

Two cases make the suggestion fall back to a plain patch bump, each printing why: no `v*` tag exists yet (git-cliff has no baseline to measure against), or `VERSION` has drifted away from the last tag (its answer would be wrong rather than merely absent).

The task needs `git-cliff` on `PATH` and stops with install instructions when it is missing:

```sh
cargo install git-cliff --version 2.13.1
```

Each run regenerates `CHANGELOG.md` in full rather than prepending to it. The release commit itself is skipped by a `cliff.toml` commit parser, so regenerating later reproduces the same file.

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml). A `gate` job checks that the tag equals `VERSION` and runs `task go:lint` and `task go:test`; the venom suites need podman and have already run on `main` in `test.yml`. A `publish` job then runs [GoReleaser](https://goreleaser.com/) (v2.17.0, pinned in `go.mod`'s `tool` block) as configured in [`.goreleaser.yaml`](.goreleaser.yaml). The GitHub release for the tag gets the per-arch `riotbox-core` archives, the rpm and deb packages, an SBOM for each, and `checksums.txt` with its keyless cosign signature. [docs/dev/riotbox-core.md § Releasing](docs/dev/riotbox-core.md#releasing) lists every file name.

Every archive, package, SBOM and `checksums.txt` also gets a GitHub build-provenance attestation. The release notes are that version's section of the committed `CHANGELOG.md`, extracted by [`.taskfiles/scripts/changelog-section.sh`](.taskfiles/scripts/changelog-section.sh), so the published notes and the file in the repository cannot disagree.

`task release:package` runs the same GoReleaser configuration as a local snapshot into `dist/`, without signing or SBOMs, to check the packaging before you tag. How to verify a published release by hand is in [docs/dev/riotbox-core.md](docs/dev/riotbox-core.md#releasing).

## Podman setup

Rootless podman requires `fuse-overlayfs` for this project. Without it, `--userns=keep-id` triggers a full ID-mapped layer copy on the ~8 GB image, which hangs indefinitely.

### Required: build UID/GID mappings

The image creates its `llm` account with your host UID and primary GID. Both numeric IDs must be mapped **as container IDs** during a rootless Podman build. A typical 65,536-ID subordinate allocation cannot cover a UID in the millions, even though Podman maps that host user to container root. Otherwise the build eventually fails at `chown llm /workspace` with `Invalid argument`.

`riotbox build` and the `task build:*` image builds check the effective Podman maps before detecting toolchains or staging configs. The check reports each unmapped ID and the current map, including stale mappings after an allocation change. It also prints a `sudo usermod` command with a proposed range sized for your IDs, above all account and group IDs returned by `getent` and all allocations in `/etc/subuid` and `/etc/subgid`. An administrator must confirm the range is unused in any centrally managed allocations before running it. If lookups fail or there is insufficient space above the visible IDs, the check asks the administrator to choose a range instead.

Inspect the effective maps:

```sh
id -u
id -g
podman unshare cat /proc/self/uid_map /proc/self/gid_map
```

Each row is `container_start host_start count`. Your UID must fall within a UID-map row's container range, and your primary GID within a GID-map row's container range: `container_start <= ID < container_start + count`. Check every row; allocations can be split across several ranges.

If either ID is missing:

1. Have an administrator choose additional unused host ranges for `/etc/subuid` and `/etc/subgid`. They must not overlap real account IDs, group IDs, or other subordinate allocations. Keep existing allocations in place and choose new ranges above all of your existing host ranges in each file. Podman sorts allocations by host ID; adding a lower range shifts existing container IDs and can break ownership in container storage, even when the entry is appended at the end of the file.
2. Stop services that automatically restart your containers, then run `podman system migrate` as your normal user. This stops that user's running containers and releases Podman's persistent namespace. Avoid further Podman commands until the allocations have been updated.
3. Have the administrator append the ranges. For example, **only if host IDs 10000000–14999999 are available and above your existing ranges in both files**, this adds five million subordinate UIDs and GIDs:

   ```sh
   sudo usermod --add-subuids 10000000-14999999 \
     --add-subgids 10000000-14999999 "$(id -un)"
   ```

   With an existing `165536:165536` allocation, the effective map would then be:

   ```text
   0        <your host UID or GID> 1
   1        165536                165536
   165537   10000000              5000000
   ```

   This covers container IDs through 5165536, including UID/GID 4243795. Choose a larger additional allocation if your IDs require it; the host range's start does not determine the container range's start.
4. Re-run `podman unshare cat /proc/self/uid_map /proc/self/gid_map`, confirm both IDs are covered, and retry the same build command. Restart container services as needed.

This repair does not require `podman system reset`. See [Podman's migration documentation](https://docs.podman.io/en/latest/markdown/podman-system-migrate.1.html) for why the persistent namespace must be stopped before editing subordinate allocations.

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

When something breaks, the first thing to try is `riotbox doctor` — it walks every host prerequisite (podman, fuse-overlayfs, `flock`, a `riotbox-core` matching this install, image build, credentials, plugin/skill dirs) and prints a fix hint per failure. By default every check runs even if earlier ones failed, so a single invocation surfaces every problem at once; set `RIOTBOX_DOCTOR_FIRST_FAIL=1` to short-circuit at the first failure. The exit code is the FIRST failure encountered (0 on full pass). The same checks run at the end of `./setup.sh`, so a fresh install is self-verifying.

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

- **Did the support land?** The signal differs per agent, and on Claude it changed in this release.
  - **`--agent=claude`** — there is no `[context-mode]` startup line any more, because riotbox no longer writes Claude's wiring. The plugin registration prints instead, on stdout: `  [plugins] Context Mode 1.0.169 registered at /home/llm/.riotbox/context-mode-plugin/v1.0.169.` **Do not read that line, or its absence, as the answer.** It is printed only by a call that changed the registry, and how often that happens depends on your host: with no `context-mode` under `~/.claude/plugins` it prints on the first run and then goes quiet, while with one mounted the host merge overwrites the entry every start and the line prints on every run — twice on the first. The definitive negative signal is on stderr instead: `  [context-mode] WARN: no Context Mode plugin is installed and enabled in this session`. To check a quiet session directly, look for the plugin: `riotbox run "/context-mode:ctx-doctor"`, or `jq '.plugins["context-mode@context-mode"]' ~/.local/share/riotbox/<session>/.claude/plugins/installed_plugins.json`.
  - **`--agent=opencode`** — unchanged: `  [context-mode] opencode plugin shim wired at <path>.` on stderr.
  - **`--agent=pi`** — `  [context-mode] pi package wired in /home/llm/.pi/agent/settings.json.` on stderr.

  Either way, every give-up path explains itself on **stderr** as `[context-mode] WARN:` or `[plugins] WARNING:` — streams an autonomous run usually discards. Re-run capturing them: `RIOTBOX_CONTEXT_MODE=1 riotbox run "…" 2>/tmp/rb.err; grep -E 'context-mode|Context Mode' /tmp/rb.err`. Most common causes: the selected agent has no Context Mode support in riotbox (the warning names it), the session config could not be written, the image is older than the plugin-staging layer and staged nothing (`riotbox doctor` catches that one and tells you to rebuild), or — on opencode — `--pure` was on the command line, which disables external plugins outright.
- **Is the exit report zero rather than absent?** `this run 0 B kept out · 8.0 KB hook log on disk` means the hooks ran and withheld nothing — the feature engaged and saved nothing. The hook-log figure is disk volume, not tokens. `bytesAvoided` only moves when the model actually routes large output through the sandbox tools; a session of small tool results has nothing to redirect. **No report at all** is the different problem, and it points back to the support check above.
- **Do not read `riotbox doctor` as proof the session works.** Its probe runs the image with `--entrypoint /usr/bin/bash`, which bypasses `container/entrypoint.sh` — the file where the per-session wiring actually happens. A green check proves the image ships a working `context-mode`, that it carries a staged plugin tree a session could register, and that the agent you selected has Context Mode support at all — and nothing else about your session.
- **Compare against `context-mode statusline` and expect disagreement.** Upstream's headline divides `eventDataBytes` by 4 and calls the result saved tokens, so it reports a saving for a session that saved nothing. RiotBox reports `bytesAvoided` alone.

### Session directory owned by wrong UID

**Symptom**: `Permission denied` errors writing to `~/.local/share/riotbox/` or `~/.local/share/riotbox-state/`.

**Cause**: a previous container run without `--userns=keep-id` (or with broken userns) caused files to be created with a subordinate UID. For the session directory, `mount-projects.sh` detects this and exits with an error message; the state directory has no such check, so a wrong owner there shows up as a `chmod` or `Permission denied` error at launch. Fix manually:

```sh
sudo chown -R $(id -u):$(id -g) ~/.local/share/riotbox/ ~/.local/share/riotbox-state/
```

### Build fails with permission denied

**Symptom**: `mkdir: cannot create directory '/home/llm/.cache/...': Permission denied` during build.

**Cause**: the multi-stage Containerfile copies security tools and installs semgrep as root, which creates directories under `/home/llm/` with root ownership. The Containerfile includes a `chown -R llm:llm /home/llm` step after these installs. If you modify the Containerfile and add root-stage installs after this chown, you'll hit this error. Always ensure the chown runs after all root-stage operations.

### IPv6 warnings in system journal

**Symptom**: `NetworkManager` logs IPv6 permission errors when containers start.

**Cause**: IPv6 is disabled on the host but podman's network stack creates veth interfaces that trigger NetworkManager's IPv6 configuration. These are cosmetic warnings and do not affect container operation.
