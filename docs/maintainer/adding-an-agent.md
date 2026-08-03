# Adding a new CLI agent to RiotBox

This document is for maintainers who want to add a third (or fourth, or
fifth) CLI agent alongside `claude` and `opencode` — for example
[aider](https://aider.chat/), [goose](https://block.github.io/goose/),
[cursor-agent](https://docs.cursor.com/cli), or [codex](https://github.com/openai/codex).

Adding an agent is a **single-directory operation**. You drop a new manifest
under `agents/`, register the name, install the binary in the Containerfile,
and you're done — no edits to dispatch sites, wrappers, or test fixtures.

## TL;DR — the three steps

1. **Install the binary** in the Containerfile (one `RUN` line).
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
  context-mode.sh    ← optional: Context Mode verbs (sourced by manifest.sh)
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

| Agent      | argv tokens                   |
|------------|-------------------------------|
| `claude`   | `claude`, `-p`, `<prompt>`    |
| `opencode` | `opencode`, `run`, `<prompt>` |

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
    # Append KEY=VAL lines to "${RIOTBOX_INJECT_ENV_FILE}" for env hints
    # (e.g. CI=true) the wrapper should export to the agent.
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
- For each env var the agent should see set, append a `KEY=VAL` line to
  the file pointed to by `${RIOTBOX_INJECT_ENV_FILE}` (the wrapper
  allocates a fresh tmpfile per call and exports the var before calling
  this function). The wrapper reads the file and exports each entry
  after the function returns.
- Stderr is reserved for user-facing diagnostics; nothing on stderr is
  parsed by the wrapper.

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
`agents/opencode/setup.sh` writes `AGENTS.md` and `opencode.json`). For agents
whose config is fully baked at build time (e.g. claude's managed-policy
`/etc/claude-code/CLAUDE.md`), this is a no-op.

If your agent has runtime setup, place its body in
`agents/<name>/setup.sh` and have `agent_<name>_container_setup` source
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
The launcher (`libexec/passthrough-vars.sh`) sources the
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
that want a curated list, or add to it without restating the base via
`RIOTBOX_PASSTHROUGH_EXTRA_VARS` (same syntax, appended after the base).

## Optional verbs

Beyond the eight required functions, a manifest may implement optional
verbs. The wrapper probes for them with `declare -F agent_<name>_<verb>`;
absence is never an error.

### `agent_<name>_headroom_argv "$@"`

Emits (NUL-terminated, like the other argv verbs) the command line the
wrapper execs instead of the real binary when `RIOTBOX_HEADROOM=1`. The
wrapper exports `RIOTBOX_HEADROOM_ACTIVE=1` first, so when the emitted
command eventually re-invokes the agent by name, the shim's second pass
takes the normal inject-and-exec path. Two shapes exist:

**Wrap-shaped** — for tools headroom supports natively
(`headroom wrap claude|codex|goose|…`):

```bash
agent_<name>_headroom_argv() {
	printf '%s\0' headroom wrap <real-binary> <flags...> --
	local arg
	for arg in "$@"; do
		printf '%s\0' "${arg}"
	done
}
```

A wrap-shaped verb MUST:

- start with `headroom wrap <real-binary>`,
- disable anything that downloads at session start (the claude manifest
  passes `--no-serena --no-context-tool` — the image is offline-after-build),
- place all caller args after a literal `--` (headroom's wrap subcommands
  define their own flags, e.g. `-p/--port`, that would otherwise swallow
  agent flags).

**Proxy-routed** — for tools headroom has no wrap subcommand for. Emit an
executable helper co-located in your agent's directory, followed by the
caller args verbatim:

```bash
agent_<name>_headroom_argv() {
	printf '%s\0' "${_AGENT_<NAME>_DIR}/headroom-exec.sh"
	local arg
	for arg in "$@"; do
		printf '%s\0' "${arg}"
	done
}
```

The helper owns whatever routing the tool needs and MUST:

- ensure `headroom proxy` is listening (reuse a live one, else spawn with
  `--memory --learn`, log to `~/.headroom/logs/proxy.log`, and wait for
  TCP readiness with a timeout),
- apply agent-specific routing only AFTER the proxy answers (opencode
  ignores `*_BASE_URL` env vars, so its helper injects
  `provider.{anthropic,openai}.options.baseURL` into the merged
  `opencode.jsonc`, never overriding a user-set baseURL),
- degrade to unwrapped on any failure — warn on stderr, leave config
  untouched, `exec <real-binary-name> "$@"`,
- end with `exec <real-binary-name> "$@"` so the shim's guarded second
  pass applies the agent's normal injection rules.

`agents/opencode/headroom-exec.sh` is the reference implementation.

Agents without the verb run unwrapped under `RIOTBOX_HEADROOM=1`, with a
warning on stderr.

Contract coverage lives in `tests/agents.venom.yml` ("Headroom optional
verb" cases), `tests/headroom.venom.yml` (wrapper gate, guard, and
fallbacks), and `tests/headroom-opencode.venom.yml` (proxy-routed helper
behavior).

### The Context Mode verbs

Five optional verbs wire [Context Mode](../../README.md#context-mode-opt-in)
for an agent. Four run per session; the fifth runs at image build time:

| Verb | When | Contract |
|------|------|----------|
| `context_mode_store_dir` | session start | Print this agent's absolute `CONTEXT_MODE_DIR` on stdout. No side effects. |
| `context_mode_data_dir` | session start | Print the absolute root this agent's `CONTEXT_MODE_DATA_DIR` pins. Implement only where the pin is otherwise missing. |
| `context_mode_wire` | session start | Write this agent's wiring. All-or-nothing: return 0 only when every artifact landed. |
| `context_mode_strip` | session start | Remove anything this agent's `context_mode_wire` could have written. Idempotent, always returns 0. |
| `context_mode_build_assert "$pkg_root"` | image build | Assert the upstream contract this agent's wiring depends on. Non-zero fails the build. |

Every caller probes with `declare -F agent_<name>_<verb>` before calling —
`container/context-mode-setup.sh` at session start, `scripts/preflight.sh`
for the `riotbox doctor` check, and the Context Mode layer in the
`Containerfile` for the build guard. An agent that implements none of them
is not an error: the session warns naming the agent, strips any wiring an
earlier session left in the same session directory, and runs with the
feature off.

They are a set rather than a menu. **Implementing `context_mode_wire`
obliges the agent to implement `context_mode_store_dir` and
`context_mode_strip` as well.** The orchestrator asks for the store path
*before* it wires and gives up when the answer is unusable, so a `wire`
without `store_dir` never runs; and every give-up path — including the ones
inside `wire` itself — calls the stripper, so a `wire` without `strip`
leaves wiring behind that nothing removes, for the life of a session
directory that outlives the image that wrote it.

`context_mode_data_dir` is the exception: it is per-agent by design and
Claude does not implement it. See its section below for when an agent needs
it.

Put the bodies in `agents/<name>/context-mode.sh` and have `manifest.sh`
source it:

```bash
# Context Mode verbs (optional contract — see docs/maintainer/adding-an-agent.md).
# shellcheck source=./context-mode.sh
source "${_AGENT_<NAME>_DIR}/context-mode.sh"
```

That keeps the upstream constants, the wiring that depends on them, and the
build guard that asserts them in one file. `agents/claude/context-mode.sh`
(hook stanzas plus an MCP server entry) and `agents/opencode/context-mode.sh`
(one generated plugin file) are the two worked examples, and they are
deliberately different shapes — the registry contract is about the
lifecycle, not about what wiring looks like.

#### `agent_<name>_context_mode_store_dir`

```bash
agent_<name>_context_mode_store_dir() {
    printf '%s\n' "${<NAME>_CONFIG_DIR:-${HOME}/.config/<name>}/context-mode"
}
```

Print the absolute path the session exports as `CONTEXT_MODE_DIR`, and do
nothing else — no `mkdir`, no writes, nothing that assumes the feature is
enabled. `container/context-mode-setup.sh` rejects an empty or relative
answer (warn, strip, run with the feature off) instead of exporting it:
upstream resolves a relative `CONTEXT_MODE_DIR` against whatever directory
the hook happened to start in, which is the user's project, so the store
would land in the repo being worked on.

Point it inside the agent's config directory, which riotbox replaces with
the session bind mount. The store holds verbatim tool output, so it has to
be somewhere `riotbox session-remove` deletes and somewhere that cannot
vanish onto the container overlay at exit.

#### `agent_<name>_context_mode_data_dir`

```bash
agent_<name>_context_mode_data_dir() {
    printf '%s\n' "${<NAME>_CONFIG_DIR:-${HOME}/.config/<name>}"
}
```

`CONTEXT_MODE_DIR` pins the `sessions/` and `content/` stores behind the
`ctx_*` tools, and nothing else. An agent whose Context Mode support runs as
an in-process plugin has a second store — the plugin's own session DB — and
upstream resolves that through the adapter's `getSessionDir()`, which reads
`CONTEXT_MODE_DATA_DIR` and otherwise falls back to the agent's config
directory. Implement this verb when riotbox does not already pin that
fallback:

- **Claude does not implement it.** `resolveClaudeConfigDir()` reads
  `CLAUDE_CONFIG_DIR`, which `container/entrypoint.sh` exports at the session
  bind mount, so the DB is already pinned and a second variable would only be
  one more thing for a future reader to explain.
- **opencode does.** `OpenCodeAdapter.getConfigDir()` reads
  `XDG_CONFIG_HOME`, which the image never sets, and falls back to
  `~/.config/opencode`. That is the session mount today, but by coincidence
  rather than by anything riotbox stated — and the DB holds verbatim tool
  output, so an upstream change to that fallback would move it onto the
  container overlay, where it vanishes at exit and escapes
  `riotbox session-remove`.

**Print the parent of `context_mode_store_dir`'s path, not the same path.**
Upstream builds the DB directory as `<root>/context-mode/sessions`, whereas
`CONTEXT_MODE_DIR` names that `context-mode` directory outright. Returning
the store path here puts the DB at `<store>/context-mode/sessions`, one level
below the `ctx_*` stores instead of beside them.
`container/context-mode-setup.sh` rejects an empty or relative answer the
same way it rejects one from `store_dir`, and validates both before it
exports either, so a session that gives up leaves no storage variable behind.

Note that upstream's `getMemoryDir()` follows this root too: auto-memory
moves from `<config>/memory` to `<config>/context-mode/memory`. That is
harmless for an agent adopting Context Mode for the first time and worth
checking for one that has been storing memory under the old path.

#### `agent_<name>_context_mode_wire`

Write whatever form of wiring this agent needs, and return 0 **only** when
every artifact landed. On any failure: warn on stderr, leave nothing behind
— calling the agent's own `context_mode_strip` on the way out is the
straightforward way to guarantee that — and return non-zero.

The status is not advisory. `container/context-mode-setup.sh` reads it to
decide whether the session may claim the feature ran, so a give-up that
returned 0 would hand a session running with Context Mode off an exit
report saying it was wired — a false claim in the one place the user
actually looks. A half-wired session is worse than an unwired one for the
same reason on both agents: partial wiring changes the agent's behaviour
while delivering none of the feature.

Two further rules, both learned the hard way:

- **Parse, build and format everything before writing anything**, so a
  failure that can be seen at all is seen while the session config is still
  untouched.
- **Never overwrite something riotbox did not write.** Config in the
  session directory is the user's, hand-edited, and not regenerated from
  the host. Both existing implementations identify their own output before
  replacing it — Claude by the shim path inside a hook command, opencode by
  a generated marker on the shim's first line — and refuse the write
  otherwise, so the session degrades to the feature being off rather than
  destroying a file the user cannot get back.

#### `agent_<name>_context_mode_strip`

Remove everything this agent's `context_mode_wire` could have written, and
nothing else. It runs for every registered agent on every session start,
including sessions that never had Context Mode and sessions wired by an
older image, so:

- **It is idempotent and always returns 0.** A failure to clean is a
  warning on stderr, not a non-zero status; nothing upstream of it has a
  better answer than carrying on.
- **It is silent when there was nothing to remove.** The common case is a
  session that never had the feature, and it must not be told about a
  cleanup that did not happen. Report on stderr only what was actually
  removed.
- **It under-removes rather than over-removes.** Touch only what can be
  positively identified as riotbox's own; leave anything else — a
  user-written hook that merely mentions `context-mode`, a user's own file
  at the shim path — exactly as found.

This verb is what keeps a session directory from outliving the image that
wired it while still holding wiring that points at a binary that is gone.
It is also what makes "at most one agent's wiring exists in a session
directory at a time" enforceable: switching `--agent` strips the other
agent's wiring through this verb.

#### `agent_<name>_context_mode_build_assert "$pkg_root"`

```bash
agent_<name>_context_mode_build_assert() {
    local pkg="${1:?package root required}"
    ...
}
```

Called once per registered agent by the Context Mode layer in the
`Containerfile`, with the installed `context-mode` package root as `$1`.
Assert every upstream contract this agent's wiring silently depends on —
a file the wiring re-exports, a symbol it names, a config key it reproduces
— and on any mismatch print a diagnostic that names the *consequence* (not
just the mismatch) on stderr and return non-zero.

The point is where the failure lands. Without the guard, an upstream rename
between pinned versions surfaces as a user session that quietly runs with
the feature broken; with it, the image build fails and names what moved.
Guards live in the same file as the constants they check, because a guard
that lives apart from what it guards stops guarding it the first time
either one moves.

Contract coverage lives in `tests/context-mode.venom.yml` (the Claude
path, plus the strip-every-other-agent rule),
`tests/context-mode-opencode.venom.yml` (the opencode path, including the
foreign-file refusal and the `--pure` warning), and
`tests/doctor-context-mode.venom.yml` (the preflight check for an agent
with no support).

## Worked example: adding `aider`

Suppose [aider](https://aider.chat/) is your third agent. Here's the
complete diff:

### 1. Install in Containerfile

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
    if [ "${set_ci}" = "1" ] && [ -n "${RIOTBOX_INJECT_ENV_FILE:-}" ]; then
        printf 'CI=true\n' >> "${RIOTBOX_INJECT_ENV_FILE}"
    fi
    return 0
}

agent_aider_container_setup() { :; }   # no runtime setup needed

agent_aider_host_sync() {
    local session_dir="${1:?host_sync requires a session_dir argument}"
    # aider reads ~/.aider.conf.yml; copy it into the session dir if
    # present, otherwise no-op.
    if [ -f "${HOME}/.aider.conf.yml" ]; then
        cp "${HOME}/.aider.conf.yml" "${session_dir}/.aider.conf.yml"
        echo "-v ${session_dir}/.aider.conf.yml:/home/llm/.aider.conf.yml:z"
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
- `libexec/run.sh`, `resume.sh`, `audit.sh` — they call
  `agent_call "$RIOTBOX_AGENT" <verb>`.
- `container/agent-wrapper.sh` — it dispatches by `basename($0)`.
- `container/entrypoint.sh` — it loops over `AGENT_REGISTRY`.
- `scripts/mount-projects.sh` — it loops over `AGENT_REGISTRY`.
- `Containerfile` (apart from the install step) — the symlink loop reads
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
  on the contract. Long setup bodies belong in `agents/<name>/setup.sh`
  (sourced by `container_setup`); long sync logic in
  `agents/<name>/sync-settings.sh` (called by `host_sync`).

## Where to look when something breaks

| Symptom                                              | Where to look                                                                                                        |
|------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `--agent=<new>` rejected with "must be one of"       | Does `agents/<new>/manifest.sh` exist? The host wrapper sources the registry at runtime, so no re-install is needed. |
| `riotbox run` exits with "unknown verb"              | Manifest is missing `agent_<name>_run_argv`                                                                          |
| Wrapper invokes wrong binary                         | Check `agent_<name>_real_binary` and PATH order                                                                      |
| `--dangerously-skip-permissions` in wrong place      | Bug in `agent_<name>_wrapper_inject`; see opencode for subcommand-local injection                                    |
| Container fails to start with "no agents discovered" | The `COPY agents/` in the Containerfile didn't run, or every subdirectory is missing `manifest.sh`                      |
| Host config not synced                               | `agent_<name>_host_sync` is a no-op or its sync script is missing                                                    |

Run `task test ARGS=agents` to re-exercise the contract suite at any
time — it's the fastest signal that a manifest is well-formed.
