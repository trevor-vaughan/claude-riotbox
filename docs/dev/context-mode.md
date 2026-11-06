# How Context Mode works in RiotBox

Maintainer-facing. This describes the integration **as it stands today** — what
gets wired, by whom, what it costs, and where it is still unproven.

- **Using the feature** → [README § Context Mode](../../README.md#context-mode-opt-in)
- **Why we adopted it, and on what terms** → [decisions/context-mode-adoption.md](decisions/context-mode-adoption.md)
- **Why RiotBox stopped writing Claude's wiring** → [decisions/context-mode-native-plugin.md](decisions/context-mode-native-plugin.md)
- **Why we moved from 1.x to 2.x, and what that cost** → [decisions/context-mode-2x-migration.md](decisions/context-mode-2x-migration.md)
- **Adding support for a new agent** → [agent-contract.md § Context Mode verbs](agent-contract.md#optional-verbs-context-mode)

Context Mode is opt-in behind `RIOTBOX_CONTEXT_MODE=1`, mutually exclusive with
`RIOTBOX_HEADROOM=1`, and is **not** a default. The head-to-head measurement that
would justify making it one has not been made.

## The shape of the integration

Seven layers, each with one job:

| Layer | Where | Job |
|---|---|---|
| Gate | `libexec/launch.sh` | Accept the literal `1` only; refuse the headroom pair |
| Install | `Containerfile` | Install the package from a committed lockfile on its pinned Node; stage it as the Claude Code plugin; run the per-agent build guards, the health checks and the routing probe |
| Sandbox runtime | `Containerfile` (the bun layer) | Supply the JS/TS interpreter `ctx_execute` needs. Without bun on `PATH`, `ctx_execute` reports `TypeScript: not available` and TS snippets cannot run at all. It is **not** on the hook path — those commands name the pinned Node |
| Registration | `container/plugin-setup.sh` | Point this session's plugin registry at the staged tree, in place, and re-assert it after the host-plugin merge |
| Orchestration | `container/context-mode-setup.sh` | Wire the current agent if it authors wiring, strip every other agent |
| Per-agent support | `agents/<name>/context-mode.sh` | The agent-shaped part: stripper and build guard — plus wiring, for an agent that writes its own |
| Reporting | `container/context-mode-summary.sh`, `scripts/ctx-stats.sh` | Exit report per session; ledger aggregated across sessions |

The orchestration layer **names no agent.** Each agent supplies some subset of
`context_mode_wire`, `context_mode_strip` and `context_mode_build_assert`, and
every caller probes with `declare -F` before calling. Nothing is pinned per
agent: context-mode 2.x keeps every store under `~/.context-mode` and takes its
platform from the `--agent` argument of the hook and server commands, or from
which in-process entry loaded, so the session exports no `CONTEXT_MODE_*`
variable.

**The probe for "does this agent have support at all" is `build_assert`, not
`wire`.** Claude Code has no wire verb — the plugin is the wiring — so a probe
on `wire` would read Claude as unsupported and turn the feature off on the agent
it is best supported on. An agent implementing none of the verbs is
still not an error: the session warns, strips whatever an earlier session left in
the same session directory, and runs with the feature off.

## How each agent reaches Context Mode

The three implementations are deliberately different shapes, and they do not
even share the question of who writes the wiring. The registry
contract is about the lifecycle, not about what wiring looks like.

### Claude Code — upstream's plugin, registered rather than authored

RiotBox writes no Claude wiring at all. The npm package is the plugin: it
carries `.claude-plugin/plugin.json`, which names `hooks/claude-code.json` and
declares the MCP server, and `.claude-plugin/marketplace.json`, which declares
the plugin with source `"./"`. The image installs the package with `npm ci`
against the committed `container/context-mode-package-lock.json`, deletes the
Gemini `hooks/hooks.json` the tarball also ships (Claude Code always loads
`<plugin>/hooks/hooks.json`, and upstream deletes it from its own
`plugins/claude-code` for that reason), rewrites the bare `node` in
`hooks/claude-code.json` and `.claude-plugin/plugin.json` to the pinned
interpreter, and leaves the tree at
`/home/llm/.riotbox/context-mode-plugin/v<version>`.
`container/plugin-setup.sh` then records that path in the session's
`installed_plugins.json` and `known_marketplaces.json`. The hooks and the MCP
server both come from the plugin's own manifests.

The hook set at 2.x is `PreToolUse`, `PostToolUse`, `SessionStart` and
`UserPromptSubmit`, every one running `hook.mjs --agent claude-code`. 1.x's
`PreCompact` and `Stop` are gone. What the plugin adds over the CLI is the
`/context-mode:*` slash commands, which are the skills under `skills/`
(`ctx-doctor`, `ctx-stats`, `ctx-upgrade`).

Three consequences worth knowing before debugging a session:

- **The tree is registered, not copied.** It is 6.2 MB at 2.1.4 and `~/.claude`
  is a per-session-key bind mount of a host directory, so a copy would pay that
  disk once per project set. The registry entry names the image path and the
  tree is read in place, which also means a rebuild at a new version moves it —
  `context_mode_plugin_register` rebuilds the entry from what is staged now
  rather than trusting what a session recorded.
- **A host-installed `context-mode` is deliberately excluded from the host-plugin
  copy.** `plugin_setup` merges `~/.host-plugins` over the registry with host
  entries winning, so without the exclusion a host tree — one that never went
  through the interpreter rewrite — would displace the staged one. The registration is re-asserted after the merge for the same
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

Two verbs are left in `agents/claude/context-mode.sh` — `context_mode_strip` and
`context_mode_build_assert` — and no `context_mode_wire`. The stripper outlived the
wiring it used to undo, because session directories outlive images: a directory
wired by the previous release still holds six hand-authored hook stanzas and an
`mcpServers` entry, `settings.json` is never synced from the host, and nothing
else removes them. Left in place beside the registered plugin they would dispatch
every event twice against one server name two writers claim.

### opencode — one generated plugin file

No hooks, no MCP server. RiotBox writes a single file,
`~/.config/opencode/plugins/riotbox-context-mode.js`, re-exporting the vendored
adapter (`opencode/plugin.js`) by absolute path. Notes that cost time to
establish:

- **The directory is `plugins/`, plural.** A file placed in the singular
  `plugin/` never loads.
- **The shim re-exports the default alone.** The adapter's default export is
  `{ id, server, setup }` — opencode 1.x's loader reads `server`, opencode 2's
  reads `setup` — and it also exports `server`, `setup` and `setupLegacy` by
  name. opencode 1.x falls back to calling every function export as a plugin,
  so a named re-export would register the plugin three times.
- **The adapter finds its own files from `import.meta.url`,** which an ES
  module re-export does not change, so the shim's location does not matter.
- **The `ctx_*` tools arrive in-process, not over MCP,** and the adapter opens
  `node:sqlite` inside opencode's runtime. The pinned Node does not apply here.

### Pi — one entry in a RiotBox-owned `packages` list

Pi loads Context Mode as a Pi package. The installed `context-mode` package
root declares `pi.extensions` (`./pi/index.js`) in its `package.json`, and Pi
loads that extension when the root is listed in `~/.pi/agent/settings.json`
`packages`. `agents/pi/setup.sh` rewrites that list on every container start,
before `context_mode_setup` runs, so wiring is one entry appended and stripping
is that entry removed. Notes:

- **The entry is the vendored root by absolute path,** so Pi never installs
  the package from npm and the version stays on the pin the build asserts.
- **The strip removes two shapes and nothing else:** any path under
  `RIOTBOX_CM_PLUGIN_DIR/`, so an entry an older image wrote naming its own
  version still goes after a bump, and a path whose last segment is exactly
  `context-mode`, the 1.x package root a session directory may still carry. A
  user path like `my-context-mode-tools` or `context-mode-fork/x` stays.
- **The `ctx_*` tools run in-process** and register lazily from
  `before_agent_start`, so the build's SDK smoke (`container/pi/smoke.mjs`)
  cannot see them and does not try.
- **It runs on Pi's Node, and needs 24.15.0 or later there.** The extension
  opens `node:sqlite` in Pi's process, so `PI_NODE` carries context-mode's floor
  and equals `CONTEXT_MODE_NODE`.

The build guard, `agent_pi_context_mode_build_assert`, fails the image when
`pi.extensions` is anything but `["./pi/index.js"]`, when that file is missing,
or when it has no default export.

## Where the stores live

context-mode 2.x keeps one SQLite database per project at
`~/.context-mode/projects/<key>/context.db`, where `<key>` is the first 16 hex
characters of the SHA-256 of the project's git common directory (or of the
directory itself outside git), whichever agent runs it. Nothing per agent
chooses this, and no environment variable RiotBox sets moves it.

`~/.context-mode` is a session-state mount: `scripts/mount-projects.sh` creates
`<state-dir>/context-mode` with `ensure_real_dir` and bind-mounts it read-write
on every launch, whether or not `RIOTBOX_CONTEXT_MODE` is set, because a plugin
copied in from the host writes the same store. The session's agents and its
concurrent runs share it, and `riotbox session-reset` removes it with the state
dir. No `entries` pair in `internal/migrate` feeds it: it has no older location
to import from.

Placement rests on the mount alone. 2.1.4 also reads `CONTEXT_MODE_DATA_DIR` as
a full override of the data root, so a value that reached the container — a
passthrough entry, an extra `-e` — would move every store off the mount without
a word. `context_mode_setup` unsets it first, before the feature check, and the
default passthrough set never forwards it.

A read-only data root does not fail loudly: every hook's store write gets
`EACCES`, the hook exits 0 and passes the tool output through whole, so the
feature reports itself on and saves nothing.

The 1.x stores — `~/.claude/context-mode`, `~/.pi/agent/context-mode` and
`~/.local/share/opencode/context-mode` — are not read and not imported. They
sit in session mounts, so they persist; an enabled session prints one
`[context-mode] NOTE:` line naming each non-empty one, and nothing deletes them.

## Which tools are actually intercepted

At 2.1.4 the staged plugin's `hooks/claude-code.json` routes `PreToolUse` for

`Bash`, `PowerShell`, `Read`, `Grep`, `WebFetch`, `Write`, `Edit`,
`NotebookEdit` and the plugin's own `ctx_*` tools,

and `PostToolUse` for the same set plus every MCP tool. **`WebSearch`, `Glob`
and `Agent` are not in either**, so no hook fires for them and their output
lands in the transcript in full.

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
way the lockfile is. The Context Mode layer projects the staged
`hooks/claude-code.json` down to `{event: [matchers]}` and requires equality,
so a tool added or dropped upstream fails the image build again, and the refresh at a
version bump is a command whose diff a reviewer reads rather than two arrays
somebody retypes. On opencode and Pi there is no such file — routing lives inside
the in-process adapter — and nothing in the build compares it.

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

The replacement runs the real thing. It reads the `PreToolUse` command out of
the staged `hooks/claude-code.json` — whatever the interpreter rewrite produced
— feeds it a real `WebFetch` payload, and requires a
`hookSpecificOutput.permissionDecision` back. Two details are load-bearing and
should not be simplified away:

- **A control run.** The same command fed a plain `Bash` `ls` must return
  nothing — the hook allows a tool by saying nothing — so a pass cannot come
  from a hook that answers every tool.
- **`PATH=/usr/bin:/bin`.** With the build's PATH inherited, an un-rewritten
  command would run on the build's Node 20. With no `node` resolvable, an
  un-rewritten command produces nothing and fails the layer.

The layer also runs two health checks in place of `context-mode doctor`, which
checks each agent it finds for the config `context-mode setup` writes and so
exits 1 for every agent RiotBox wires per session: the CLI shim must answer
`--version` with the pin, and the OpenCode adapter, imported under the pinned
Node, must carry a default export with `id`, `server` and `setup`. It also
generates the exit report's stats shim and probes it against a store the real
`PostToolUse` hook writes; see [Producing a real context.db](#producing-a-real-contextdb).

`riotbox doctor` runs the same checks again against the built image, through
`scripts/lib/context-mode-probe.sh`. It covers the CLI and Node pins, the
OpenCode adapter, `pi/index.js`, the hook table and the routing probe, and adds
one check the build cannot make: that `~/.context-mode`, mounted the way a
session mounts it, is writable. The pins and the hook table it compares
against come from the install tree, so an image built by an older riotbox fails
there. Change a probe in the Containerfile and change it in that file too.

## Reporting

A wired session prints a short block when it exits and, when the ledger is
mounted, writes one record for the run:

```text
── context-mode ─────────────────────────────────────
 this run 279 KB kept out · 4.0 KB re-read via ctx_search · 10 tool calls recorded
 store total 427 KB kept out
 store: /home/llm/.context-mode (this project set)
```

### Where the numbers come from

context-mode 2.x writes `events` rows in the store of the project a call ran
in, but only for some calls. Two columns carry the bytes: `sandbox_bytes` is
what the call produced and `returned_bytes` is what the model received.

- **Shell commands, edits and tool errors.** The `PostToolUse` hook writes the
  row. For a shell command, `returned_bytes` is the replacement text when the
  hook replaced the output.
- **`ctx_*` calls.** The MCP server writes the row.
- **Everything else gets no row.** Upstream's `journalKind`
  (`src/core/hooks/dispatch.ts`) returns no kind for a clean `Read`, `Grep`,
  `WebFetch` or other host tool, **even when the hook replaces its output**.
  The output is indexed into `sources`, and nothing records what the model
  received instead. The real 2.1.4 hook, fed a 168893-byte `Read`, writes no
  `events` row and one `sources` row of that size.

**Kept out is therefore a lower bound.** Replaced `Read`, `Grep` and `WebFetch`
outputs are real savings that the report does not measure. Counting them would
mean estimating from `sources`, which is left for a follow-up. The image build
pins this behaviour: its stats probe feeds the real hook a large `Read` and
requires it to add nothing. If upstream starts journalling those calls, the
build fails and the report can count them deliberately.

The stats shim reads those rows. `container/context-mode-stats.mjs` runs on the
pinned Node through a shim the image generates at `CONTEXT_MODE_STATS_BIN`. It
opens every `~/.context-mode/projects/*/context.db` with `node:sqlite`, read-only
and with a one-second busy timeout, and runs one query per store:

```sql
SELECT
  COALESCE(SUM(CASE WHEN tool NOT IN ('ctx_stats', 'ctx_doctor', 'ctx_upgrade', 'ctx_purge',
                                      'ctx_index', 'ctx_search', 'ctx_resume')
                    THEN MAX(sandbox_bytes - returned_bytes, 0) END), 0) AS kept_out,
  COALESCE(SUM(CASE WHEN tool IN ('ctx_search', 'ctx_resume')
                    THEN returned_bytes END), 0) AS re_read,
  COUNT(*) AS calls
FROM events
WHERE seq > ? AND agent = ? AND tool IS NOT NULL AND kind <> 'cost'
```

The query runs twice: once at the run's watermark and once at 0, which gives
the store total. The start read uses `--seq-only`: it needs only the
watermark, and it sits in front of the agent. Any store that cannot be read,
because it is locked past the timeout, corrupt or not a 2.x store, fails the
whole read. Skipping it would under-count without saying so. A failed read at
exit prints no report, plus one stderr line naming the store, so it can be
found and removed:

```text
  [context-mode] NOTE: exit report skipped, cannot read /home/llm/.context-mode/projects/<key>/context.db: file is not a database
```

At start, a failed read makes the baseline unknown and prints nothing.

### Which rows are this run's

`context_mode_summary_init` records each store's `AUTOINCREMENT` counter
(`sqlite_sequence`, not `MAX(seq)`) before the agent starts. At exit only rows
above it count. A store created during the run has no entry, so all its rows
count.

`MAX(seq)` would be wrong: `ctx_purge` deletes rows but leaves the counter.

Rewind detection is partial. If a store's counter is **below** its watermark at
exit, the database was recreated during the run (by the dead-project sweep or a
heal) and has not yet grown past the old counter. Its rows are not this run's,
so the report says `this run unknown (no usable baseline)` and the ledger
records `baseline_unknown: true`. A store that was recreated **and** has
already grown past its watermark is not detected: its rows above the watermark
count as the run's, and its rows below it are missed.

Rows are also filtered on `agent`. `claude` maps to upstream's `claude-code`;
`opencode` and `pi` keep their names. The 1.x stores lived in each agent's own
directory, so this keeps the same scope.

**Concurrent runs of the same agent on one project set are not separated.**
`~/.context-mode` is one mount per project set, shared by every run of it, and
no column identifies a run:

- `session_id` is the agent's own session id, which RiotBox neither assigns nor
  learns. `riotbox resume` continues the last session, so two runs can share
  one.
- `worktree` is the same `/workspace` path for every run.
- `agent` is the same agent.

Each run's report therefore counts both runs' rows. The figure is exact for one
run per project set at a time; with concurrent runs it is an upper bound. 1.x
had the same overlap, because its counters were store-wide totals read before
and after the run.

### Why our savings figure differs from upstream's

The report counts only bytes genuinely withheld from the model, and prints
**no percentage**. Upstream's `ctx_stats` (`src/core/tools/stats.ts`) groups
rows by `(session_id, agent)` and nets each group:
`max(0, SUM(sandbox_bytes) − SUM(returned_bytes))`. It reports the sum as
saved and the share of what was produced as a reduction percentage. Three
parts of that are not savings:

- **Netting.** Within a group, a `ctx_search` reply (sandbox 0, returned *n*)
  subtracts from another call's saving. Upstream's own comment calls this
  "index then search nets out". A re-read is a cost, so we report it as a
  separate term. We also clamp each row at zero, so no call cancels another's
  saving.
- **The rows it counts.** Every tool except `ctx_stats` counts. A `ctx_doctor`
  report counts as saved bytes, and so does `ctx_index`, whose input can be
  `content` the model wrote into the call. Those bytes were already in its
  context. A row does not say whether indexed bytes came from a path, a URL or
  the call itself, so none of them are counted. 1.x did not count `ctx_index`
  as kept out either.
- **The percentage.** Its denominator is what the tools produced. That says
  nothing about what reached the model, and the ratio hides the absolute
  figure.

1.x's headline was a different composite with the same defect: it added
bookkeeping counters (`eventDataBytes`, `snapshotBytes`) to the saving. 2.x has
no such columns, so the rule now comes down to which rows count. The rule
itself is the same, and the header of `container/context-mode-summary.sh`
carries it. Do not "restore parity".

### Why a zero is always printed

An earlier version suppressed the report when nothing was saved, on the reasoning
that a zero is not a result worth a block of output. Using it disproved that.

The report is the only evidence a session leaves, so "no report" had to carry two
unrelated meanings at once — *the feature engaged and saved nothing*, and *the
feature never engaged*. The first is precisely the measurement we want; the second
is a bug. Nothing on screen could tell them apart.

The renderer now always prints for a wired session, with the tool-call count
beside the zero as the proof-of-life signal that distinguishes the two cases.
It counts only the calls 2.x journals: shell commands, edits, tool errors and
`ctx_*` calls. A session of nothing but `Read` and `Grep` shows no calls even
when the hooks replaced every output.
It is a count of calls, not bytes, so it cannot be read as a token cost. Under
1.x that signal was the "hook log on disk" byte figure, which 2.x has no
counter for.

### The store total

The second line sums kept out over every row the stores hold for this agent.
It is not a time window. 2.x's row retention deletes indexed sources that have
been idle for 30 days, but it never deletes events. Only `ctx_purge` and the
dead-project sweep remove them; the sweep takes a whole project that has been
idle for 14 days with no live owner. A total that drops between runs was one of
those two.

### The cross-session ledger

Upstream prunes its stores, so totals across sessions have to be captured at
session exit: they cannot be re-derived later. One JSON record per run lands in
a user-owned directory outside `RIOTBOX_DATA_DIR`, and `riotbox ctx-stats`
aggregates the records.

Records from 2.x runs are schema 2: `tool_calls` replaces 1.x's
`hook_log_bytes`. `ctx-stats` reads schema 1 and 2 records side by side and
sums their kept-out and re-read figures, because both follow the same rule.
Every view names the 1.x share and the date of the last 1.x run, `--runs` marks
each 1.x row, and the hook-log line appears only when 1.x records exist.

Both the report and the ledger are agent-neutral: every record stamps `agent`.
See [decisions/context-mode-ledger.md](decisions/context-mode-ledger.md) for
the storage shape, both schemas, the audit boundary that excludes read-only
sessions, and the reader's validation posture.

### Producing a real context.db

The test image has no Node 24 and no context-mode package, so the suites build
their stores from `tests/fixtures/context-mode-2-events.sql`. That file is
upstream's `events` and `sources` DDL, copied out of a store the real hook
wrote. The image
build keeps it honest. After the routing probe, the Context Mode layer feeds the
real `PostToolUse` command a canned `Bash` call with a 169 KB output, in a fresh
scratch `HOME`. The stats shim must then see exactly one `claude-code` call with
bytes kept out, and nothing above the watermark that read reported. A canned
`Read` of the same output must then add nothing.

To produce a store by hand, run the hook under the Node the image pins, with the
package at `/p`:

```bash
podman run --rm --network=none -v <package>:/p:ro,z docker.io/library/node:24 bash -c '
  export HOME=/tmp/h; mkdir -p /tmp/proj; cd /tmp/proj; git init -q .
  seq 1 30000 | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.stdout.write(JSON.stringify({session_id:\"S1\",cwd:\"/tmp/proj\",hook_event_name:\"PostToolUse\",tool_name:\"Bash\",tool_input:{command:\"seq 1 30000\"},tool_response:{stdout:s,stderr:\"\",interrupted:false}})))" \
    | CLAUDE_PROJECT_DIR=/tmp/proj node /p/hook.mjs --agent claude-code > /dev/null
  ls /tmp/h/.context-mode/projects/*/context.db'
```

The store appears at `/tmp/h/.context-mode/projects/<key>/context.db`.

## What it costs

**`PostToolUse` costs ~112 ms per tool call, and interpreter startup is nearly all
of it.** This is the one cost of the full hook set that could plausibly outweigh
its benefit, because `PostToolUse` fires on nearly every tool call and each fire
spawns the pinned Node.

The figure was measured on context-mode 1.x and has not been re-measured on 2.x,
whose hooks are one minified `hook.mjs` bundle on Node 24; upstream reports 7.5
to 12.3 ms of hook overhead over a bare `node` start.

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

At ~112 ms the hook stayed — it is what buys the session journal `SessionStart`
replays.

**One package, pinned by its lockfile.** context-mode 2.x has no runtime
dependencies and no install scripts, so `container/context-mode-package-lock.json`
resolves exactly one package. It is generated against a one-line `package.json`
that depends on exactly `CONTEXT_MODE_VERSION`, and the Context Mode layer runs
`npm ci --ignore-scripts` against the same `package.json`. Its integrity hash is
the only pin on the bytes: npm verifies the downloaded tarball against it, so a
republished release fails the build. `npm ci` also refuses a `package.json` the
lockfile does not satisfy, so a version bump that forgets the lockfile fails the
layer rather than installing the old release. The hash carries the same limit
the bun digests do: it was transcribed from one resolution, so it catches a
republished tarball and not a release that was already malicious when it was
recorded.

**A version bump moves two things:** `CONTEXT_MODE_VERSION` and the lockfile,
regenerated with the npm of `CONTEXT_MODE_NODE`. The recipe is in the
`Containerfile`, in the Context Mode block above the ARGs, and it is the only
copy — do not restate it elsewhere. Regenerate
`container/context-mode-hooks-expected.json` in the same pass and read its diff.

## Known gaps

| Gap | Effect | Status |
|---|---|---|
| No head-to-head measurement against a real session | Cannot justify making it a default | Open; the reason it stays opt-in |
| The image has never been built | The install, the interpreter rewrites, the health checks and the routing probe have never run as a `podman build` layer | Blocked: `podman build` fails in the dev container with `userxattr: invalid argument`. Every layer body was extracted and run under `podman run` instead |
| Concurrent runs of a session share one store across PID namespaces | upstream marks a project owned by writing `owners/<uuid>.pid` and tests it with `kill(pid, 0)`. A second run of the same session sees the first's PIDs from its own namespace: `ESRCH` deletes a live run's owner file and lets row retention and the 14-day idle sweep run under it; a PID that happens to be alive there keeps a dead owner's project from ever being swept. Only what upstream's retention rules select (sources idle 30 days, the 500 MB cap, projects idle 14 days) is affected | Open |
| Replaced `Read`, `Grep` and `WebFetch` outputs are not measured | 2.x journals no `events` row for a clean `Read`, `Grep`, `WebFetch` or other host tool, even when the hook replaces its output. It records them only in `sources`, which does not say what the model received instead. Kept out is therefore a lower bound, and "tool calls recorded" counts only shell commands, edits, tool errors and `ctx_*` calls. See [Where the numbers come from](#where-the-numbers-come-from) | Open. The image build fails if upstream starts journalling a replaced `Read`, so the change cannot go unnoticed |
| A store recreated during a run is only sometimes detected | The run is marked unknown when a store's counter is below its watermark at exit. A store that was recreated and has already grown past the watermark is counted as if it were the original | Open |
| Concurrent runs of one agent on one project set count each other's rows | The stores are one mount per project set, and no `events` column identifies a run: `session_id` is the agent's own id, which RiotBox neither assigns nor learns, `worktree` is the same path, and `agent` is the same agent. Each run's exit report and ledger record include the other run's rows above its watermark. See [Which rows are this run's](#which-rows-are-this-runs) | Open. 1.x had the same overlap; the figure is exact for one run per project set at a time and an upper bound otherwise |
| The matcher set is asserted against a committed file, not against upstream | The Context Mode layer requires the staged `hooks/claude-code.json` to equal `container/context-mode-hooks-expected.json`, so a tool added or dropped upstream fails the build — but the expectation is RiotBox-generated, so a ref bump that regenerates it without reading the diff accepts the change silently. Same shape of limit as the lockfile row above | Closed at build time on Claude; the review of the regenerated diff is the part no gate can take. opencode and Pi have no equivalent — routing lives in the in-process adapter. See [Which tools are actually intercepted](#which-tools-are-actually-intercepted) |
| Every plugin the user disabled is re-enabled at session start | `plugin_setup` step 1 deletes `.enabledPlugins` wholesale whenever it is present and step 7 rebuilds it from the registry keys as all-`true`, so a `false` set in an earlier session never survives. Not specific to Context Mode — it clobbers every plugin | Open, and not a Context Mode decision to take. The behaviour is pinned by "a session start re-enables a plugin the user switched off" in `tests/context-mode.venom.yml`, and the argument for raising it separately is in the `context_mode_plugin_installed` header |
| A corrupt `known_marketplaces.json` can leave a dangling enabled registration | `context_mode_plugin_register` writes the registry entry and the marketplace entry as one fact — where this session's Context Mode is — and refuses to write either when it cannot write both. So a marketplace file it cannot parse blocks the reconcile of a perfectly readable `installed_plugins.json`, and a stale stamped path an earlier image wrote survives in it. The step-5 gate no longer stands down in that state, so a session with a host `context-mode` copies it in and the merge replaces the stale entry with a tree that is really there; a session **without** one keeps the stale entry and step 7 enables it. Claude Code surfaces the plugin and every hook in it fails to load | Narrowed to the no-host-copy case by "A marketplace file this session cannot parse does not cost it the host copy" in `tests/plugin-setup.venom.yml`. What is left is open: clearing it means removing half of a fact this code refuses to record half of, and the argument for refusing the halves together is in the `context_mode_plugin_register` header |
| The routing probe proves one route | It runs `WebFetch` through `PreToolUse` and nothing else; a broken `PostToolUse` or `SessionStart` still passes the build | Open |
| bun's `SHASUMS256.txt.asc` is not verified | The digests are transcribed from the unsigned checksum file; neither the signature nor its key is checked, here or in the refresh recipe | Open |
| No opencode session run end to end | The adapter opens `node:sqlite` inside opencode's embedded bun. A current bun (1.4.4) loads it with FTS5; the bun opencode ships was not checked | Open |
| opencode has no `SessionStart` hook upstream | Weaker resume attribution than Claude | Documented degradation, not fixed |
| `opencode --pure` disables external plugins | Context Mode cannot engage at all | RiotBox warns on stderr and changes nothing else — `--pure` is the user's explicit instruction |
| No Pi session run end to end through `riotbox` with Context Mode on | The staged package loads into a real Pi session on Node 24 with no errors, but its tools register only at the first `before_agent_start`, and the `riotbox run` integration suite pins the feature off | Open |
| Pi's routing is not asserted at build time | A version bump can change what the `tool_call` handler blocks without failing the build, as on opencode | Open |
| The `ctx_doctor` version check cannot be suppressed | When the agent calls `ctx_doctor`, one unauthenticated read of the npm dist-tags, then `git ls-remote` of the release tags if that fails. Offline it reports the version as unknown after a 10 s timeout per source | Accepted; see `THREAT_MODEL.md` |

A real `riotbox rebuild` — not `riotbox build`, which would reuse a cache
predating this work — is required before the build path is trusted.

**A Claude session no longer prints a `[context-mode]` line at startup.** The
wire verb printed one; there is no wire verb. The equivalent signal now comes
from the registration, on stdout during plugin setup:

```text
  [plugins] Context Mode 2.1.4 registered at /home/llm/.riotbox/context-mode-plugin/v2.1.4.
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
| `container/context-mode-package-lock.json` | The single pin on the installed package. Generated, not upstream's; `COPY`'d in and consumed by `npm ci` in the Context Mode layer. Regenerate it with every version bump |
| `container/context-mode-hooks-expected.json` | The event and matcher set the staged plugin must ship |
| `agents/claude/context-mode.sh` | MCP name, legacy-wiring stripper, Claude build guard |
| `agents/opencode/context-mode.sh` | Plugin shim writer, strip verb, opencode build guard |
| `agents/pi/context-mode.sh` | `packages` entry wire and strip verbs, Pi build guard |
| `container/context-mode-summary.sh` | Exit report and ledger append |
| `container/context-mode-stats.mjs` | The stats reader the exit report runs on the pinned Node: the SQL over `events` |
| `scripts/ctx-stats.sh` | Host-side ledger reader |
| `scripts/lib/json-write.sh` | `json_write_atomic`, shared with CodeGraph |
| `scripts/preflight.sh` | The `riotbox doctor` checks |
| `scripts/lib/context-mode-probe.sh` | The in-image half of the Context Mode doctor check |

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
| `tests/context-mode.venom.yml` | The Claude session path — no 1.x variable exported, the installed-plugin probe, and the legacy-stanza strip driven from fixtures shaped like the previous release's output — plus the build-time pins it depends on: the `Containerfile` layers read as text, and the claude build assert executed against fixtures in both directions |
| `tests/plugin-setup.venom.yml` | The registration side, end to end: `context_mode_staged_path` and the usability test, the registration and its reconcile, the refusals for a registry *or* a marketplace file it cannot read, build and write, the host-copy exclusion and its three stand-down states, and what removal will and will not claim as RiotBox's own |
| `tests/context-mode-opencode.venom.yml` | The opencode path, the default-only shim, the foreign-file refusal, the `--pure` warning, no 1.x variable exported |
| `tests/context-mode-pi.venom.yml` | The Pi path: the Node floor, idempotent wire and strip, the refusals for a package without `pi.extensions` and for an unusable `settings.json`, the strip that leaves look-alike user entries, the build guard against fixtures in both directions, and the setup orchestration |
| `tests/context-mode-summary.venom.yml` | Every printed number in the exit report, and the stats SQL against real 2.x stores: the row classes, the watermark and agent scoping, several project stores, a purge, a recreated store, a replaced `Read` that adds nothing, and locked, corrupt and absent stores with the stderr note. The store cases need Node 24: the test image installs the pinned one and sets `RIOTBOX_REQUIRE_CM_NODE=1`, which turns a missing Node into a failure; on a bare host they print `<case>=SKIPPED`. A case asserts the test image's Node pin matches `CONTEXT_MODE_NODE` |
| `tests/context-mode-ledger.venom.yml` | Schema-2 record shape, the `agent` field, skip-and-return-0 paths, and the report and record agreeing on one real store |
| `tests/ctx-stats.venom.yml` | All four reader views, schema 1 and 2 side by side with the 1.x boundary labelled, malformed records of either schema, empty ledger |
| `tests/doctor-context-mode.venom.yml` | The preflight checks, including an agent with no support |
| `tests/lib-json-write.venom.yml` | The shared atomic writer |
