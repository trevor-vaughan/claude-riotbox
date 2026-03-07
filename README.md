# Claude Riotbox - Letting Claude run Wild

---

> 🤖 LLM/AI WARNING 🤖
>
> This project was largely written by [Claude](https://claude.ai/).
> It has been reviewed and tested, but use in production at your own
> discretion.
>
> 🤖 LLM/AI WARNING 🤖

---

Container-based isolation for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) autonomously against your projects. The container mirrors your host dev environment (nvm, uv, Go, Rust, Ruby) so Claude has the same toolchain you do, but runs isolated from your credentials and secrets.

> **Security:** This project has an AI-generated [threat model](THREAT_MODEL.md) covering the container isolation boundary, auth handling, mount surface, and nested container mode. Read it before use.

## Why did I build this?

Claude has [Sandboxing](https://code.claude.com/docs/en/sandboxing), but I wanted the opposite of what that does. I wanted unbridled insanity, the ability to install whatever it needed, and the ability to map in multiple projects easily for complex coordinated development while I was sleeping.

I also use CentOS/RHEL and wanted something that would work natively in that environment.

Finally...it was fun!

## How it works

1. **`scripts/build.sh`** introspects your local environment (nvm, uv, Go, Rust/rustup, Ruby/RVM, UID, tool configs) and passes them as build args.
2. The **Dockerfile** uses a multi-stage build: a `tools` stage downloads standalone binaries (trivy, grype, syft, task, venom), and the `runtime` stage assembles the final CentOS Stream 10 image with all toolchains. Claude Code is installed last for optimal layer caching.
3. At runtime your project directory is bind-mounted into the container. Auth credentials (`~/.claude.json`, `~/.claude/.credentials.json`) are copied — not mounted — into an isolated session directory so multiple containers can run concurrently without file contention.
4. A **wrapper script** shadows the `claude` binary to add autonomous-mode flags and a system prompt with commit discipline guidelines.

## Prerequisites

- [Podman](https://podman.io/) or Docker (podman preferred, auto-detected)
- [task](https://taskfile.dev) command runner
- [fuse-overlayfs](https://github.com/containers/fuse-overlayfs) (required for podman — see [Podman setup](#podman-setup))
- One of:
  - `ANTHROPIC_API_KEY` environment variable, **or**
  - `~/.claude.json` with OAuth tokens (created by running `claude` on the host and completing the OAuth flow)

- [git-filter-repo](https://github.com/newren/git-filter-repo) (required for `reown` — `pip install git-filter-repo`)
- (Optional) nvm, uv, Go, rustup, RVM installed locally — the build mirrors whatever it finds

## Setup

The quickest way to get started is the guided setup script:

```sh
./setup.sh
```

This checks prerequisites, configures podman, installs the CLI, and builds the image. It's idempotent — safe to re-run if you need to fix something.

### Manual setup

If you prefer to set things up yourself:

1. Install the `claude-riotbox` command:

   ```sh
   ./install.sh            # installs to ~/bin (default)
   ./install.sh ~/.local/bin   # or pick a different directory
   ```

2. Configure podman (see [Podman setup](#podman-setup))

3. Build the image:

   ```sh
   claude-riotbox build
   ```

## Quick start

```sh
cd /path/to/your/project

# Run Claude autonomously against the current directory
claude-riotbox run "add tests for the auth module"

# Or specify a project directory explicitly
claude-riotbox run "fix lint errors" /path/to/other/project

# Interactive shell in the riotbox
claude-riotbox shell

# After a run, rewrite Claude's commits to use your identity
claude-riotbox reown
```

## Commands

| Command | Description |
|---|---|
| `claude-riotbox build` | Introspect host environment and build the container image |
| `claude-riotbox rebuild` | Force a clean rebuild with no layer cache |
| `claude-riotbox run "<task>" [dir]` | Run Claude autonomously (defaults to current directory) |
| `claude-riotbox shell [dir]` | Interactive shell (defaults to current directory) |
| `claude-riotbox clean` | Remove the riotbox image |
| `claude-riotbox reown` | Rewrite Claude-authored commits to your git identity |
| `claude-riotbox reown <ref>` | Rewrite only commits since a specific ref |
| `claude-riotbox reown --all` | Rewrite all Claude-authored commits on the current branch |
| `claude-riotbox mounts` | Show auto-detected mounts (useful for debugging) |
| `claude-riotbox nested-run "<task>" [dir]` | Run with podman-in-podman support (disables SELinux) |
| `claude-riotbox nested-shell [dir]` | Shell with podman-in-podman support (disables SELinux) |
| `claude-riotbox backups` | List available project backups |
| `claude-riotbox restore <name>` | Show recovery options for a backed-up project |

## Pre-installed tools

The image comes with a broad set of tools pre-installed so Claude can start working immediately without spending time on setup.

**Development toolchains** (auto-detected from your host):
- Node.js (via nvm), Python/uv, Rust/cargo, Go, Ruby/RVM

**Security scanners:**
- [trivy](https://github.com/aquasecurity/trivy), [grype](https://github.com/anchore/grype), [syft](https://github.com/anchore/syft), [semgrep](https://semgrep.dev/), ShellCheck

**Testing:**
- [bats](https://github.com/bats-core/bats-core) (bash testing)

**Diagram validation:**
- `plantuml` — UML diagram generation and validation
- `mmdc` ([mermaid-cli](https://github.com/mermaid-js/mermaid-cli)) — Mermaid diagram rendering

**Containers:**
- podman, fuse-overlayfs, slirp4netns (for nested container support)

## Plugins

Claude Code [plugins](https://docs.anthropic.com/en/docs/claude-code/plugins) (skills, LSP servers, etc.) are pre-installed at image build time and copied into each session on first run. The plugin list is defined in the `Dockerfile` — edit the staging `RUN` block and rebuild to customize.

**Skills** from your host `~/.claude/skills/` are copied into the session directory at every launch, so newly installed skills are available immediately. Symlinks are dereferenced during copy. Removed or renamed skills persist in the session cache — run `claude-riotbox session:reset-session` to clear stale entries.

## Auto-detected mounts

At runtime, `scripts/detect-mounts.sh` generates mount flags for the container. This uses an allowlist — only explicitly listed paths are ever mounted.

**Functional** (required for operation):

| Host path | Container path | How |
|---|---|---|
| `~/.claude-riotbox/<session>/` | `~/.claude` | bind mount (`:z`) |
| `~/.claude.json`, `~/.claude/.credentials.json` | copied into session dir | file copy |
| `~/.claude/skills/` | copied into session dir | file copy (symlinks dereferenced) |
| `~/bin` | `~/bin` | bind mount (read-only) |

Riotbox sessions are isolated from your host `~/.claude` — it is never mounted. Auth files are copied (not mounted) so each container gets its own writable copy, avoiding file contention with concurrent runs.

**Package caches** (named volumes, shared across containers):

| Volume | Container path |
|---|---|
| `claude-cache-npm` | `~/.npm` |
| `claude-cache-cargo` | `~/.cargo/registry` |
| `claude-cache-go` | `~/go/pkg` |
| `claude-cache-pip` | `~/.cache/pip` |
| `claude-cache-uv` | `~/.cache/uv` |
| `claude-cache-bundler` | `~/.bundle/cache` |
| `claude-cache-m2` | `~/.m2/repository` |
| `claude-cache-gradle` | `~/.gradle/caches` |
| `claude-cache-bun` | `~/.bun/install` |

Package caches use named podman/docker volumes rather than bind mounts. This avoids SELinux relabeling overhead — bind-mounting gigabytes of cache with `:z` causes recursive `chcon` on every container start, which can take minutes. Named volumes get `container_file_t` automatically. The tradeoff is that caches are not shared with the host.

Sensitive directories (`.ssh`, `.gnupg`, `.kube`, `.aws`, etc.) are never mounted. Run `claude-riotbox mounts` to see what would be mounted for your system.

## Claude wrapper

Inside the container, `claude` is a wrapper script (`container/claude-wrapper.sh`) that shadows the npm-installed binary. It automatically:

- Passes `--dangerously-skip-permissions` — this is safe here because the container **is** the riotbox. Claude can't escape to the host, and the mounted project directory has a git checkpoint for easy rollback.
- Appends a system prompt instructing Claude to install whatever it needs, commit regularly, and perform a security/sanity/DRY/maintainability review before every commit.

## Nested containers (podman-in-podman)

If Claude needs to build or run containers (e.g., testing Dockerfiles, running docker-compose stacks), use the nested variants:

```sh
claude-riotbox nested-run "build and test the Dockerfile"
claude-riotbox nested-shell
```

This passes `--device /dev/fuse` and `--security-opt label=disable` to the outer container, enabling rootless podman inside the riotbox. The image includes podman, fuse-overlayfs, and slirp4netns pre-installed with proper subuid/subgid mappings.

> **WARNING:** Nested mode disables SELinux confinement on the outer container. This is a meaningful reduction in host isolation — the container processes are no longer confined by SELinux policy. Only use this when Claude actually needs container capabilities.

You can also enable nested mode on any command via the environment variable:

```sh
RIOTBOX_NESTED=1 claude-riotbox shell
```

## Reclaiming authorship

After a riotbox run, Claude's commits will have the container's git identity. Use `claude-riotbox reown` from the project directory to rewrite those commits with your name and email (read from your `~/.gitconfig`). The `run` command auto-creates a checkpoint commit before launching Claude, which `reown` uses to determine the rewrite range.

```sh
cd /path/to/project
claude-riotbox reown              # rewrites since the last checkpoint
claude-riotbox reown abc123       # rewrites since a specific commit
claude-riotbox reown --all        # rewrites all claude-authored commits on current branch
```

> **Note:** This uses `git filter-repo` under the hood, which rewrites commit hashes. Only use this on commits that haven't been pushed to a shared remote, or be prepared to force-push. A backup tag (`backup/pre-reown-<timestamp>`) is created before rewriting — use `git diff <backup-tag>..<branch>` to verify the result.

## What could go wrong

Claude runs autonomously with full write access to your project directory and passwordless sudo inside the container. This is powerful but comes with real risks:

- **Claude can delete your entire project and start over.** It may decide your codebase is too messy to fix and `rm -rf` everything. This has happened.
- **Claude can rewrite git history.** Force-pushes, rebases, and `git reset --hard` are all available.
- **Claude can install arbitrary packages** via dnf, npm, pip, cargo, etc. These run inside the container and can't affect the host, but they can affect the project.
- **Claude can make sweeping refactors** that look correct but subtly break things. Always review changes before merging.
- **Multiple riotbox runs on the same project can conflict** if run concurrently without separate branches.

### Built-in protections

The riotbox includes several layers of protection, but none are foolproof:

- **Local bare backup**: Before every `run`, all refs and tags are pushed to a bare clone at `~/.claude-riotbox/backups/<project>.git`. This backup lives outside the container's mount tree — Claude cannot access or modify it. Even if Claude deletes every file and rewrites all history, the backup is intact.
- **Checkpoint tags**: A git tag (`claude-checkpoint/<timestamp>`) is created on the current HEAD before each run. Tags survive history rewrites inside the container.
- **Session branches**: On `shell` and `launch` sessions, the container offers to create a `riotbox/<id>` branch. Claude works there; on exit the branch is fast-forward merged back so the full commit history lands seamlessly on your branch. See [Session branches](#session-branches).
- **Non-git-repo warning**: If a project directory isn't a git repo, the riotbox warns you that there's no checkpoint protection.
- **Git guardrails**: Inside the container, `receive.denyNonFastForwards` and `receive.denyDeletes` are enabled to prevent the most destructive git operations.
- **Container isolation**: Claude can't access your SSH keys, cloud credentials, or anything outside the mounted directories.

### Recovery

If Claude makes a mess, you have several recovery options:

```sh
# List available backups and their checkpoints
claude-riotbox backups

# Show recovery instructions for a specific project
claude-riotbox restore my-project

# Fetch everything from the backup into your project
cd /path/to/my-project
git fetch ~/.claude-riotbox/backups/my-project.git --all --tags
git reset --hard claude-checkpoint/<timestamp>

# Or clone a fresh copy from the backup
git clone ~/.claude-riotbox/backups/my-project.git my-project-restored
```

### Session branches

When you start an interactive session (`claude-riotbox shell` or `claude-riotbox launch`) against a single-repo workspace, the container prompts you to create a session branch:

```
  Git repo detected on branch 'main'.
  Create session branch 'riotbox/20260309-143022-a1b2c3d4'? [y/N]
```

If you say yes, Claude works on `riotbox/<id>` instead of your current branch. On clean exit, the session branch is fast-forward merged back so all commits land directly on your branch with their original messages and timestamps:

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

| Value | Behavior |
|---|---|
| *(unset)* | Prompt at session start (default for `shell`/`launch`) |
| `SESSION_BRANCH=1` | Auto-create, no prompt |
| `SESSION_BRANCH=0` | Skip silently (default for `run`) |

```sh
SESSION_BRANCH=1 claude-riotbox shell   # always create a session branch
SESSION_BRANCH=0 claude-riotbox shell   # never create one
```

Session branching is automatically disabled for `claude-riotbox run` (non-interactive) since those runs are scripted and already checkpoint before starting.

### Recommendations

- **Always use git repos.** The checkpoint and backup mechanisms are your primary safety net.
- **Push to a remote before running Claude.** Belt and suspenders.
- **Review changes before merging.** Use `git diff claude-checkpoint/<tag>..HEAD` to see everything Claude did.
- **Use branches.** Run Claude on a feature branch, not main. Session branching automates this.

## Security model

### What's exposed to the container

| Resource | Access | Notes |
|---|---|---|
| Project directory | read-write bind mount (`:z`) | Your code — Claude needs full access |
| Session data (`~/.claude-riotbox/`) | bind mount (`:z`) | Isolated per project set |
| Auth credentials | file copy into session dir | Not bind-mounted — each container gets its own copy |
| User scripts (`~/bin`) | read-only bind mount | Available but not writable |
| Package caches | named volumes | Shared across containers, not with host |
| Network | enabled | Claude needs npm/PyPI/crates.io etc. |

### What's NOT exposed

`~/.ssh`, `~/.gnupg`, `~/.kube`, `~/.aws`, `~/.claude` (host conversations), cloud credentials, and anything not explicitly listed above. The `.dockerignore` also blocks secrets (`.env`, `*.pem`, `*.key`, etc.) from being baked into the image.

### Other design choices

- **Sudo**: the container user has passwordless `sudo`. Claude often needs to `dnf install` build dependencies, and the container is disposable. This does **not** grant any host privileges.
- **UID mapping**: the container user's UID matches your host UID. With podman, `--userns=keep-id` preserves this mapping in rootless mode, requiring `fuse-overlayfs` for acceptable performance on large images.
- **SELinux**: project and session bind mounts use `:z`. Package caches use named volumes to avoid relabeling overhead. Auth files are copied rather than mounted to avoid permission issues with `:z` on 600-permission files.
- **Tool configs** (`.npmrc`, `.editorconfig`, etc.) are copied at build time — not mounted — so edits inside the container don't affect the host.
- **Nested containers**: `RIOTBOX_NESTED=1` passes `--device /dev/fuse` and `--security-opt label=disable`. This disables SELinux confinement — the container is no longer restricted by SELinux policy. Only used when explicitly requested via `nested-run`/`nested-shell`.

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
claude-riotbox build
```

### Recommended: containers.conf

Create `~/.config/containers/containers.conf`:

```toml
[containers]
init = false
```

This disables catatonit (podman's default init process), which segfaults on EL10 (`catatonit-0.2.1-3.el10`). The riotbox image has its own entrypoint that handles signal forwarding.

### Optional: enable metacopy at the kernel level

For faster overlay operations, enable metacopy in the kernel:

```sh
# Enable now
echo "Y" | sudo tee /sys/module/overlay/parameters/metacopy

# Persist across reboots
echo "options overlay metacopy=on" | sudo tee /etc/modprobe.d/overlay.conf
```

## Troubleshooting

### Container startup hangs

**Symptom**: `claude-riotbox .` or `podman run` hangs indefinitely.

**Likely causes**:
1. **Missing fuse-overlayfs** — `--userns=keep-id` without fuse-overlayfs triggers a full ID-mapped layer copy on the ~8 GB image. Install fuse-overlayfs and configure storage.conf (see [Podman setup](#podman-setup)).
2. **SELinux relabeling** — bind-mounting large directories with `:z` causes recursive `chcon`. This was the original cause with cache directories (now using named volumes). If you add custom bind mounts, avoid `:z` on large trees.
3. **catatonit segfault** — check `journalctl --user -xe` for catatonit crashes. Set `init = false` in containers.conf.

**Diagnosis**: run with increasing complexity to isolate the issue:
```sh
# Bare minimum — does the image work?
podman run --rm -it localhost/claude-riotbox echo hello

# Add userns — does ID mapping work?
podman run --rm -it --userns=keep-id localhost/claude-riotbox echo hello

# Add project mount — does SELinux allow it?
podman run --rm -it --userns=keep-id -v $PWD:/workspace:z localhost/claude-riotbox echo hello

# Full mount set — which mount causes the hang?
podman run --rm -it --userns=keep-id $(scripts/detect-mounts.sh) localhost/claude-riotbox echo hello
```

### Claude Code hangs on startup

**Symptom**: container starts, but `claude` shows a blank screen or hangs.

**Likely causes**:
1. **Telemetry/update checks** — Claude Code tries to reach external services on startup. The entrypoint sets `DISABLE_TELEMETRY=1`, `DO_NOT_TRACK=1`, and `CLAUDE_CODE_SKIP_UPDATE_CHECK=1` to prevent this. If you're running claude directly (not via the entrypoint), set these manually.
2. **Auth file write failure** — Claude Code writes back to `~/.claude.json` on startup. If the file is read-only or on a read-only mount, Claude hangs in a retry loop. Auth files are now copied into the session directory to avoid this.
3. **Missing directories** — Claude Code expects `~/.claude/debug/` and `~/.claude/plugins/cache/` to exist. The entrypoint creates these, but if permissions are wrong they may silently fail. Check with `ls -la ~/.claude/` inside the container.

**Diagnosis**: check the debug log inside the container:
```sh
cat ~/.claude/debug/latest
```

### "Not logged in" inside the container

**Symptom**: Claude Code starts but says you're not logged in.

**Cause**: auth credentials aren't reaching the container. The riotbox copies `~/.claude.json` and `~/.claude/.credentials.json` from the host into the session directory before each run.

**Check**:
- Verify the files exist on the host: `ls -la ~/.claude.json ~/.claude/.credentials.json`
- Verify the session directory is writable: `ls -la ~/.claude-riotbox/`
- If the session directory is owned by a numeric UID (e.g., 525287), a previous run without `--userns=keep-id` left it with wrong ownership. Fix with: `sudo chown -R $(id -u):$(id -g) ~/.claude-riotbox/`

### Session directory owned by wrong UID

**Symptom**: `Permission denied` errors writing to `~/.claude-riotbox/`.

**Cause**: a previous container run without `--userns=keep-id` (or with broken userns) caused files to be created with a subordinate UID. The mount-projects.sh script detects this and exits with an error message. Fix manually:

```sh
sudo chown -R $(id -u):$(id -g) ~/.claude-riotbox/
```

### Build fails with permission denied

**Symptom**: `mkdir: cannot create directory '/home/claude/.cache/...': Permission denied` during build.

**Cause**: the multi-stage Dockerfile copies security tools and installs semgrep as root, which creates directories under `/home/claude/` with root ownership. The Dockerfile includes a `chown -R claude:claude /home/claude` step after these installs. If you modify the Dockerfile and add root-stage installs after this chown, you'll hit this error. Always ensure the chown runs after all root-stage operations.

### IPv6 warnings in system journal

**Symptom**: `NetworkManager` logs IPv6 permission errors when containers start.

**Cause**: IPv6 is disabled on the host but podman's network stack creates veth interfaces that trigger NetworkManager's IPv6 configuration. These are cosmetic warnings and do not affect container operation.
