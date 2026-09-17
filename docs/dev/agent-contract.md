# The agent contract

Reference for every function an `agents/<name>/manifest.sh` may define. Eight are
required; the rest are optional and probed with `declare -F` — absence is never an
error.

**Adding an agent for the first time?** Start at
[adding-an-agent.md](adding-an-agent.md), which walks the three steps and shows a
complete worked example. This page is the per-verb detail that how-to links into.

Function names are mechanical: `agent_<name>_<verb>`.

## Verbs at a glance

| Verb | Required | Runs |
|---|---|---|
| [`real_binary`](#agent_name_real_binary) | yes | wrapper, per invocation |
| [`run_argv`](#agent_name_run_argv) | yes | `riotbox run` |
| [`resume_argv`](#agent_name_resume_argv) | yes | `riotbox resume` |
| [`audit_argv`](#agent_name_audit_argv) | yes | `riotbox audit` |
| [`wrapper_inject`](#agent_name_wrapper_inject) | yes | wrapper, per invocation |
| [`container_setup`](#agent_name_container_setup) | yes | container start |
| [`host_sync`](#agent_name_host_sync) | yes | host, before launch |
| [`env_vars`](#agent_name_env_vars) | yes | host, building passthrough |
| [`headroom_argv`](#agent_name_headroom_argv) | no | wrapper, when `RIOTBOX_HEADROOM=1` |
| [`context_mode_store_dir`](#agent_name_context_mode_store_dir) | no | session start |
| [`context_mode_data_dir`](#agent_name_context_mode_data_dir) | no | session start |
| [`context_mode_platform`](#agent_name_context_mode_platform) | no | session start |
| [`context_mode_wire`](#agent_name_context_mode_wire) | no | session start |
| [`context_mode_strip`](#agent_name_context_mode_strip) | no | session start |
| [`context_mode_build_assert`](#agent_name_context_mode_build_assert) | no | image build |
| [`github_mcp_wire`](#agent_name_github_mcp_wire) | no | `enable_github_mcp` |
| [`github_mcp_strip`](#agent_name_github_mcp_strip) | no | `disable_github_mcp` |
| [`gitlab_mcp_wire`](#agent_name_gitlab_mcp_wire) | no | `enable_gitlab_mcp` |
| [`gitlab_mcp_strip`](#agent_name_gitlab_mcp_strip) | no | `disable_gitlab_mcp` |
| [`git_ai_strip`](#agent_name_git_ai_strip) | no | session start |

## Required verbs

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

### `agent_<name>_run_argv`

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

### `agent_<name>_audit_argv`

```bash
agent_<name>_audit_argv() {
    local prompt="${1:?audit_argv requires a prompt argument}"
    printf '%s\0' <binary> <flags...> "${prompt}"
}
```

Print the argv for read-only audit mode. The launcher already configures
`RIOTBOX_READONLY=1` so the project mount is read-only — `audit_argv`
typically returns the same tokens as `run_argv`.

### `agent_<name>_wrapper_inject`

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

- **What flags to inject** (claude: `--dangerously-skip-permissions`;
  opencode: `--auto`)
- **Where to inject them** (claude: at the root; opencode: immediately
  after the `run` subcommand, or at the root only when argv carries no
  positional token at all — `--auto` is registered on `run` and on the
  default `[project]` command, not globally, so injecting it ahead of a
  subcommand stops that subcommand from being dispatched at all. The rule
  keys on "is there a positional?" rather than on a list of subcommand
  names, because a list that fell behind upstream would inject in front
  of a subcommand it did not recognise. The cost is that a bare
  positional gets nothing even when it is really the TUI's project path:
  `opencode /workspace` runs ask-first. The position is per-CLI, which is
  exactly why this is a hook and not a constant)
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

Two different failures live here, and they are loud in different ways.

A flag this function never emits is **quiet**. Nothing downstream can
observe that the agent is running without auto-approval, and the agent
does not treat it as an error: opencode's headless `run` answers each
request with `permission requested: <tool>; auto-rejecting` on stderr
and carries on, and the TUI simply starts in its normal ask-first mode.
That is the case the symptom table in `adding-an-agent.md` troubleshoots.

A flag the CLI no longer recognises is **loud but late**. opencode's
parser is strict, so an unknown flag exits 1 with usage: an upstream
rename does not degrade the session, it breaks it, at the moment the
user tries to work. So the `Containerfile` asserts the flag at build
time — it requires opencode >= 1.18.0 (the release that added `--auto`)
*and* greps the installed binary's help for the flag at both sites the
wrapper injects into, `opencode run --help` and root `--help`. That
moves the failure from the user's session to the image build, where it
names what moved. Same reasoning as
`agent_<name>_context_mode_build_assert` below.

For opencode the injected flag is not the only thing granting autonomy —
`agents/opencode/setup.sh` also forces `permission = "allow"` into the
merged config on every container start. `THREAT_MODEL.md` records how the
two divide the work and why neither replaces the other.

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

### `agent_<name>_host_sync`

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

## Optional verbs: headroom

Beyond the eight required functions, a manifest may implement optional
verbs. Every caller probes with `declare -F agent_<name>_<verb>`; absence is
never an error.

### `agent_<name>_headroom_argv`

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
  passes `--code-memory none` — the image is offline-after-build),
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
- apply agent-specific routing only AFTER the proxy answers,
- degrade to unwrapped on any failure — warn on stderr, leave config
  untouched, `exec <real-binary-name> "$@"`,
- end by exec'ing something that reaches `<real-binary-name>`, so the shim's
  guarded second pass applies the agent's normal injection rules. That may
  be the binary directly, or `headroom wrap <tool>`, which launches it.

A helper is the right shape whenever `headroom wrap <tool>` does most of the
job but one of its side effects is unacceptable in a container. The opencode
helper exists for exactly one such effect: `wrap opencode --memory` writes a
memory block into `AGENTS.md` in the CWD, which in a session is the caller's
bind-mounted repository. Owning the proxy locally buys memory without that
write; everything else is delegated to `wrap opencode --no-proxy`.

`agents/opencode/headroom-exec.sh` is the reference implementation.

Agents without the verb run unwrapped under `RIOTBOX_HEADROOM=1`, with a
warning on stderr.

Contract coverage lives in `tests/agents.venom.yml` ("Headroom optional
verb" cases), `tests/headroom.venom.yml` (wrapper gate, guard, and
fallbacks), and `tests/headroom-opencode.venom.yml` (proxy-routed helper
behavior).

## Optional verbs: Context Mode

Six optional verbs carry [Context Mode](../../README.md#context-mode-opt-in)
support for an agent. Five run per session; the sixth runs at image build
time. Claude implements four of them, opencode all six:

| Verb | When | Contract |
|------|------|----------|
| `context_mode_store_dir` | session start | Print this agent's absolute `CONTEXT_MODE_DIR` on stdout. No side effects. |
| `context_mode_data_dir` | session start | Print the absolute root this agent's `CONTEXT_MODE_DATA_DIR` pins. Implement only where the pin is otherwise missing. |
| `context_mode_platform` | session start | Print the upstream platform token this agent runs as, exported as `CONTEXT_MODE_PLATFORM`. Every agent should implement it. |
| `context_mode_wire` | session start | Write this agent's wiring. All-or-nothing: return 0 only when every artifact landed. Omit it when the agent's support arrives some other way. |
| `context_mode_strip` | session start | Remove any wiring this agent could be carrying — from `context_mode_wire`, or from an older release that wrote some. Idempotent, always returns 0. |
| `context_mode_build_assert "$tree_root"` | image build | Assert the upstream contract this agent's support depends on. Non-zero fails the build. |

Every caller probes with `declare -F agent_<name>_<verb>` before calling —
`container/context-mode-setup.sh` at session start, `scripts/preflight.sh`
for the `riotbox doctor` check, and the Context Mode layer in the
`Containerfile` for the build guard. An agent that implements none of them
is not an error: the session warns naming the agent, strips any wiring an
earlier session left in the same session directory, and runs with the
feature off.

**`context_mode_store_dir` is the verb that answers "does this agent have
Context Mode support at all."** It is what `container/context-mode-setup.sh`
probes before anything else, and what `scripts/preflight.sh` reports on. It
is deliberately not `context_mode_wire`: Claude Code reaches Context Mode
through a plugin the image stages and `container/plugin-setup.sh` registers,
so it has no wire verb, and a probe on `wire` would read the best-supported
agent as unsupported.

**Implementing `context_mode_wire` obliges the agent to implement
`context_mode_store_dir` and `context_mode_strip` as well.** The
orchestrator asks for the store path *before* it wires and gives up when the
answer is unusable, so a `wire` without `store_dir` never runs; and every
give-up path — including the ones inside `wire` itself — calls the stripper,
so a `wire` without `strip` leaves wiring behind that nothing removes, for
the life of a session directory that outlives the image that wrote it.

The reverse does not hold. **`context_mode_strip` outlives the wiring it
undoes**, and Claude is the worked example: it has `store_dir`, `platform`,
`strip` and `build_assert`, and no `wire`. Session directories outlive
images, one wired by
an older release still holds that release's hook stanzas, and `settings.json`
is never synced from the host — so the stripper is the only thing that
converges a reused directory on one form of wiring. Delete a `wire` verb;
keep its `strip` for as long as a session directory might still carry what
it wrote.

`context_mode_data_dir` is per-agent by design and Claude does not implement
it. See its section below for when an agent needs it.

`context_mode_platform` is optional to the orchestrator — an agent that omits
it keeps upstream's own `detectPlatform()` — but omitting it is almost always
a bug, because that detection is exactly what this verb exists to defeat.
Every riotbox image ships more than one agent, so the detection has more than
one config to pick from, and a wrong pick sends `getPluginRoot()` to a
package cache no riotbox install populates. The import fails onto a stderr
the hook dispatcher has already redirected to `/dev/null`. Nothing warns,
nothing routes, and the toggle, `riotbox doctor` and the exit report all
still say the feature is on — so unlike the other five, this one fails
silently rather than loudly. Implement it in every agent that implements
`context_mode_store_dir`.

Put the bodies in `agents/<name>/context-mode.sh` and have `manifest.sh`
source it:

```bash
# Context Mode verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./context-mode.sh
source "${_AGENT_<NAME>_DIR}/context-mode.sh"
```

That keeps the upstream constants, whatever depends on them, and the build
guard that asserts them in one file. `agents/claude/context-mode.sh` (no
wiring — a store path, a platform token, and a stripper for what an older
release wrote) and `agents/opencode/context-mode.sh` (one generated plugin
file) are the two worked examples, and they are deliberately different
shapes — the registry contract is about the lifecycle, not about what wiring
looks like.

### `agent_<name>_context_mode_store_dir`

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

### `agent_<name>_context_mode_data_dir`

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

### `agent_<name>_context_mode_platform`

```bash
agent_<name>_context_mode_platform() {
    printf '<upstream platform token>\n'
}
```

Print the token upstream keys its hook dispatch and adapter detection off —
`claude-code` for Claude, `opencode` for opencode — and nothing else. The
session exports it as `CONTEXT_MODE_PLATFORM`, which is the same remedy
upstream applies to its own Copilot CLI bundle for the same reason.

**Pin it rather than letting upstream detect it.** `hookDispatch` resolves
the hook script through `getPluginRoot()`, which branches on
`detectPlatform()`. Every riotbox image ships every supported agent, so that
detection has several configs to choose between and no way to know which
agent is running; when it lands on an in-process plugin platform it returns
`~/.cache/<platform>/packages/context-mode@latest/node_modules/context-mode`,
a path no riotbox install populates. The import throws — into a stderr
`hookDispatch` closed and reopened on `/dev/null` before dispatching. The
session routes nothing and reports itself healthy, which is why this verb
matters more than its "optional" status suggests.

`container/context-mode-setup.sh` probes for it the way it probes
`context_mode_data_dir`, so an agent that does not implement it keeps
upstream's detection instead of being handed a wrong answer. An answer that
is *empty* is a different thing — a bug in the verb — and is rejected the
way an empty store path is: warn, strip, run with the feature off. It is not
exported empty, because upstream reads an empty `CONTEXT_MODE_PLATFORM` as
"unset" on some paths and as a platform named `""` on others.

### `agent_<name>_context_mode_wire`

Implement this only when riotbox has to author something for the agent to
reach Context Mode. Claude Code does not: the image stages upstream's
marketplace plugin and `container/plugin-setup.sh` registers it against the
session, so there is nothing left for a wire verb to write and the verb was
removed. opencode still needs one, because its support is a plugin file in
the session config directory that only riotbox can put there.

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

**An agent with no wire verb still has to earn that claim.** `_CONTEXT_MODE_WIRED`
is not set unconditionally for want of a verb to ask. For Claude,
`context_mode_setup` calls `context_mode_plugin_installed`, which reads
`~/.claude/plugins/installed_plugins.json` and `settings.json` and answers yes
only for a registered entry whose `installPath` is on disk and which
`settings.json` has not explicitly disabled. A no warns on stderr and leaves the
flag unset, so the exit report and the ledger record stay silent rather than
claiming a run that never happened. That probe deliberately asks what the
*session* has rather than what RiotBox staged: a `context-mode` the user
installed on the host is copied in and registered by the ordinary host-plugin
path, and it counts. An agent adding support that arrives from outside riotbox
owes the same kind of evidence — the rule is "prove the feature is live", and
`wire`'s return status is only how an agent that authors its wiring proves it.

Two further rules, both learned the hard way:

- **Parse, build and format everything before writing anything**, so a
  failure that can be seen at all is seen while the session config is still
  untouched.
- **Never overwrite something riotbox did not write.** Config in the
  session directory is the user's, hand-edited, and not regenerated from
  the host. Identify riotbox's own output before replacing it — opencode
  does so by a generated marker on the shim's first line, and Claude's
  stripper still does it by the shim path inside a hook command — and refuse
  the write otherwise, so the session degrades to the feature being off
  rather than destroying a file the user cannot get back.

### `agent_<name>_context_mode_strip`

Remove everything riotbox could have put in this session directory for this
agent, and nothing else. That is a wider set than the current
`context_mode_wire` writes: it includes wiring an *older release* wrote, so
the verb outlives the wiring it undoes and Claude keeps a stripper with no
wire verb at all. It runs for every registered agent on every session start,
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
  at the shim path — exactly as found. For a hook command that means two
  things. The shim path has to appear as a whole whitespace-delimited token
  once quote characters are stripped, so a user's `<shim>-wrapper` beside
  ours is theirs and stays. And the verdict is per hook entry, not per
  stanza: Claude Code groups hooks under a shared matcher, so a hook the
  user added under the same matcher as ours survives, and the stanza around
  it goes only once pruning has emptied it.

This verb is what keeps a session directory from outliving the image that
wired it while still holding wiring that points at a binary that is gone.
It is also what makes "at most one agent's wiring exists in a session
directory at a time" enforceable: switching `--agent` strips the other
agent's wiring through this verb.

### `agent_<name>_context_mode_build_assert`

```bash
agent_<name>_context_mode_build_assert() {
    local root="${1:?upstream tree root required}"
    ...
}
```

Called for every registered agent that implements it, at least once, by the
Context Mode layer in the `Containerfile`, with the installed `context-mode`
package root as `$1`.
Treat `$1` as "the root of an upstream tree", not as "the npm package": the
plugin-staging layer calls claude's verb a second time with the staged plugin
clone as `$1`, because that clone — not the npm package — is what
`container/plugin-setup.sh` registers and what a Claude session's hooks and MCP
server run from. An agent whose artifact is staged separately owes the same
second call; asserting one copy and calling the other covered rests the
guarantee on two pins naming the same release, which no build layer can see.
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

## Optional verbs: forge MCP servers

Four optional verbs attach the GitHub and GitLab MCP servers to an agent.
None of them runs on its own: they fire only when a user runs one of the
four commands the [`riotbox-gh-glab`](../../README.md#github-and-gitlab-the-riotbox-gh-glab-flavor)
image puts on `PATH`.

| Verb | When | Contract |
|------|------|----------|
| `github_mcp_wire "$token_var"` | `enable_github_mcp` | Register `github-mcp-server` as a stdio server, with `$token_var` written as an environment-variable *reference*. Warn before replacing an entry riotbox did not write. Return 0 only if the entry landed. |
| `github_mcp_strip` | `disable_github_mcp` | Remove the entry **only if riotbox wrote it**; warn and leave anything else alone. Idempotent and silent when there is nothing to remove. An unparseable config warns and returns 0; every other give-up path returns non-zero. |
| `gitlab_mcp_wire "$url" "$token_var"` | `enable_gitlab_mcp` | Register `$url` as an HTTP server authenticating with `Bearer` + a reference to `$token_var`. **Reject a `$url` that is not an `http(s)` `/api/v4/mcp` endpoint** — anything else is a server `gitlab_mcp_strip` will not recognise as riotbox's. Same ownership warning as `github_mcp_wire`. Return 0 only if the entry landed. |
| `gitlab_mcp_strip` | `disable_gitlab_mcp` | As `github_mcp_strip`, for the GitLab entry. |

`container/forge-mcp.sh` probes with `declare -F agent_<name>_<verb>` and
skips an agent that implements none of them, saying so on stderr. Silence
would read as "wired" for an agent that is not.

Unlike the Context Mode verbs, these are **two independent pairs**. An agent
may implement the GitHub pair and not the GitLab one; the two servers are
enabled by separate commands and share no state. Within a pair, `wire`
obliges `strip`: `disable_*` is the only way a user turns a server back off
without hand-editing JSON.

### What the verbs are handed, and what they must not do

Both `wire` verbs take the **name** of an environment variable, never its
value, and write a reference the agent expands when it spawns the server —
`${NAME}` for Claude Code, `{env:NAME}` for opencode.

This is not a style preference and must not be "simplified" away. The agent
config directories resolve into the session directory, which is a bind mount
from the host: a token written there outlives the container, survives the
agent exiting, and stays readable by anything on the host that can read the
session directory. `tests/forge-mcp.venom.yml` asserts the property directly
by wiring with sentinel token values and grepping the whole tree for them.

Deciding *which* variable holds the token is the caller's job, not the
agent's. `container/forge-mcp.sh` resolves it once — `GITHUB_PERSONAL_ACCESS_TOKEN`
then `GITHUB_TOKEN` for GitHub, `GITLAB_TOKEN` for GitLab — and hands the
same answer to every agent, so two agents can never disagree about which one
won. It also resolves `GITLAB_HOST` into a full endpoint URL before calling,
and refuses to call at all when no candidate variable is set.

The GitLab URL, unlike the token, is written **literally**. It is not a
secret, and an unexpanded `${GITLAB_HOST}` inside a URL would produce a
malformed endpoint instead of an honest failure.

Put the bodies in `agents/<name>/forge-mcp.sh` and have `manifest.sh` source
it:

```bash
# GitHub/GitLab MCP verbs (optional contract — see docs/dev/agent-contract.md).
# shellcheck source=./forge-mcp.sh
source "${_AGENT_<NAME>_DIR}/forge-mcp.sh"
```

Both forges share one file per agent because they share a destination —
each agent reads all its MCP servers from one place — and nothing else. They
do not share an entry shape, and no abstraction is forced over the
difference:

- **GitHub** is a local stdio process. The image bakes in `github-mcp-server`
  and the entry names it, with the credential in the server's own environment
  block. That block exists solely to bridge `GITHUB_TOKEN` to the
  `GITHUB_PERSONAL_ACCESS_TOKEN` the server actually reads; a stdio child
  already inherits the agent's environment.
- **GitLab** is not a program. It is an endpoint on the user's own instance
  (`<host>/api/v4/mcp`, streamable HTTP), so the entry is a URL and the
  credential rides in an `Authorization` header. A personal access token
  carrying GitLab's `mcp` scope authenticates there; browser OAuth, which
  GitLab documents as the default, is unusable in a headless container.

### Whose entry is it

The server key alone does not make an entry riotbox's. `agents/claude/sync-settings.sh`
copies the host's `~/.claude.json` into the session at every launch, and
`opencode_setup` regenerates `opencode.jsonc` from the host's opencode config
at every session start, so a `github` or `gitlab` entry the user configured on
the host is sitting in the very file these verbs write. A third agent will have
its own version of the same problem.

So both verbs decide ownership on the entry's **shape** — a predicate over the
entry, kept beside the code that builds it:

| Forge | Ours when |
|---|---|
| GitHub, claude | `type` is `stdio`, `command` is `github-mcp-server`, `args` is exactly `["stdio"]`, and `env` is an object whose only key is `GITHUB_PERSONAL_ACCESS_TOKEN`, holding a bare `${VAR}` reference |
| GitHub, opencode | `type` is `local`, `command` is exactly `["github-mcp-server", "stdio"]`, and `environment` is an object whose only key is `GITHUB_PERSONAL_ACCESS_TOKEN`, holding a bare `{env:VAR}` reference |
| GitLab, claude | `type` is `http`, `url` ends in `/api/v4/mcp`, and `headers` has exactly one key, `Authorization`, matching `Bearer ${VAR}` |
| GitLab, opencode | `type` is `remote`, `url` ends in `/api/v4/mcp`, and `headers` has exactly one key, `Authorization`, matching `Bearer {env:VAR}` |

Write the shape out in full, as an exact statement of what the wire verb
produces. **Every field a shape omits is a field a user can differ on and lose
their entry over**, so omit only what riotbox genuinely cannot pin:

- **The credential's variable NAME.** A session may export
  `GITHUB_PERSONAL_ACCESS_TOKEN` on one run and only `GITHUB_TOKEN` on the
  next; both wrote riotbox's entry. A strip that did not recognise the first
  would leave a server registered that the user asked to revoke. The *block*
  holding the credential is not omitted with it — `github-mcp-server` reads
  `GITHUB_TOOLSETS` and `GITHUB_HOST` from that same block, so an extra key
  there is a user's narrowing and must not be claimed.
- **The GitLab URL's host**, for the same reason: `GITLAB_HOST` can change
  between the wire call and the strip. Its *path* is pinned — `container/forge-mcp.sh`
  always builds `<host>/api/v4/mcp` — so an entry pointing elsewhere on a
  GitLab instance is not riotbox's.
- **opencode's `enabled`.** A user who flipped riotbox's entry to `false` still
  has riotbox's entry, and `disable_github_mcp` should still take it away.
- **The entry's top-level key set.** Every block the shape names is checked
  exactly, but an *unrecognised sibling key* does not disqualify an entry.
  This one cuts the other way from the rest: an agent release that normalises
  configs by adding a field would otherwise strand riotbox's own entry
  permanently, which is worse than the case pinning it would catch. Accepting
  an entry riotbox may not have written is recoverable — the wire warning and
  a hand edit; refusing to remove one riotbox did write is not.

The wire verb owes the shape a **precondition**: it must refuse to write
anything the shape would disown. `gitlab_mcp_wire` rejecting a URL that is not
an `/api/v4/mcp` endpoint is that rule in practice. A verb pair that can write
what it cannot revoke strands the user in the state this whole rule exists to
prevent, so enforce it in the wire verb rather than trusting the caller.

Do not identify the entry with a marker key instead. The config document's
schema belongs to the agent, which is free to reject or drop a field it does
not know, and ownership would then hinge on whether some unrelated release
tolerated it.

The check has **three** answers, not two: ours, provably not ours, and *cannot
tell* — the predicate failed to evaluate. Do not fold the third into the
second. On the strip side an entry riotbox did write would then be reported as
foreign, stay registered, and be announced as removed. `strip` must take its
non-zero `could not clean` path instead; `wire`, which is about to overwrite
the entry either way, simply stays quiet.

If the shape is expressed as a query the implementation splices into a program
(the two shipped agents splice a jq predicate), it must be a literal defined in
the agent's own file — never derived from a config file, an environment
variable, or anything else a session can influence.

From that rule, two obligations:

- **`wire`** replaces a foreign entry — a user who runs `enable_github_mcp`
  asked for riotbox's server — but warns on stderr first, naming the key and
  saying that whatever the entry restricted is not preserved. It stays
  idempotent and still returns 0. Re-wiring riotbox's own entry is silent, and
  so is re-wiring it under a different token variable: shape, not equality.
- **`strip`** deletes only an entry matching the shape. Anything else it leaves
  in place, warns about, and reports as **success** — the user's config is
  intact, which is what they wanted. It also says riotbox had no entry of its
  own to remove, because `container/forge-mcp.sh` prints `<forge> MCP cleanup
  complete` on a 0 return and a user reading stdout alone would otherwise have
  nothing telling them their own entry is still there.

`tests/forge-mcp.venom.yml` covers these behaviours for both agents and both
forges, including a GitHub entry narrowed through its environment block, a
GitLab entry on a different endpoint, and riotbox's own GitLab entry stripped
after the host it was wired against changed.

## Optional verbs: git-ai

One optional verb carries [git-ai](../../README.md#ai-authorship-attribution-git-ai)
cleanup for an agent — there is no `wire` verb, and that absence is deliberate rather
than a gap.

| Verb | When | Contract |
|------|------|----------|
| `git_ai_strip` | session start | Remove wiring this project's binary owns, deciding on the entry's shape and under-removing. Idempotent, always returns 0. |

**RiotBox does not write git-ai's wiring — upstream's `install-hooks` does.**
`container/git-ai-setup.sh` calls it once per session and lets it write the Claude
hook stanzas, the opencode plugin, and the `~/.gitconfig` Trace2 target. RiotBox
does not hand-author any of those shapes, for the same reason
`agent_<name>_context_mode_wire` is missing on Claude Code: upstream's own docs
have already drifted from what its binary installs once — the documented Claude
matcher is `Write|Edit|MultiEdit`, the matcher v1.7.4 actually writes is `"*"` — so
a hand-maintained stanza in this repo would be one more place that drift could go
unnoticed. Letting upstream own the shape keeps RiotBox out of it. What upstream
cannot do is clean up a session directory that outlives the image: a session wired
by an on-run and reopened with `RIOTBOX_GIT_AI=0` would otherwise keep firing hooks
at a binary whose config this session stopped maintaining. That gap is what
`git_ai_strip` exists to close, and it is the only thing this verb set owns.

**An agent with no git-ai verbs simply gets no cleanup, which is safe.** Nothing
calls `install-hooks` on behalf of an agent riotbox does not register, so an agent
missing from `AGENT_REGISTRY` never gets wiring in the first place and has nothing
for a stripper to remove.

Put the body in `agents/<name>/git-ai.sh` and have `manifest.sh` source it, the
same layout as the Context Mode and forge-MCP verb sets.

### `agent_<name>_git_ai_strip`

Remove only what this project's own git-ai binary could have written, deciding on
the entry's **shape** — never a key name — and under-removing rather than
over-removing, the same rule `agent_<name>_context_mode_strip` and the forge-MCP
strip verbs follow. It is idempotent, silent when there is nothing to remove, and
always returns 0: a failure to clean is a warning on stderr, not a non-zero status,
because nothing upstream of it has a better answer than carrying on.

The two shipped agents decide ownership by different means, because the wiring
upstream writes for each one has a different shape:

- **`agents/claude/git-ai.sh`** matches the binary as a **whole
  whitespace-delimited token** inside a hook's `command`, after stripping quote
  characters — not a substring match. A `contains($bin)` test was tried first and
  over-removed: the binary's path is a prefix of any sibling script a user might
  keep beside it, so a hook naming `<bin>-wrapper` read as ours and was deleted.
  Token comparison leaves that hook alone. The verdict is per hook **entry**, not
  per stanza — Claude Code groups hooks under a shared matcher, so a hook the user
  added under the same matcher as ours survives, and the stanza around it is
  removed only once pruning has emptied it of every entry.
- **`agents/opencode/git-ai.sh`** is content-gated, not path-gated. Upstream
  regenerates `~/.config/opencode/plugins/git-ai.ts` on every session — the
  binary's absolute path is baked into the file at install time, so path alone
  cannot identify a stale copy left by an older image — so the strip instead
  requires upstream's own banner, `git-ai plugin for OpenCode`, to appear as a
  **block-comment line within the first 10 lines** of the file. A free-substring
  match was tried first and deleted a user's own plugin whose comment read
  `// replaces the git-ai plugin for OpenCode`: the phrase appears, but not as a
  block-comment line at the position upstream's generator actually writes it. The
  tighter gate leaves that file alone and only takes the file whose shape matches
  what a real `git-ai install-hooks` run produces.

### `agent_<name>_github_mcp_wire`

```bash
agent_<name>_github_mcp_wire() {
    local token_var="${1:?github_mcp_wire requires the name of the token variable}"
    ...
}
```

Register `github-mcp-server` under the server name `github`, invoked as
`github-mcp-server stdio`, passing `GITHUB_PERSONAL_ACCESS_TOKEN` to it as a
reference to `$token_var`.

Validate that `$token_var` is a shell identifier before using it. `jq --arg`
quotes its input, so this is a typo guard rather than an injection guard: a
malformed name would otherwise land in the config as a reference the agent
cannot resolve, presenting as a server that authenticates as nobody.

Parse, build and format everything *before* writing, so a failure that can
be seen at all is seen while the config is untouched. Skip the write when the
document already matches — that is what makes re-running an enable command
free. Return non-zero on every give-up path, leaving the config as found. Warn
before overwriting an entry riotbox did not write, per
[Whose entry is it](#whose-entry-is-it).

Do not write `GITHUB_HOST` or `GITHUB_TOOLSETS`. The server reads both from
the environment it inherits, so a session that exports them already has them,
and writing an opinion would be one the user did not ask for.

### `agent_<name>_github_mcp_strip`

Delete the `github` entry, and only if riotbox wrote it — see
[Whose entry is it](#whose-entry-is-it) for how that is decided and why a
foreign entry is left alone with a warning and a 0 return. Silent and
successful when there is nothing to remove — it runs against sessions that
never had the feature.

A malformed config **warns and still returns 0**, unlike the wire verb. The
disable commands are how a user gets out of a bad state; refusing to finish
because another tool corrupted the file would strand them with nothing to do
but hand-edit the file that cannot be parsed. An unparseable config is not
loaded by the agent either, so nothing is left running.

**Every other give-up path returns non-zero** — an edit that could not be
built as much as a write that did not land. In each the entry is provably
still registered, and on a 0 return `container/forge-mcp.sh` prints
`<agent>: <forge> MCP cleanup complete.` on stdout and exits 0 — telling a
user who asked to revoke an agent's forge access that the command did its
job when it did not.

That status line says "cleanup complete" rather than "server removed"
because a strip returns 0 on four paths where nothing was removed: no
config file, no entry present, a config too malformed to edit, and a
foreign entry left in place. The verb itself is what reports an actual
deletion, with `Removed the <server> MCP server from <config>.` on
stderr.

### `agent_<name>_gitlab_mcp_wire`

```bash
agent_<name>_gitlab_mcp_wire() {
    local api_url="${1:?gitlab_mcp_wire requires the MCP endpoint URL}"
    local token_var="${2:?gitlab_mcp_wire requires the name of the token variable}"
    ...
}
```

Register `$api_url` under the server name `gitlab` as an HTTP/remote server,
with the header `Authorization: Bearer <reference to $token_var>`. Reject a
`$api_url` that is not `http://` or `https://`, and reject one that does not
end in `/api/v4/mcp` — the ownership shape requires that endpoint, so writing
any other would register a server `gitlab_mcp_strip` then refuses to remove.
Same write discipline and same return contract as the GitHub verb.

### `agent_<name>_gitlab_mcp_strip`

Delete the `gitlab` entry, under the same rules as `github_mcp_strip`.

### Where each agent writes

| Agent | File | Key | Lifetime |
|---|---|---|---|
| claude | `${CLAUDE_CONFIG_DIR}/.claude.json` | `.mcpServers` | persists across sessions |
| opencode | `${OPENCODE_CONFIG_DIR}/opencode.jsonc` | `.mcp` | **one session** |

The opencode row is not an oversight. `opencode_setup`
(`agents/opencode/setup.sh`) regenerates `opencode.jsonc` from host config on
every container start, so an entry written there survives until the next
session start and no longer. Writing somewhere more durable would mean
editing the user's real config on the host, which a session-scoped enable
command has no business doing. The documented answer is to re-run the enable
command after a restart.

An opencode implementation must also preserve the file's `//` banner:
`agents/opencode/headroom-exec.sh` splits the file on it with line-level
grep, and `opencode_setup` regenerates it from a template.

Contract coverage lives in `tests/forge-mcp.venom.yml` — the verbs for both
agents, the four commands end to end, credential-variable precedence,
`GITLAB_HOST` normalization, entry ownership, and the no-secrets-on-disk
assertion.
