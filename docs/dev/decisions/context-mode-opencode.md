# Wiring Context Mode for opencode

**Decision:** Wire the upstream opencode adapter, and move all per-agent Context
Mode wiring behind optional registry verbs so the shared orchestration script
names no agent.

**Date:** 2026-07-31 · **Issue:** [#5](https://github.com/trevor-vaughan/claude-riotbox/issues/5) (follow-on to the full-hooks work) · **Branch:** `feat/context-mode-opencode`

> **Frozen design record.** The body below is as written, with corrections made
> during implementation marked inline. For the current implementation, read
> [How Context Mode works in RiotBox](../context-mode.md).

## Purpose

Context Mode ships wired for Claude Code only. `context_mode_setup` warns and skips
for any other agent, and [the evaluation](context-mode-adoption.md#what-happened-next)
records that as a deliberate scope cut: every stanza RiotBox writes is
`context-mode hook claude-code …` under `CLAUDE_CONFIG_DIR`, which opencode never
reads.

Upstream ships an opencode adapter that RiotBox does not reach for. This design
wires it, and does so through the agent registry rather than a second branch in a
shared script, because a third agent is coming and the alternative pays the same
cost again.

Two things follow that are not "make opencode work":

1. **The Claude wiring moves out of `container/context-mode-setup.sh`** into
   `agents/claude/`, so the shared script holds no agent names. The four
   Claude-contract constants the image build asserts against the installed bundle
   move with it, and the build guard follows them.
2. **"At most one agent's wiring exists in this session directory" becomes an
   explicit loop** instead of a special case that happens to hold while exactly one
   agent wires.

## Upstream facts this design depends on

Verified against `context-mode@1.0.169` and `opencode 1.18.10` as installed in the
image, on 2026-07-31. Every claim below was checked by running the code, not by
reading the docs, except where marked.

- **The adapter exists and is complete.** `build/adapters/opencode/` implements
  opencode's TypeScript plugin paradigm across five files.
- **It initialises under opencode's embedded runtime.** Loaded through a local
  plugin file, `ContextModePlugin(ctx)` returns without error under **bun 1.3.14**
  and yields seven hook keys: `tool`, `tool.execute.before`, `tool.execute.after`,
  `event`, `chat.message`, `experimental.session.compacting`,
  `experimental.chat.system.transform`.
- **Tools arrive in-process, not over MCP.** The plugin imports `build/server.js`
  with `CONTEXT_MODE_EMBEDDED_PLUGIN_TOOLS=1` and registers eleven tools as native
  opencode tools: `ctx_execute`, `ctx_execute_file`, `ctx_index`, `ctx_search`,
  `ctx_fetch_and_index`, `ctx_batch_execute`, `ctx_stats`, `ctx_doctor`,
  `ctx_upgrade`, `ctx_purge`, `ctx_insight`. **No `mcpServers` entry is written for
  opencode, and none is needed.**
- **The Node floor does not apply to this path.** `build/db-base.js` ships a
  `BunSQLiteAdapter` (upstream #45) that bridges `bun:sqlite` to the better-sqlite3
  API, so the native addon that forced `ARG CONTEXT_MODE_NODE=22.23.1` is never
  loaded. bun's SQLite is **3.53.0 with FTS5 compiled in**, verified by creating an
  FTS5 virtual table and matching against it inside the plugin.
- **Local plugins load from `plugins/` (plural).** Both
  `~/.config/opencode/plugins/` and `<project>/.opencode/plugins/` load at startup;
  a file placed in the singular `plugin/` never loaded. Upstream's adapter
  docstring says `.opencode/plugins/*.ts`, which agrees.
- **npm plugin entries are installed from the registry at startup.** opencode
  bun-installs `"plugin": ["context-mode"]` into `~/.cache/opencode/node_modules/`
  (documented, not run here — running it requires the network this design exists to
  avoid). This is why RiotBox writes a local shim instead, for the same reason it
  writes the Claude stanzas by hand instead of running `context-mode upgrade`.
- **A local plugin and an npm plugin of the same name both load.** Documented
  upstream. Two adapter instances means duplicate tool registration and
  double-fired hooks; [the opencode implementation](#opencode-implementation-agentsopencodecontext-modesh)
  handles it.
- **Two variables pin two stores, and this design originally saw only one.**
  Corrected during implementation, from source, against the same pinned version:
  `CONTEXT_MODE_DIR` (`build/session/db.js:22`) is read by
  `resolveSessionStorageDir` / `resolveContentStorageDir`, which back the `ctx_*`
  tools. The plugin's own session DB does **not** read it — `plugin.js:139` takes
  `adapter.getSessionDir()`, and `getSessionDir()`
  (`build/adapters/opencode/index.js:193`) prefers `resolveContextModeDataRoot()`,
  which reads **`CONTEXT_MODE_DATA_DIR`** (`build/adapters/base.js:50`), falling
  back to `join(getConfigDir(), "context-mode", "sessions")`. RiotBox now exports
  both. **Neither pin is verified at runtime** — the probe never fired a tool, so
  no store was ever created. See [Risks](#risks).
- **opencode has no `SessionStart` hook** (upstream #14808, #5409). The adapter
  compensates with plugin-init cleanup and a resume snapshot injected through
  `experimental.chat.system.transform`. Resume attribution is weaker than on Claude;
  this is a documented degradation, not a defect to fix here.
- **The adapter injects its own routing instructions.** `systemHasRoutingInstructions`
  requires two of three markers (`<context_window_protection>`, `ctx_search`,
  `ctx_index`) in the system prompt and injects `ROUTING_BLOCK` when they are
  absent. RiotBox's generated `AGENTS.md` needs no edit.

## What carries over, and what does not

**Carries over unchanged.** The opt-in gate (`RIOTBOX_CONTEXT_MODE=1`, literal `1`
only), mutual exclusion with `RIOTBOX_HEADROOM=1` enforced in `libexec/launch.sh`
and `scripts/preflight.sh`, the pinned `CONTEXT_MODE_BIN` shim, the exit report, the
JSON ledger, and `riotbox ctx-stats`. The report and ledger are already
agent-neutral: `container/context-mode-summary.sh:228` resolves the store through
`CONTEXT_MODE_DIR`, and `:336` already stamps `--arg agent "${RIOTBOX_AGENT:-claude}"`
into every record.

**Does not carry over.** Hook stanzas in `settings.json`, the `mcpServers` entry in
`.claude.json`, `CONTEXT_MODE_MATCHER` / `CONTEXT_MODE_POST_MATCHER` (opencode has
no matcher concept — routing is enforced in-process), and
`CONTEXT_MODE_MCP_NAME` (no MCP server). The `context-mode hook claude-code <event>`
dispatcher is not used at all on this path.

**Store location.** Per-agent, not shared: opencode gets
`${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/context-mode`, Claude keeps
`${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/context-mode`. As implemented, opencode
also exports `CONTEXT_MODE_DATA_DIR` at the *parent* of that path so the plugin's
session DB lands at `<store>/sessions` beside the `ctx_*` stores rather than
wherever upstream's config-dir fallback happens to resolve. Both sit inside the
bind-mounted session directory, so both remain covered by `riotbox session-remove`
and neither can land on the container overlay and vanish at exit. The cost is
accepted deliberately: two stores per session directory, and recall does not survive
switching agents mid-session.

## Registry contract: optional session verbs

`agents/*/manifest.sh` gains optional verbs. Optional means absent-is-legal:
callers probe with `declare -F "agent_${agent}_<verb>"`, the idiom
`container/agent-wrapper.sh:53` already uses for `headroom_argv`. No new registry
API, and `agents/registry.sh` is untouched.

| Verb | Contract |
| --- | --- |
| `context_mode_wire` | Wire Context Mode for this agent. All-or-nothing: return 0 only when every artifact landed. On any failure, leave nothing behind and return non-zero. |
| `context_mode_strip` | Remove anything this agent's `context_mode_wire` could have written. Idempotent, returns 0, reports on stderr what it actually removed and stays silent when there was nothing. |
| `context_mode_store_dir` | Print the absolute `CONTEXT_MODE_DIR` for this agent on stdout. No side effects. |
| `context_mode_data_dir` | Print the absolute `CONTEXT_MODE_DATA_DIR` for this agent on stdout. No side effects. Added during implementation; see the store-pin correction under [upstream facts](#upstream-facts-this-design-depends-on). |

This design specified the first three. `context_mode_data_dir` was added while
implementing, once the second storage variable was found; it is the one verb that
is genuinely per-agent rather than a set — opencode implements it and Claude does
not, because Claude's adapter already resolves its config dir from
`CLAUDE_CONFIG_DIR`, which `container/entrypoint.sh` exports at the session mount.
`context_mode_build_assert` (see [Build-time guards](#build-time-guards-containerfile)) is a fifth verb, and the only one that runs at
image build time rather than session start.

An agent that defines none of them degrades exactly as today: warn, strip, run with
the feature off.

`docs/dev/agent-contract.md` documents the verbs alongside the existing
contract, including that implementing `context_mode_wire` obliges an agent to
implement `context_mode_store_dir` and `context_mode_strip`.

## Orchestration: `container/context-mode-setup.sh`

Retains the feature-level concerns only, and no agent name appears in the file:

1. `RIOTBOX_CONTEXT_MODE` is not literally `1` → strip every registered agent,
   return 0.
2. Current agent has no `context_mode_wire` verb → warn naming the agent, strip
   every registered agent, return 0.
3. `CONTEXT_MODE_BIN` not executable → warn, strip every registered agent, return 0.
4. `CONTEXT_MODE_DIR="$(agent_call "${agent}" context_mode_store_dir)"`, rejected if
   empty or not absolute (warn, strip all, return 0), otherwise exported. As
   implemented, an agent that also defines `context_mode_data_dir` has
   `CONTEXT_MODE_DATA_DIR` resolved and validated the same way; both values are
   validated *before* either is exported, so a give-up leaves no storage variable
   behind for a later reader to mistake for the feature being on.
5. Strip every registered agent **except** the current one.
6. `agent_call "${agent}" context_mode_wire`; on failure strip that agent and return
   0 with the feature off; on success export `_CONTEXT_MODE_WIRED=1`.

Step 5 is a behaviour change worth naming. Today the Claude wiring is stripped only
on the non-Claude branch, which is correct only while exactly one agent wires. The
invariant is "at most one agent's wiring exists in this session directory at a
time," and the loop states it directly. It matters because `settings.json`,
`.claude.json` and `opencode.jsonc` live in the bind-mounted session directory and
nothing regenerates them, so wiring written by one image outlives it.

Ordering in `container/entrypoint.sh` is unchanged: `context_mode_setup` still runs
after the per-agent `container_setup` loop (so opencode's regenerated
`opencode.jsonc` is already in place) and after `codegraph_setup` (so both MCP
entries merge into a settled `.claude.json` rather than racing for it).

## Claude implementation: `agents/claude/context-mode.sh`

New file, sourced by `agents/claude/manifest.sh` the way
`agent_opencode_container_setup` sources `setup.sh`. It receives, moved verbatim,
the existing `context_mode_wire_hooks` / MCP-entry writers and
`context_mode_strip_session_wiring` from `container/context-mode-setup.sh`, plus the
four constants: `CONTEXT_MODE_MATCHER`, `CONTEXT_MODE_POST_MATCHER`,
`CONTEXT_MODE_MCP_NAME`, and the hook table.

`CONTEXT_MODE_BIN` stays in `container/context-mode-setup.sh` — it names the shim
the image build generates, which is feature-level and shared by every agent and by
`container/context-mode-summary.sh`.

Behaviour is unchanged, including the both-stanzas-land-or-neither invariant across
`settings.json` and `.claude.json`, and every give-up path stripping earlier wiring.
`tests/context-mode.venom.yml` must pass unmodified apart from the strip-all-others
addition; a passing suite after a pure move is the evidence that the move was pure.
It took one further change that is not about the move: every case now clears the
ambient `_CONTEXT_MODE_WIRED` / `CONTEXT_MODE_DIR` / `RIOTBOX_CONTEXT_MODE` /
`RIOTBOX_AGENT` a wired RiotBox session exports, because cases asserting on those
being *absent* passed in CI and failed for anyone running the suite from the
environment this feature is developed in.

## opencode implementation: `agents/opencode/context-mode.sh`

`context_mode_store_dir` prints
`${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/context-mode`, and
`context_mode_data_dir` prints its parent,
`${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}`. The parent, not the store
itself: upstream composes `<root>/context-mode/sessions` from
`CONTEXT_MODE_DATA_DIR`, while `CONTEXT_MODE_DIR` names that `context-mode`
directory outright. One consequence to know about — upstream's
`BaseAdapter.getMemoryDir()` follows the same root, so opencode's auto-memory sits
at `<config>/context-mode/memory` rather than `<config>/memory`. Both are inside
the session directory and opencode has never had Context Mode before this, so
nothing is orphaned by it.

`context_mode_wire` writes one file,
`${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}/plugins/riotbox-context-mode.js`.
It does **not** call `json_write_atomic` — that writer takes JSON — but it follows
the same discipline: stage in the target directory, then rename, so a reader never
sees a partial file. The shim holds no secrets, so it takes the umask rather than
`json_write_atomic`'s 0600. Content:

```js
// riotbox-generated: context-mode shim — do not edit.
// Pinned to the copy vendored in the image. An npm entry in opencode.jsonc would
// make opencode bun-install context-mode from the registry at startup, which needs
// network (RIOTBOX_NETWORK=none forbids it) and floats the version off the image
// pin. Same reasoning as the hand-written Claude stanzas: see
// container/context-mode-setup.sh.
export { ContextModePlugin } from "<CONTEXT_MODE_PKG>/build/adapters/opencode/plugin.js"
```

`<CONTEXT_MODE_PKG>` is the vendored package root, derived from the same pinned
interpreter path the image build uses for `CONTEXT_MODE_BIN` so the path written is
the path a session reads.

The first line is a **marker**, and it is load-bearing in both directions:

- `context_mode_wire` refuses to overwrite a file at that path whose first line is
  not the marker. It warns naming the file and returns non-zero, so the session runs
  with the feature off rather than destroying a user's plugin.
- `context_mode_strip` deletes that path **only** when the marker is present, and
  touches nothing else in `plugins/`.

Upstream has already paid for this lesson: `hooks/pretooluse.mjs:15-18` records an
earlier version deleting user-written hook configs without consent as "the
documented cause of the regression." RiotBox's stripper must not become the second
instance.

**Duplicate-load guard.** `agents/opencode/setup.sh`, which already force-merges
`permission`, `share`, `autoupdate` and `instructions` into the generated
`opencode.jsonc`, gains one jq clause: when `RIOTBOX_CONTEXT_MODE=1`, drop any
`context-mode` or `context-mode@<version>` entry from the `plugin` array and warn
naming the file. Without it, a user whose host config carries that entry loads two
adapter instances — duplicate tool registration and double-fired hooks.

Filtering here rather than from `context-mode.sh` is deliberate: it keeps a single
writer for `opencode.jsonc`, whose exact `//`-banner-plus-plain-JSON shape
`agents/opencode/headroom-exec.sh` splits with line-level grep. The cost is one line
of Context Mode awareness in the generator, which is cheaper than two writers
contending for that file.

**`--pure` guard.** `opencode --pure` runs without external plugins, so a session
could report Context Mode as wired while nothing engaged — the exact ambiguity the
always-print exit report exists to prevent. `agent_opencode_wrapper_inject` warns
when `--pure` appears in argv and `RIOTBOX_CONTEXT_MODE=1`. It warns and continues:
`--pure` is an explicit user instruction and RiotBox does not override it.

The warning goes to **stderr, and argv is returned unchanged**. That verb's stdout
is the NUL-terminated argv the wrapper reads back with `mapfile -d ''`
(`container/agent-wrapper.sh:90`); a stray line on stdout becomes an argument.

## Build-time guards: `Containerfile`

The layer at `Containerfile:852-882` currently sources
`container/context-mode-setup.sh`, asserts four constants are still defined, and
greps the installed bundle against them so an upstream rename fails the build rather
than a user session. Moving the Claude constants without moving the guard would
leave it asserting nothing.

Each agent's `context-mode.sh` therefore defines
`agent_<name>_context_mode_build_assert`, which greps the installed bundle for the
contract that agent depends on and exits non-zero with a diagnostic naming the
pinned version:

- **claude** — the existing checks, unchanged: `CONTEXT_MODE_MCP_NAME` in
  `hooks/core/tool-naming.mjs`, the matchers against upstream's
  `PRE_TOOL_USE_MATCHERS`, and the hook-event set in `hooks/hooks.json`.
- **opencode** — `build/adapters/opencode/plugin.js` exists and exports
  `ContextModePlugin`, and `package.json`'s `exports` still maps `./plugin` to it.

The build layer sources `agents/registry.sh` and calls the verb for every registered
agent that defines it, so a third agent's guard costs nothing at the Containerfile.
No layer reordering is needed: `COPY agents/` is already at `Containerfile:582`,
ahead of the Context Mode layer at 852. `CONTEXT_MODE_BIN` and
`CONTEXT_MODE_STATS_BIN` assertions stay where they are.

## Tests

New suite `tests/context-mode-opencode.venom.yml`, shell-level and hermetic — no
opencode process is started, matching the existing Context Mode suites:

- shim written to `plugins/`, with the absolute vendored path and the marker line
- nothing written to the singular `plugin/`
- rerunning `context_mode_wire` is idempotent — identical content, one file
- `RIOTBOX_CONTEXT_MODE` unset or `0` strips the shim
- agent switch strips the other agent's wiring, both directions
- a foreign file at the shim path is neither overwritten nor deleted, and the
  session degrades to the feature off
- unrelated files in `plugins/` survive strip
- `context_mode_store_dir` prints the opencode path and `CONTEXT_MODE_DIR` is
  exported to it; `CONTEXT_MODE_DATA_DIR` is exported to its parent, asserted as
  the session-DB path upstream composes from it, and is absent on the Claude path
- the merged `opencode.jsonc` loses a `context-mode` npm entry when the flag is on,
  keeps it when off, and retains its banner-plus-body shape either way
- a registered agent with no `context_mode_wire` verb warns, strips, and runs off
- `--pure` plus `RIOTBOX_CONTEXT_MODE=1` warns on stderr and leaves argv byte-identical

Extended rather than duplicated: `tests/context-mode.venom.yml` for the moved Claude
path and the strip-all-others rule, `tests/context-mode-ledger.venom.yml` for a
record carrying `agent=opencode`, `tests/doctor-context-mode.venom.yml` for a doctor
warning when the selected agent has no verb.

## Documentation

- **`README.md`** — Context Mode is no longer Claude-only. Document per-agent
  support, the pinned-shim rationale, the per-agent store locations, and the
  opencode degradations: no `SessionStart` upstream, so resume attribution is
  weaker, and tools arrive in-process rather than over MCP.
- **`THREAT_MODEL.md`** — three additions:
  - **Wider blast radius.** The opencode adapter runs *in-process inside the
    agent* under bun, holding the plugin API's `client` handle, where the Claude
    path uses short-lived hook processes and an MCP child process. Same ELv2 code,
    more reach.
  - **A second store location** holding verbatim tool output.
  - **`plugins/` lives in the bind-mounted session config,** so write access there
    is code execution inside the agent process.
  - *Correction:* this originally also claimed a `$` shell handle. It was wrong
    and was never written into `THREAT_MODEL.md` — the adapter's typed plugin
    input is `{ client: { app: { log } }, directory: string }` (`plugin.d.ts`,
    `PluginContext`) and `plugin.js:190` uses `ctx.client.app.log`. The in-process
    placement is what widens the surface, not a handed-over shell.
- **`docs/dev/decisions/context-mode-adoption.md`** — the "What actually shipped" section
  states as fact that no opencode adapter is wired and that
  `tests/context-mode-opencode.venom.yml` has nothing to exercise. Both stop being
  true; replace with what was verified here.
- **`docs/dev/agent-contract.md`** — the new optional verbs.
- **`libexec/launch.sh`** — the help text for `RIOTBOX_CONTEXT_MODE=1`.

## Risks

1. **The store pin is two variables, and it is still source-read rather than
   runtime-observed.** This risk asked the implementation to confirm the pin by
   observation. That did not happen — `podman build` does not work in the
   development container (see the verification note at the end of this section), so
   no opencode session was ever started and no store was ever created. Reading the
   source again did find something the design had missed:

   - `CONTEXT_MODE_DIR` pins `sessions/` and `content/` for the `ctx_*` tools, via
     `resolveSessionStorageDir` / `resolveContentStorageDir` (`build/session/db.js`).
     That much the design had right.
   - The plugin's **own session DB** — the same verbatim tool output — never reads
     it. `plugin.js:139` passes `adapter.getSessionDir()`, and that
     (`build/adapters/opencode/index.js:193`) prefers `resolveContextModeDataRoot()`,
     which reads **`CONTEXT_MODE_DATA_DIR`** (`build/adapters/base.js:50`) and
     otherwise falls back to `join(getConfigDir(), "context-mode", "sessions")`.
     `OpenCodeAdapter.getConfigDir()` derives from `XDG_CONFIG_HOME`, which the image
     never sets, so it lands on `~/.config/opencode` — the session bind mount, but by
     coincidence rather than because RiotBox said so. Nothing was landing in the
     wrong place; the *guarantee* the pin exists to provide simply was not there.

   Fixed by exporting `CONTEXT_MODE_DATA_DIR` alongside `CONTEXT_MODE_DIR`, from the
   new `context_mode_data_dir` verb, at the parent of the store directory.
   `tests/context-mode-opencode.venom.yml` asserts both variables and the session-DB
   path upstream composes from the second, so an off-by-one on the `context-mode`
   path segment fails the suite.

   **What remains unobserved.** Everything downstream of the exports: no opencode
   process has read either variable in this environment, no `sessions/*.db` or
   `content/` directory has been created, and the exit report has never rendered a
   non-zero saving for an opencode session. The pin is asserted at the shell seam —
   the values a session exports — and read from upstream source on the other side of
   it. What still needs a real session to prove is that upstream honours them where
   the source says it does. The failure mode if it does not is unchanged and mild:
   the store lands in the session config directory anyway, because that is also the
   fallback. The pin's value is against a *future* change to that fallback, which is
   exactly the thing no amount of testing today can observe.

   The pin also holds only while upstream keeps both names. Unlike the matchers, the
   MCP server name and the `hook <platform> <event>` dispatcher, nothing in the image
   build greps the installed bundle for either variable, so a version bump that
   renamed or dropped one would surface in a user session rather than at build time.
2. **The in-process paradigm has no matcher to audit.** On Claude, `CONTEXT_MODE_MATCHER`
   is a reviewable list of which tools reach the hook, asserted against upstream at
   build time. On opencode, routing enforcement lives inside
   `tool.execute.before` with nothing equivalent to inspect or pin. A version bump
   can change which tools are intercepted with no build-time signal.
3. **Version drift is now two-sided.** Bumping `CONTEXT_MODE_VERSION` can break the
   plugin export or the bun path, and bumping opencode can change the plugin
   directory, the plugin API, or the bundled zod that
   `build/adapters/opencode/zod3tov4.js` shims. The build assertions cover the
   first; the second surfaces only in a user session.
4. **opencode cannot currently bootstrap in this image.**
   `~/.config/opencode/agents/cavecrew-reviewer.md` declares `tools:` as a YAML list
   where opencode 1.18.10's schema requires an object, which aborts instance
   bootstrap with `ConfigInvalidError`. The venom suites are unaffected, but any
   manual end-to-end check is blocked until it is fixed. Out of scope here.

### What was verified, and how

Stated plainly because several claims above are source readings that look like
observations if the distinction is not kept:

- **Run and passing.** `task lint`, `task test:lint`, and the venom suites, which
  are shell-level and hermetic — they source the files under test, drive the verbs
  in a throwaway `HOME`, and assert on what a session would export and write. That
  is the seam the pin is asserted at.
- **Read from source, not run.** Everything upstream of that seam and everything
  downstream of it: which variables `context-mode@1.0.169` reads and what it
  composes from them, that the adapter loads under opencode's bun, and that the
  `ctx_*` tools register in-process. The adapter-loads and tools-register claims
  come from the probe run while this design was written; the storage claims come
  from reading `build/` at the pinned version.
- **Not attempted, and why.** No image was built and no session was run.
  `task container:build` fails in this development container before it reads the
  `Containerfile` — `Error: mounting an overlay over build context directory: …
  userxattr: invalid argument` from buildah, an environment limitation, not a
  defect in the build. The `Containerfile`'s per-agent
  `context_mode_build_assert` calls are therefore also unexercised: they are
  asserted by review of the shell they run, not by a build that ran them.

## Non-goals

- **No end-to-end integration suite.** Exercising the hooks needs a model and
  credentials CI does not have. Coverage is shell-level, matching the existing
  Context Mode suites.
- **No shared cross-agent store.** Considered and declined; see
  [What carries over](#what-carries-over-and-what-does-not).
- **No change to the mutual exclusion with headroom.** The launcher and doctor
  already refuse the pair for every agent.
- **No `riotbox ctx-stats` changes.** The ledger already distinguishes runs by
  agent.
- **Context Mode does not become a default.** The head-to-head measurement
  [the evaluation demands](context-mode-adoption.md#decision) still
  has not been made, and adding a second agent does not make it.
- **No fix for the invalid agent file in risk 4.**
