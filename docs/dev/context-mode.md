# How Context Mode works in RiotBox

Maintainer-facing. This describes the integration **as it stands today** — what
gets wired, by whom, what it costs, and where it is still unproven.

- **Using the feature** → [README § Context Mode](../../README.md#context-mode-opt-in)
- **Why we adopted it, and on what terms** → [decisions/context-mode-adoption.md](decisions/context-mode-adoption.md)
- **Why RiotBox stopped writing Claude's wiring** → [decisions/context-mode-native-plugin.md](decisions/context-mode-native-plugin.md)
- **Adding support for a new agent** → [agent-contract.md § Context Mode verbs](agent-contract.md#optional-verbs-context-mode)

Context Mode is opt-in behind `RIOTBOX_CONTEXT_MODE=1`, mutually exclusive with
`RIOTBOX_HEADROOM=1`, and is **not** a default. The head-to-head measurement that
would justify making it one has not been made.

## The shape of the integration

Seven layers, each with one job:

| Layer | Where | Job |
|---|---|---|
| Gate | `libexec/launch.sh` | Accept the literal `1` only; refuse the headroom pair |
| Install | `Containerfile` | Pin the package and its interpreter; stage upstream's plugin at a pinned ref with its locked runtime dependencies; run the per-agent build guards and the routing probe |
| Sandbox runtime | `Containerfile` (the bun layer) | Supply the JS/TS interpreter `ctx_execute` needs. Without bun on `PATH`, `ctx_execute` reports `TypeScript: not available` and TS snippets cannot run at all. It is **not** on the hook path — those commands name the pinned Node |
| Registration | `container/plugin-setup.sh` | Point this session's plugin registry at the staged tree, in place, and re-assert it after the host-plugin merge |
| Orchestration | `container/context-mode-setup.sh` | Resolve the store, pin the platform token, wire the current agent if it authors wiring, strip every other agent |
| Per-agent support | `agents/<name>/context-mode.sh` | The agent-shaped part: storage pins, platform token, stripper, build guard — plus wiring, for an agent that still writes its own |
| Reporting | `container/context-mode-summary.sh`, `scripts/ctx-stats.sh` | Exit report per session; ledger aggregated across sessions |

The orchestration layer **names no agent.** Each agent supplies some subset of
`context_mode_store_dir`, `context_mode_data_dir`, `context_mode_platform`,
`context_mode_wire`, `context_mode_strip` and `context_mode_build_assert`, and
every caller probes with `declare -F` before calling.

**The probe for "does this agent have support at all" is `store_dir`, not
`wire`.** Claude Code no longer has a wire verb — the plugin is the wiring — so
a probe on `wire` would now read Claude as unsupported and turn the feature off
on the agent it is best supported on. An agent implementing none of the verbs is
still not an error: the session warns, strips whatever an earlier session left in
the same session directory, and runs with the feature off.

## How each agent reaches Context Mode

The two implementations are deliberately different shapes, and after this branch
they no longer even share the question of who writes the wiring. The registry
contract is about the lifecycle, not about what wiring looks like.

### Claude Code — upstream's plugin, registered rather than authored

RiotBox writes no Claude wiring at all. The image clones upstream's marketplace
plugin at `CONTEXT_MODE_PLUGIN_REF`, checks the clone against
`CONTEXT_MODE_PLUGIN_SHA` so a moved tag fails the build, installs its runtime
dependencies with `npm ci --omit=dev` against the committed
`container/context-mode-package-lock.json`, rewrites
the bare `node` in `hooks/hooks.json` and `.claude-plugin/plugin.json` to the
pinned interpreter, and leaves the tree at
`/home/llm/.riotbox/context-mode-plugin/<ref>`.
`container/plugin-setup.sh` then records that path in the session's
`installed_plugins.json` and `known_marketplaces.json`. The hooks and the MCP
server both come from the plugin's own manifests.

The hook set is unchanged in effect — `PreToolUse`, `PostToolUse`, `PreCompact`,
`SessionStart`, `UserPromptSubmit`, `Stop`, all six — but it is now upstream's
declaration of them rather than RiotBox's transcription. What the plugin adds
over the npm package is the surface the package does not carry: the
`/context-mode:*` slash commands, which are the eight bundled skills under
`skills/` that `.claude-plugin/plugin.json` declares with `"skills": "./skills/"`.
There is no `commands/` directory upstream.

Three consequences worth knowing before debugging a session:

- **The tree is registered, not copied.** It is 60 MB and `~/.claude` is a
  per-session-key bind mount of a host directory, so a copy would pay that disk
  once per project set. The registry entry names the image path and the tree is
  read in place, which also means a rebuild at a new ref moves it —
  `context_mode_plugin_register` rebuilds the entry from what is staged now
  rather than trusting what a session recorded.
- **A host-installed `context-mode` is deliberately excluded from the host-plugin
  copy.** `plugin_setup` merges `~/.host-plugins` over the registry with host
  entries winning, so without the exclusion a host tree — one that never went
  through the interpreter rewrite or the dependency install — would displace the
  staged one. The registration is re-asserted after the merge for the same
  reason. The exclusion is narrow and it is **silent at run time**: it fires only
  where both registry files already name the staged tree — that is, where step 3
  really did register it, read back out of what it wrote rather than re-decided —
  and it prints nothing when it does. The session's own output therefore never
  distinguishes "your host copy was passed over" from "you had none" — README
  § Plugins states the carve-out ahead of time, but a session that took it says
  so nowhere. The opencode side of the same decision does warn on stderr; this
  one has no equivalent, and adding one would mean a line on every enabled
  Claude session that has a host copy.
- **`RIOTBOX_CONTEXT_MODE` governs RiotBox's own staged registration, not a
  `context-mode` the user installed on the host.** With the toggle off,
  `context_mode_plugin_unregister` removes what RiotBox registered and
  deliberately spares a host entry, the host-plugin copy takes that tree as it
  takes any other, and the `enabledPlugins` sync switches it on. That is by
  design — a host install is the user's own plugin choice — and it is why
  `context_mode_plugin_installed` asks the registry rather than asking whether
  RiotBox staged anything. The headroom mutual exclusion is not a second gate on
  any of this: `libexec/launch.sh` refuses the pair before mount setup and exits
  1, and `riotbox doctor` fails it with rc 22, so no session starts at all.

Two couplings a maintainer should not break by accident:

- **Toggle-off cleanliness depends on step 1 of `plugin_setup`.** Unregistering
  removes the entry from `installed_plugins.json` and `known_marketplaces.json`
  and touches `.enabledPlugins` not at all. What clears a stale
  `"context-mode@context-mode": true` from an earlier enabled session is step 1
  deleting `.enabledPlugins` wholesale, before step 7 rebuilds it from the
  registry keys. Stop step 1 doing that and the toggle leaks: a session with
  Context Mode off keeps an enabled entry for a plugin that is no longer
  registered.
- **The `false` a user writes into `.enabledPlugins` does not survive to be
  read.** `context_mode_plugin_installed` refuses an explicitly disabled plugin,
  which is correct whenever it fires, but the same two steps rewrite that key
  before it runs. The check is kept because it becomes load-bearing the day they
  stop. See [Known gaps](#known-gaps).

Four verbs are left in `agents/claude/context-mode.sh` —
`context_mode_store_dir`, `context_mode_platform`, `context_mode_strip` and
`context_mode_build_assert` — and no `context_mode_wire`. The stripper outlived the
wiring it used to undo, because session directories outlive images: a directory
wired by the previous release still holds six hand-authored hook stanzas and an
`mcpServers` entry, `settings.json` is never synced from the host, and nothing
else removes them. Left in place beside the registered plugin they would dispatch
every event twice against one server name two writers claim.

### opencode — one generated plugin file

No hooks, no MCP server. RiotBox writes a single file,
`~/.config/opencode/plugins/riotbox-context-mode.js`, re-exporting the vendored
adapter by absolute path. Notes that cost time to establish:

- **The directory is `plugins/`, plural.** A file placed in the singular
  `plugin/` never loads.
- **The eleven `ctx_*` tools arrive in-process, not over MCP.** The plugin imports
  `build/server.js` with `CONTEXT_MODE_EMBEDDED_PLUGIN_TOOLS=1` and registers each
  entry of `REGISTERED_CTX_TOOLS` as a native opencode tool.
- **The Node floor does not apply here.** The adapter runs under opencode's
  embedded bun (1.3.14), whose SQLite is 3.53.0 with FTS5 compiled in.
  `build/db-base.js` bridges `bun:sqlite` to the better-sqlite3 API, so the native
  addon that forced `ARG CONTEXT_MODE_NODE` is never loaded.
- **That same env var skips upstream's `main()`,** where the `registry.npmjs.org`
  version check lives — so the one residual outbound GET has no counterpart on
  this path.

## The platform token is pinned, not detected

`CONTEXT_MODE_PLATFORM` is exported from `context_mode_platform` before anything
dispatches a hook — `claude-code` for Claude, `opencode` for opencode.

Upstream's `detectPlatform()` resolves the platform from whichever agent config
it finds, and every RiotBox image ships every supported agent, so it has more
than one to choose between and no way to know which is running. When it lands on
an in-process plugin platform, `getPluginRoot()` returns
`~/.cache/<platform>/packages/context-mode@latest/node_modules/context-mode` — a
path no RiotBox install populates — and the hook's import throws.

The throw is what makes this worth a section. `hookDispatch` (`src/cli.ts:158`
upstream) closes fd 2 and reopens it on `/dev/null` before dispatching, because
Claude Code reads hook stderr as failure. So the import error goes nowhere: the
session routes nothing, and the toggle, `riotbox doctor` and the exit report all
still report the feature as on. Upstream pins the same variable for its own
Copilot CLI bundle, for the same co-install reason.

## Two storage pins, not one

`CONTEXT_MODE_DIR` pins `sessions/` and `content/` behind the `ctx_*` tools, and
nothing else. An agent whose support runs as an in-process plugin has a **second**
store — the plugin's own session DB — which upstream resolves through
`adapter.getSessionDir()`, reading `CONTEXT_MODE_DATA_DIR` and otherwise falling
back to the agent's config directory.

- **Claude does not implement `context_mode_data_dir`.** `CLAUDE_CONFIG_DIR` is
  already exported at the session bind mount by `container/entrypoint.sh`, so the
  fallback is already pinned.
- **opencode does.** Its fallback reads `XDG_CONFIG_HOME`, which the image never
  sets, landing on `~/.config/opencode` — the session mount, but by coincidence
  rather than by anything RiotBox stated.

Both stores hold verbatim tool output, so both must sit inside the bind-mounted
session directory: somewhere `riotbox session-remove` deletes, and somewhere that
cannot vanish onto the container overlay at exit.

## Which tools are actually intercepted

At `v1.0.169` the `PreToolUse` matcher set in the staged plugin's
`hooks/hooks.json` names:

`Bash`, `WebFetch`, `Read`, `Grep`, `Agent`, and every MCP tool.

**`WebSearch` and `Glob` are not in it.** No `PreToolUse` hook fires for them and
their output lands in the transcript in full. `Agent` — subagent calls — *is*
intercepted.

This corrects the adoption evaluation, which claimed WebSearch was hard-denied and
listed Glob among the routed tools. Both were wrong.

**The build asserts that list, against a committed expectation.** RiotBox used to
keep `CONTEXT_MODE_MATCHER` and `CONTEXT_MODE_POST_MATCHER` as verbatim copies of
upstream's arrays in `agents/claude/context-mode.sh` and compare them to
`hooks/hooks.json` for equality at build time. Those constants went with the
hand-authored wiring, and for one commit nothing replaced them — a version bump
that quietly stopped intercepting `Read` would have surfaced in a user session
rather than in the build.

What replaces them is `container/context-mode-hooks-expected.json`: the same
event-and-matcher set, but generated from the staged tree by the one-line `jq`
recipe in the `Containerfile` instead of transcribed by hand, and committed the
way the plugin lockfile is. The staging layer projects the staged `hooks.json`
down to `{event: [matchers]}` and requires equality before `npm ci` runs, so a
tool added or dropped upstream fails the image build again, and the refresh at a
version bump is a command whose diff a reviewer reads rather than two arrays
somebody retypes. On opencode there is no such file — routing enforcement lives
inside `tool.execute.before`.

The check is deliberately blind to the hook *commands*, which the interpreter
substitution below rewrites; it compares only which events are wired and which
tools each intercepts. The routing probe covers the other half: that the
`WebFetch` route actually executes and returns a decision.

## The routing probe

The build guard that went with the wiring was a grep of the dispatcher's
`--help`, and the `Containerfile` said outright what it was worth: the dispatcher
"exits 0 and prints nothing for an event that does not exist, exactly as a valid
event fed empty stdin does — so invoking the dispatcher can only ever prove that
the CLI runs." A Context Mode that reported itself enabled and routed nothing
passed it.

The replacement runs the real thing. It reads the `PreToolUse` command for
`WebFetch` out of the staged `hooks.json` — whatever the interpreter rewrite
produced — feeds it a real `WebFetch` payload, and requires a
`hookSpecificOutput.permissionDecision` back. Two details are load-bearing and
should not be simplified away:

- **A seeded MCP sentinel directory.** Every routing decision passes through
  `mcpRedirect()`, which returns `null` unless `isMCPReady()` finds a
  `context-mode-mcp-ready-<PID>` file for a live process. No MCP server runs
  during a build, so the probe seeds one via upstream's own
  `CONTEXT_MODE_MCP_SENTINEL_DIR` override, pointing at a private directory. It
  has to be private: upstream's default scan root is a hardcoded `/tmp`, and an
  early version of this probe run on a developer host "passed" by reading that
  session's own running server's sentinel. The unseeded control run — which must
  return nothing — is what makes the seeded run mean anything.
- **`PATH=/usr/bin:/bin`.** With the build's PATH inherited, an un-rewritten tree
  *passes*: the `WebFetch` route is pure JS and Node 20 runs it. Worse, it
  corrupts the tree it just checked — `ensure-deps`' ABI heal fires below Node
  22.5, `npm rebuild better-sqlite3` runs with the build's network, and the tree
  comes back carrying the devDependencies `--omit=dev` excluded and a
  `better-sqlite3` the pinned Node can no longer load, after the loader check
  already passed. With no `node` resolvable, an un-rewritten command produces
  nothing and fails the layer.

## Reporting

### Why our savings figure differs from upstream's

The exit report prints `bytesAvoided` alone as *kept out*, the `bytesReturned`
delta beside it as a re-read cost, and **no percentage**. Upstream's `statusline`
and `ctx_stats` report `bytesAvoided + snapshotBytes + eventDataBytes` over that
plus `bytesReturned`.

The divergence is deliberate, because upstream's formula counts things that are
not savings:

- `eventDataBytes` is `SUM(LENGTH(data))` over every `session_events` row — the
  continuity bookkeeping each `PostToolUse` writes whether or not anything was
  redirected.
- `snapshotBytes` is the `PreCompact` resume snapshot, which is context added
  *back* after a compact.

With only retrieval cost in the denominator, the percentage is pinned near 100% by
construction and reads **lowest exactly when the feature is working hardest**. A
session that redirected nothing printed `11.7 KB kept out (100%)`.

Ours is the saving; theirs is the saving plus the feature's own accounting.

### Why a zero is always printed

An earlier version suppressed the report when nothing was saved, on the reasoning
that a zero is not a result worth a block of output. Using it disproved that.

The report is the only evidence a session leaves, so "no report" had to carry two
unrelated meanings at once — *the feature engaged and saved nothing*, and *the
feature never engaged*. The first is precisely the measurement we want; the second
is a bug. Nothing on screen could tell them apart.

The renderer now always prints for a wired session, with the hook-log figure
beside the zero as the proof-of-life signal that distinguishes the two cases.

### The "hook log on disk" line, and why the unit matters

`eventDataBytes` is labelled **hook log on disk**, and the unit is load-bearing.
The label first read "event bookkeeping", which put a number that is not context
bytes on a line of context bytes and invited it to be read as a token cost.

`session_events` rows are consumed only by aggregate queries (`COUNT`,
`SUM(LENGTH(data))`, `GROUP BY category`) and by `getMcpToolUsage`. Nothing feeds
them to a hook's `additionalContext`, so they never reach a model's context and
cost zero tokens. It is never added to the saving.

### The cross-session ledger

Upstream prunes its counters after seven days, so totals beyond that window have
to be captured at session exit — they cannot be re-derived. One JSON record per
run lands in a user-owned directory outside `RIOTBOX_DATA_DIR`, aggregated by
`riotbox ctx-stats`.

Both the report and the ledger are agent-neutral: the store resolves through
`CONTEXT_MODE_DIR`, and every record stamps `agent`, so opencode runs aggregate
alongside Claude ones with no schema bump. See
[decisions/context-mode-ledger.md](decisions/context-mode-ledger.md) for the
storage shape, the audit boundary that excludes read-only sessions, and the
reader's validation posture.

## What it costs

**`PostToolUse` costs ~112 ms per tool call, and interpreter startup is nearly all
of it.** This is the one cost of the full hook set that could plausibly outweigh
its benefit, because `PostToolUse` fires on nearly every tool call and each fire
spawns the pinned Node.

The figure predates the move to the plugin and still stands: the hook scripts are
the same files under the same interpreter. What changed is who names the command
— upstream's `hooks.json` rather than a stanza RiotBox wrote — not what runs.

Measured against `context-mode@1.0.169` inside `quay.io/centos/centos:stream10` on
Node v22.23.1, the version `ARG CONTEXT_MODE_NODE` pinned at the time — 50
invocations per
condition, each piping a 2 KB `Write` payload that lands a row in
`session_events`:

| Condition | Cost |
|---|---|
| Empty store | 112.6 ms/call |
| Store holding 350 events, WAL open | 112.5 ms/call |
| `node -e ''` alone | 64.7 ms/call |
| Module graph imported, DB untouched | 94.7 ms/call |

So roughly 85% of the wall clock is interpreter startup plus module load, and only
~17 ms is the SQLite work — upstream's "<20ms" claim, honoured. Warming the store
changes nothing measurable.

In the units a long run feels: **an agent making 2,000 tool calls pays about 3.7
minutes of wall clock**, serialized into the tool-call path. That scales with
Node's startup time on the host, not with store size, so a slower machine pays
proportionally more and no amount of pruning helps.

At ~112 ms the hook stays — it is what buys the session DB that `SessionStart`
replays and `PreCompact` snapshots. If it ever needs to come down, dropping
`PostToolUse` alone retains `UserPromptSubmit`, `PreCompact` and `Stop`, which fire
orders of magnitude less often.

**A plugin without its dependencies staged costs 120 seconds per hook, forever.**
Upstream's bundles mark `better-sqlite3`, `turndown`, `turndown-plugin-gfm` and
`@mixmark-io/domino` external, so a bare clone sends every hook invocation into
`hooks/ensure-deps.mjs`. Under `--network=none` that spends its own `execSync`
timeout — 120 s — fails, returns a decision anyway with rc=0, and leaves the FTS5
store unavailable, which is the entire feature. Staging the dependencies at
build time brings the same hook to **62 ms**.

The interpreter rewrite does not prevent that on its own: `ensure-deps` gates on
`existsSync(node_modules/better-sqlite3)` with no version condition, and
upstream's own comment says `hasModernSqlite()` exists "to skip the SIGSEGV-prone
child-process probe on modern Node, but NOT to skip installing better-sqlite3."

| Tree | Size |
|---|---|
| Bare clone | 14 MB |
| Staged with runtime dependencies (`--omit=dev`) | 60 MB |
| After `ensure-deps` runs — it resolves devDependencies too | 148 MB |

**`npm ci --omit=dev` against a lockfile RiotBox generates.** Upstream ships no
`package-lock.json` — only `bun.lock`, which npm cannot read — so the lockfile is
generated against the pinned commit with `npm install --package-lock-only` and
committed as `container/context-mode-package-lock.json`. Every version in the
139-package tree is then fixed and every entry carries an integrity hash npm
verifies on download. `bun install --frozen-lockfile --production` is not the way
out: `package.json` declares no `trustedDependencies`, so bun skips
`better-sqlite3`'s prebuild and falls through to node-gyp against its spoofed
`node -v v24.3.0`.

What `npm ci` does **not** do is notice that the lockfile is stale. It fails only
when the dependency set or its ranges disagree with `package.json`, and measured
on npm 11.9.0 a lockfile at `1.0.169` under a `package.json` at `1.0.170`
installs green, because upstream's patch releases rarely move a `^`. The check
that does catch it is the three-way ref/lockfile/package comparison in
`tests/context-mode.venom.yml`. The lockfile also carries the same limit the bun
digests do: the integrity hashes were transcribed from one resolution, so they
catch a republished tarball and not a dependency that was already malicious when
they were recorded.

**A version bump moves four things, not two.** `CONTEXT_MODE_VERSION`,
`CONTEXT_MODE_PLUGIN_REF` and `CONTEXT_MODE_PLUGIN_SHA` have to name one
release, and the lockfile has to be regenerated against that release in the same
pass. The step-by-step recipe is in the `Containerfile`, immediately above the
`CONTEXT_MODE_PLUGIN_REF` ARG, and it is the only copy — do not restate it
elsewhere. The step it exists for is the one that is easy to get wrong:
upstream's tags are **annotated**, so `git ls-remote` needs the `^{}` deref to
report the commit a clone will land on. The bare ref names the tag object
instead, and a `CONTEXT_MODE_PLUGIN_SHA` pinned to that fails the staging layer
against `git rev-parse HEAD`.

## Known gaps

| Gap | Effect | Status |
|---|---|---|
| No head-to-head measurement against a real session | Cannot justify making it a default | Open; the reason it stays opt-in |
| The image has never been built | The clone, the dependency install, the interpreter rewrites and the routing probe have never run as a `podman build` layer | Blocked: `podman build` fails in the dev container with `userxattr: invalid argument`. Every layer body was extracted and run under `podman run` instead |
| The staged plugin's lockfile can go stale without failing the build | It is RiotBox-generated, so a ref bump that forgets to regenerate `container/context-mode-package-lock.json` stages the previous release's dependency resolution. `npm ci` fails only when the dependency set or its ranges disagree with `package.json`, which a patch bump usually does not move | Reproducibility itself is closed. Staleness is caught by the three-way version check in `tests/context-mode.venom.yml` — a test, not the build layer, so a build run outside `task test` would not see it |
| The lockfile does not cover the staged tree's native binary | `better-sqlite3` is `hasInstallScript` and its `prebuild-install` dependency fetches a prebuilt `better_sqlite3.node` from GitHub releases, outside the lockfile's integrity hashes and with no digest pinned here. The build's loader check proves it imports, not that it is what upstream published. Every enabled session's hooks load it | Open, tracked under RIOTBOX-20260312-001 in `THREAT_MODEL.md`. `--ignore-scripts` is not the fix on its own — without the prebuild the install falls through to node-gyp, which this stage has no toolchain for |
| The matcher set is asserted against a committed file, not against upstream | The staging layer requires the staged `hooks.json` to equal `container/context-mode-hooks-expected.json`, so a tool added or dropped upstream fails the build — but the expectation is RiotBox-generated, so a ref bump that regenerates it without reading the diff accepts the change silently. Same shape of limit as the lockfile row above | Closed at build time on Claude; the review of the regenerated diff is the part no gate can take. opencode has no equivalent — routing lives in `tool.execute.before`. See [Which tools are actually intercepted](#which-tools-are-actually-intercepted) |
| Every plugin the user disabled is re-enabled at session start | `plugin_setup` step 1 deletes `.enabledPlugins` wholesale whenever it is present and step 7 rebuilds it from the registry keys as all-`true`, so a `false` set in an earlier session never survives. Not specific to Context Mode — it clobbers every plugin | Open, and not a Context Mode decision to take. The behaviour is pinned by "a session start re-enables a plugin the user switched off" in `tests/context-mode.venom.yml`, and the argument for raising it separately is in the `context_mode_plugin_installed` header |
| A corrupt `known_marketplaces.json` can leave a dangling enabled registration | `context_mode_plugin_register` writes the registry entry and the marketplace entry as one fact — where this session's Context Mode is — and refuses to write either when it cannot write both. So a marketplace file it cannot parse blocks the reconcile of a perfectly readable `installed_plugins.json`, and a stale stamped path an earlier image wrote survives in it. The step-5 gate no longer stands down in that state, so a session with a host `context-mode` copies it in and the merge replaces the stale entry with a tree that is really there; a session **without** one keeps the stale entry and step 7 enables it. Claude Code surfaces the plugin and every hook in it fails to load | Narrowed to the no-host-copy case by "A marketplace file this session cannot parse does not cost it the host copy" in `tests/plugin-setup.venom.yml`. What is left is open: clearing it means removing half of a fact this code refuses to record half of, and the argument for refusing the halves together is in the `context_mode_plugin_register` header |
| The routing probe proves one route | It runs `WebFetch` through `PreToolUse` and nothing else; a broken `PostToolUse` or `SessionStart` still passes the build | Open |
| bun's `SHASUMS256.txt.asc` is not verified | The digests are transcribed from the unsigned checksum file; neither the signature nor its key is checked, here or in the refresh recipe | Open |
| No opencode session run end to end | Both storage pins are asserted at the shell seam and read from upstream source, never observed | Open |
| opencode has no `SessionStart` hook upstream | Weaker resume attribution than Claude | Documented degradation, not fixed |
| `opencode --pure` disables external plugins | Context Mode cannot engage at all | RiotBox warns on stderr and changes nothing else — `--pure` is the user's explicit instruction |
| Nothing greps the bundle for the two storage variables | A version bump renaming one surfaces in a user session, not at build time | Accepted |
| The npm version check cannot be suppressed | One unauthenticated GET per server start on the Claude path | Accepted; see `THREAT_MODEL.md` |

A real `riotbox rebuild` — not `riotbox build`, which would reuse a cache
predating this work — is required before the build path is trusted.

**A Claude session no longer prints a `[context-mode]` line at startup.** The
wire verb printed one; there is no wire verb. The equivalent signal now comes
from the registration, on stdout during plugin setup:

```text
  [plugins] Context Mode 1.0.169 registered at /home/llm/.riotbox/context-mode-plugin/v1.0.169.
```

It is printed only by a call that actually changed something. **How often that
is, is not a fixed answer, and the line is not a reliable proof of anything.**
`plugin_setup` registers at step 3 and again after the host-plugin merge, and
that second call runs only when `~/.host-plugins` is mounted at all. What it
finds then depends on what is under it:

- **No `context-mode` under `~/.host-plugins`.** The first run prints once; every
  run after it prints nothing, because both calls find the registry already
  naming the staged tree.
- **A host `context-mode` is mounted.** The step-5 merge lets the host entry win
  and overwrites the registration on *every* start, so the re-assert always has
  real work. The line prints on every run — twice on the first.

So neither the line nor its absence tells a user whether the plugin is loaded.
`context_mode_plugin_installed` in `container/context-mode-setup.sh` is what
answers that, by reading the registry, and the session warns on stderr when the
answer is no. opencode is unchanged: it still authors its plugin shim and still
says so on stderr.

## Where the pieces live

| Path | Holds |
|---|---|
| `libexec/launch.sh` | The opt-in gate and the headroom mutual exclusion |
| `container/context-mode-setup.sh` | Agent-neutral orchestration |
| `container/plugin-setup.sh` | `context_mode_staged_path` and `context_mode_plugin_register` — the registration and its reconcile |
| `container/context-mode-package-lock.json` | The staged plugin's dependency resolution. Generated, not upstream's; `COPY`'d in and consumed by `npm ci` in the staging layer. Regenerate it with every ref bump |
| `agents/claude/context-mode.sh` | Store path, platform token, MCP name, legacy-wiring stripper, Claude build guard |
| `agents/opencode/context-mode.sh` | Plugin shim writer, strip verb, opencode build guard |
| `container/context-mode-summary.sh` | Exit report and ledger append |
| `scripts/ctx-stats.sh` | Host-side ledger reader |
| `scripts/lib/json-write.sh` | `json_write_atomic`, shared with CodeGraph |
| `scripts/preflight.sh` | The `riotbox doctor` checks |

`json_write_atomic` is shared, but **the strippers are not.** Both features now
strip the same two files and neither wires an MCP server it did not have to.
CodeGraph's pair prunes a `UserPromptSubmit` command and an `mcp__codegraph__*`
permission from `settings.json` (`codegraph_strip_session_wiring`) and its
relocated `mcpServers` entry from `.claude.json` (`codegraph_strip_mcp_entry`),
both unconditionally, because the wiring came from an installer no image runs
any more. Context Mode's prunes the hook entries a pre-plugin release wrote into
`settings.json` *and* the `mcpServers` entry from `.claude.json`, then reports
which of the two it removed. One difference is worth carrying across: CodeGraph
decides ownership of its MCP entry on the entry's shape, where Context Mode
deletes by key — see the note in THREAT_MODEL.md on why deleting by key is a
knowing trade there. Do not read the shape test as the stronger guarantee than
it is: it distinguishes an entry the user *narrowed* from the installer's, and
nothing more. An entry left at CodeGraph's own default shape is byte-identical
to the installer's and is deleted just as a shared key is, so for the common
case the two mechanisms lose the same thing — THREAT_MODEL.md says so for both.
They share a shape and no body.

## Test coverage

All suites are shell-level and hermetic — they source the scripts and assert what
RiotBox writes, strips and refuses to touch. Exercising the routing itself needs a
model and credentials CI does not have.

| Suite | Covers |
|---|---|
| `tests/context-mode.venom.yml` | The Claude session path — the storage and platform pins, the installed-plugin probe, and the legacy-stanza strip driven from fixtures shaped like the previous release's output — plus the build-time pins it depends on: the `Containerfile` layers read as text, and the claude build assert executed against fixtures in both directions |
| `tests/plugin-setup.venom.yml` | The registration side, end to end: `context_mode_staged_path` and the usability test, the registration and its reconcile, the refusals for a registry *or* a marketplace file it cannot read, build and write, the host-copy exclusion and its three stand-down states, and what removal will and will not claim as RiotBox's own |
| `tests/context-mode-opencode.venom.yml` | The opencode path, the foreign-file refusal, the `--pure` warning, both storage pins |
| `tests/context-mode-summary.venom.yml` | Every printed number in the exit report |
| `tests/context-mode-ledger.venom.yml` | Record shape, the `agent` field, skip-and-return-0 paths |
| `tests/ctx-stats.venom.yml` | All four reader views, malformed records, empty ledger |
| `tests/doctor-context-mode.venom.yml` | The preflight checks, including an agent with no support |
| `tests/lib-json-write.venom.yml` | The shared atomic writer |
