# Adding a new CLI agent to the riotbox

This document is for maintainers who want to add a third (or fourth, or
fifth) CLI agent alongside `claude` and `opencode` — for example
[aider](https://aider.chat/), [goose](https://block.github.io/goose/),
[cursor-agent](https://docs.cursor.com/cli), or [codex](https://github.com/openai/codex).

Adding an agent is a **single-directory operation**. You drop a new manifest
under `agents/`, register the name, install the binary in the Dockerfile,
and you're done — no edits to dispatch sites, wrappers, or test fixtures.

## TL;DR — the three steps

1. **Install the binary** in the Dockerfile (one `RUN` line).
2. **Create `agents/<name>/`** with at minimum a `manifest.sh` that
   defines the contract functions (eight of them, each a handful of
   lines). Add `setup.sh` for container-side runtime setup and
   `sync-settings.sh` for host config sync if your agent needs them.
   Use `agents/claude/` or `agents/opencode/` as a template.
3. **Run `task lint && task test`** — the contract suite at
   `tests/agents.venom.yml` automatically validates the new manifest.

That's it. The registry **auto-discovers** any directory under `agents/`
that contains a `manifest.sh`, so you don't need to edit any list. The
wrapper, all dispatch sites, install.sh's `--agent` validation, the
entrypoint's setup loop, and `mount-projects.sh`'s sync loop pick up the
new agent automatically.

**Discovery rules:**
- Subdirectories without `manifest.sh` are silently skipped (drafts,
  scaffolding, tooling).
- Directories whose names start with `_` or `.` are skipped (templates,
  hidden state).
- Iteration order is the shell glob's lexical order — stable across runs.

## Layout per agent

```
agents/<name>/
  manifest.sh        ← required: contract functions
  setup.sh           ← optional: container-side runtime setup
  sync-settings.sh   ← optional: host-side config sync
```

The registry sources `agents/<name>/manifest.sh`. The manifest decides
whether to source `setup.sh` (from `container_setup`) and whether to
exec `sync-settings.sh` (from `host_sync`). Files outside `manifest.sh`
are agent-private — the rest of the system never references them.

## The agent contract

Every `agents/<name>/manifest.sh` must define this fixed set of
functions. The function names are mechanical: `agent_<name>_<verb>`.

### `agent_<name>_real_binary`

```bash
agent_<name>_real_binary() {
    printf '<binary-on-PATH>\n'
}
```

Print the name of the agent's binary as it appears on PATH inside the
container. The generic wrapper in `container/agent-wrapper.sh` uses this
name (via `find-real-bin.sh`) to resolve the real binary, skipping the
riotbox shim at `~/.riotbox/bin/`.

### `agent_<name>_run_argv "$prompt"`

```bash
agent_<name>_run_argv() {
    local prompt="${1:?run_argv requires a prompt argument}"
    printf '%s\0' <binary> <flags...> "${prompt}"
}
```

Print the argv (one NUL-terminated token per write) for non-interactive
"run with prompt" mode. Examples:

| Agent      | argv tokens                              |
|------------|------------------------------------------|
| `claude`   | `claude`, `-p`, `<prompt>`               |
| `opencode` | `opencode`, `run`, `<prompt>`            |

The caller does `mapfile -d '' -t argv < <(agent_call <name> run_argv
"$prompt")` and `exec` from there. NUL framing keeps multi-line argv
tokens (e.g. a `-p` prompt with embedded newlines) intact; argv tokens
cannot contain NUL bytes by the `execve(2)` contract.

### `agent_<name>_resume_argv`

```bash
agent_<name>_resume_argv() {
    printf '%s\0' <binary> <continue-flags...>
}
```

Print the argv to resume the most recent session in the current project.
Examples: `claude --continue`; `opencode run --continue`.

### `agent_<name>_audit_argv "$prompt"`

```bash
agent_<name>_audit_argv() {
    local prompt="${1:?audit_argv requires a prompt argument}"
    printf '%s\0' <binary> <flags...> "${prompt}"
}
```

Print the argv for read-only audit mode. The launcher already configures
`RIOTBOX_READONLY=1` so the project mount is read-only — `audit_argv`
typically returns the same tokens as `run_argv`.

### `agent_<name>_wrapper_inject "$@"`

```bash
agent_<name>_wrapper_inject() {
    # Read the user's argv as positional parameters.
    # Print the rewritten argv on stdout (NUL-terminated tokens).
    # Print the literal string "CI=1" on stderr if CI=true should be set.
    ...
}
```

This is the only function with non-trivial logic. It's called by
`container/agent-wrapper.sh` to decide:

- **What flags to inject** (e.g. `--dangerously-skip-permissions`)
- **Where to inject them** (claude: at the root; opencode: after the
  `run` subcommand only)
- **When to set `CI=true`** (claude: when `-p`/`--prompt` is present;
  opencode: when `run` is present)

The contract is:

- Read the user's argv from `"$@"`.
- Write the rewritten argv to stdout as NUL-terminated tokens
  (`printf '%s\0' <token>`); the wrapper reads them with
  `mapfile -d ''`. NUL framing preserves multi-line argv tokens.
- Optionally write the literal string `CI=1` to stderr to signal that
  the wrapper should `export CI=true`.
- Any other stderr output is forwarded to the user as a notice/error.

See `agents/claude/manifest.sh` and `agents/opencode/manifest.sh` for two
complete implementations.

### `agent_<name>_container_setup`

```bash
agent_<name>_container_setup() {
    :   # no-op if nothing runtime-side to do
}
```

Called by `container/entrypoint.sh` on every container start. Use this for
agents that need runtime config placement (e.g. opencode's
`opencode-setup.sh` writes `AGENTS.md` and `opencode.json`). For agents
whose config is fully baked at build time (e.g. claude's managed-policy
`/etc/claude-code/CLAUDE.md`), this is a no-op.

If your agent has runtime setup, place its body in
`container/<name>-setup.sh` and have `agent_<name>_container_setup` source
it and call its main function — that keeps long setup bodies out of the
manifest.

### `agent_<name>_host_sync "$session_dir"`

```bash
agent_<name>_host_sync() {
    local session_dir="${1:?host_sync requires a session_dir argument}"
    "${_AGENT_<NAME>_DIR}/sync-settings.sh" \
        "${HOME}/.config/<name>" \
        "${session_dir}"
}
```

Called by `scripts/mount-projects.sh` on the host. Should:

- Copy whatever the agent needs from `${HOME}` into the session directory.
- Print `-v` flags on stdout (one per line) for the container runtime to
  bind-mount the session-dir copies into the container's filesystem.
- Print notices on stderr if the host has no config to sync.
- Empty stdout is allowed (means "nothing to mount").

If the agent has no host config story (e.g. it reads everything from env
vars and never persists state), make this a no-op:

```bash
agent_<name>_host_sync() {
    :
}
```

### `agent_<name>_env_vars`

```bash
agent_<name>_env_vars() {
    cat <<'EOF'
PROVIDER_KEY_VAR
ANOTHER_VAR
EOF
}
```

Print the env var **names** this agent reads — one per line, no values.
The launcher (`.taskfiles/scripts/passthrough-vars.sh`) sources the
registry, calls this verb on every registered agent, dedupes the union
with `sort -u`, and emits `-e <NAME>` for each name whose value is set
on the host. Adding a new provider key for an agent is a one-line edit
to its manifest — no central list to maintain.

Constraints:

- Names only. No `=value` pairs. The container runtime copies the value
  from the caller's environment, which keeps secrets out of process argv.
- One per line. Env var names cannot contain whitespace or NULs, so
  newline framing is unambiguous and round-trips through `mapfile -t`.
- Return at least one name (the contract test asserts it). An agent
  that genuinely reads no env vars is rare; if you have one, put a
  single innocuous routing var there or revisit the design.
- Excluded by policy: AWS access keys (`AWS_ACCESS_KEY_ID` etc.) and
  `SSH_AUTH_SOCK`. See `THREAT_MODEL.md`. Use credential-file mounts
  (`RIOTBOX_CREDFILE_VARS`) for AWS instead.

Users can still override the registry-derived default with
`RIOTBOX_PASSTHROUGH_VARS` (whitespace-separated) for power-user setups
that want a curated list.

## Worked example: adding `aider`

Suppose [aider](https://aider.chat/) is your third agent. Here's the
complete diff:

### 1. Install in Dockerfile

```dockerfile
# Aider — Python-based pair-programming agent
RUN pip install --no-cache-dir --break-system-packages aider-install && \
    aider-install && aider --version
```

### 2. Manifest at `agents/aider/manifest.sh`

```bash
#!/usr/bin/env bash
_AGENT_AIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

agent_aider_real_binary() { printf 'aider\n'; }

agent_aider_run_argv() {
    local prompt="${1:?run_argv requires a prompt argument}"
    # aider takes a prompt via --message and exits non-interactively
    # with --no-stream, --yes-always for autonomy.
    printf '%s\0' aider --message "${prompt}" --no-stream --yes-always
}

agent_aider_resume_argv() {
    # aider has no native "resume" — opening it without a prompt picks
    # up the local repo state.
    printf '%s\0' aider --no-stream --yes-always
}

agent_aider_audit_argv() {
    local prompt="${1:?audit_argv requires a prompt argument}"
    printf '%s\0' aider --message "${prompt}" --no-stream --yes-always
}

agent_aider_wrapper_inject() {
    # aider's --yes-always disables interactive prompts; the run_argv
    # already passes it. The wrapper itself only needs to scan for
    # --message to decide CI=true.
    local set_ci=0 arg
    for arg in "$@"; do
        if [ "${arg}" = "--message" ]; then set_ci=1; break; fi
    done
    for arg in "$@"; do printf '%s\0' "${arg}"; done
    [ "${set_ci}" = "1" ] && echo "CI=1" >&2
    return 0
}

agent_aider_container_setup() { :; }   # no runtime setup needed

agent_aider_host_sync() {
    local session_dir="${1:?host_sync requires a session_dir argument}"
    # aider reads ~/.aider.conf.yml; copy it into the session dir if
    # present, otherwise no-op.
    if [ -f "${HOME}/.aider.conf.yml" ]; then
        cp "${HOME}/.aider.conf.yml" "${session_dir}/.aider.conf.yml"
        echo "-v ${session_dir}/.aider.conf.yml:/home/claude/.aider.conf.yml:z"
    fi
}

agent_aider_env_vars() {
    # Provider keys aider reads upstream. Listing each candidate up front
    # lets users switch backends without re-editing this manifest.
    cat <<'EOF'
ANTHROPIC_API_KEY
OPENAI_API_KEY
DEEPSEEK_API_KEY
GEMINI_API_KEY
EOF
}
```

### 3. Run the tests

The registry auto-discovers `agents/aider/manifest.sh` — no edit to
`registry.sh` is needed.

```sh
task lint && task test ARGS=agents
```

The registry contract suite at `tests/agents.venom.yml` automatically
validates `aider` against every contract check — `real_binary`,
`run_argv`, `resume_argv`, `audit_argv`, `container_setup`,
`wrapper_inject`, `host_sync`, `env_vars`, plus the dispatcher's
reject-unknown behaviour.

That's the whole change. No edits to:

- `install.sh` — the wrapper sources `agents/registry.sh` at runtime.
- `.taskfiles/scripts/run.sh`, `resume.sh`, `audit.sh` — they call
  `agent_call "$RIOTBOX_AGENT" <verb>`.
- `container/agent-wrapper.sh` — it dispatches by `basename($0)`.
- `container/entrypoint.sh` — it loops over `AGENT_REGISTRY`.
- `scripts/mount-projects.sh` — it loops over `AGENT_REGISTRY`.
- `Dockerfile` (apart from the install step) — the symlink loop reads
  `AGENT_REGISTRY` directly.

## Things to avoid

- **Don't break the contract.** If a new manifest skips a function, the
  registry tests fail loudly. Don't `# shellcheck disable=...` your way
  past missing functions.
- **Don't add agent-specific dispatch outside the registry.** If you're
  about to write a `case "$RIOTBOX_AGENT" in <name>) ... ;; esac`, stop
  and put the logic in the manifest. The whole point of the refactor is
  that there is one place to look up agent behaviour.
- **Don't overload the manifest with unrelated logic.** Keep it focused
  on the contract. Long setup bodies belong in `container/<name>-setup.sh`
  (sourced by `container_setup`); long sync logic in
  `scripts/sync-<name>-settings.sh` (called by `host_sync`).

## Where to look when something breaks

| Symptom                                           | Where to look                       |
|---------------------------------------------------|-------------------------------------|
| `--agent=<new>` rejected with "must be one of"   | Does `agents/<new>/manifest.sh` exist? The host wrapper sources the registry at runtime, so no re-install is needed. |
| `task run` exits with "unknown verb"             | Manifest is missing `agent_<name>_run_argv` |
| Wrapper invokes wrong binary                      | Check `agent_<name>_real_binary` and PATH order |
| `--dangerously-skip-permissions` in wrong place   | Bug in `agent_<name>_wrapper_inject`; see opencode for subcommand-local injection |
| Container fails to start with "no agents discovered" | The `COPY agents/` in the Dockerfile didn't run, or every subdirectory is missing `manifest.sh` |
| Host config not synced                            | `agent_<name>_host_sync` is a no-op or its sync script is missing |

Run `task test ARGS=agents` to re-exercise the contract suite at any
time — it's the fastest signal that a manifest is well-formed.
