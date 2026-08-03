# How Context Mode works in RiotBox

Maintainer-facing. This describes the integration **as it stands today** — what
gets wired, by whom, what it costs, and where it is still unproven.

- **Using the feature** → [README § Context Mode](../../README.md#context-mode-opt-in)
- **Why we adopted it, and on what terms** → [decisions/context-mode-adoption.md](decisions/context-mode-adoption.md)
- **Adding support for a new agent** → [agent-contract.md § Context Mode verbs](agent-contract.md#optional-verbs-context-mode)

Context Mode is opt-in behind `RIOTBOX_CONTEXT_MODE=1`, mutually exclusive with
`RIOTBOX_HEADROOM=1`, and is **not** a default. The head-to-head measurement that
would justify making it one has not been made.

## The shape of the integration

Five layers, each with one job:

| Layer | Where | Job |
|---|---|---|
| Gate | `libexec/launch.sh` | Accept the literal `1` only; refuse the headroom pair |
| Install | `Containerfile` | Pin the package and its interpreter; run the per-agent build guards |
| Orchestration | `container/context-mode-setup.sh` | Resolve the store, wire the current agent, strip every other agent |
| Per-agent wiring | `agents/<name>/context-mode.sh` | The agent-shaped part: hooks, plugins, constants, guards |
| Reporting | `container/context-mode-summary.sh`, `scripts/ctx-stats.sh` | Exit report per session; ledger aggregated across sessions |

The orchestration layer **names no agent.** Each agent supplies
`context_mode_store_dir`, `context_mode_data_dir`, `context_mode_wire`,
`context_mode_strip` and `context_mode_build_assert`, and every caller probes with
`declare -F` before calling. An agent implementing none of them is not an error:
the session warns, strips whatever an earlier session left in the same session
directory, and runs with the feature off.

## What each agent wires

The two implementations are deliberately different shapes. The registry contract
is about the lifecycle, not about what wiring looks like.

### Claude Code — hooks plus an MCP server

Six hook stanzas in `settings.json` and one `mcpServers` entry in `.claude.json`,
all driven from a single `context_mode_hook_table` in
`agents/claude/context-mode.sh`.

All six hooks are wired: `PreToolUse`, `PostToolUse`, `PreCompact`,
`SessionStart`, `UserPromptSubmit`, `Stop`. An earlier round wired only the first
two, which left the session database — the store `SessionStart` replays and
`/resume` restores from — with no writer at all. Continuity never engaged, and an
autocompact lost the resume snapshot `PreCompact` exists to write.

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

`CONTEXT_MODE_MATCHER` in `agents/claude/context-mode.sh` is reproduced verbatim
from upstream's `PRE_TOOL_USE_MATCHERS` and asserted against the installed bundle
at build time. It names:

`Bash`, `WebFetch`, `Read`, `Grep`, `Agent`, and every MCP tool.

**`WebSearch` and `Glob` are not in it.** No `PreToolUse` hook fires for them and
their output lands in the transcript in full. `Agent` — subagent calls — *is*
intercepted.

This corrects the adoption evaluation, which claimed WebSearch was hard-denied and
listed Glob among the routed tools. Both were wrong.

On opencode there is no matcher to audit at all: routing enforcement lives inside
`tool.execute.before`, so a version bump can change which tools are intercepted
with no build-time signal.

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

Measured against `context-mode@1.0.169` inside `quay.io/centos/centos:stream10` on
Node v22.23.1 — the version `ARG CONTEXT_MODE_NODE` pins — 50 invocations per
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

## Known gaps

| Gap | Effect | Status |
|---|---|---|
| No head-to-head measurement against a real session | Cannot justify making it a default | Open; the reason it stays opt-in |
| The image has never been built | `COPY`/`chmod` layers, nvm-resolved shim paths and the sentinel `RUN` layers are unexercised | Blocked: `podman build` fails in the dev container with `userxattr: invalid argument` |
| No opencode session run end to end | Both storage pins are asserted at the shell seam and read from upstream source, never observed | Open |
| opencode has no `SessionStart` hook upstream | Weaker resume attribution than Claude | Documented degradation, not fixed |
| `opencode --pure` disables external plugins | Context Mode cannot engage at all | RiotBox warns on stderr and changes nothing else — `--pure` is the user's explicit instruction |
| Nothing greps the bundle for the two storage variables | A version bump renaming one surfaces in a user session, not at build time | Accepted |
| The npm version check cannot be suppressed | One unauthenticated GET per server start on the Claude path | Accepted; see `THREAT_MODEL.md` |

A real `riotbox rebuild` — not `riotbox build`, which would reuse a cache
predating this work — is required before the build path is trusted.

## Where the pieces live

| Path | Holds |
|---|---|
| `libexec/launch.sh` | The opt-in gate and the headroom mutual exclusion |
| `container/context-mode-setup.sh` | Agent-neutral orchestration |
| `agents/claude/context-mode.sh` | Hook table, matchers, MCP name, Claude build guard |
| `agents/opencode/context-mode.sh` | Plugin shim writer, strip verb, opencode build guard |
| `container/context-mode-summary.sh` | Exit report and ledger append |
| `scripts/ctx-stats.sh` | Host-side ledger reader |
| `scripts/lib/json-write.sh` | `json_write_atomic`, shared with CodeGraph |
| `scripts/preflight.sh` | The `riotbox doctor` checks |

`json_write_atomic` is shared, but **the strippers are not.** CodeGraph's prunes a
`UserPromptSubmit` command and an `mcp__codegraph__*` permission from
`settings.json`; Context Mode's prunes RiotBox's own hook entries from
`settings.json` *and* the `mcpServers` entry from `.claude.json`, then reports
which of the two it removed. They share a shape and no body.

## Test coverage

All suites are shell-level and hermetic — they source the scripts and assert what
RiotBox writes, strips and refuses to touch. Exercising the routing itself needs a
model and credentials CI does not have.

| Suite | Covers |
|---|---|
| `tests/context-mode.venom.yml` | The Claude path, plus the strip-every-other-agent rule |
| `tests/context-mode-opencode.venom.yml` | The opencode path, the foreign-file refusal, the `--pure` warning, both storage pins |
| `tests/context-mode-summary.venom.yml` | Every printed number in the exit report |
| `tests/context-mode-ledger.venom.yml` | Record shape, the `agent` field, skip-and-return-0 paths |
| `tests/ctx-stats.venom.yml` | All four reader views, malformed records, empty ledger |
| `tests/doctor-context-mode.venom.yml` | The preflight checks, including an agent with no support |
| `tests/lib-json-write.venom.yml` | The shared atomic writer |
