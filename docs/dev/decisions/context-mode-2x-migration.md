# Migrating Context Mode from 1.x to 2.x

**Decision:** Move to context-mode 2.1.4 on Node 24.22.2 inside issue #60, before
the OpenCode V2 switch. Bind-mount one store at `~/.context-mode`, stage the
Claude plugin from the npm package alone, rebuild the exit report and ledger on
the new store, and replace `context-mode doctor` as the health gate.

**Date:** 2026-11-06 · **Issue:** [#60](https://github.com/trevor-vaughan/claude-riotbox/issues/60) (OpenCode V2) · **Branch:** `60-opencode-v2` · **Commits:** `dcd5baa`..`97ad930`

> **Frozen record.** Written after implementation. For the current
> implementation, read [How Context Mode works in RiotBox](../context-mode.md).
> It supersedes parts of [the adoption record](context-mode-adoption.md),
> [the native-plugin record](context-mode-native-plugin.md),
> [the opencode record](context-mode-opencode.md) and
> [the ledger record](context-mode-ledger.md); each says where.

**Verified against:** context-mode 2.1.4 (npm tarball and git tag `v2.1.4`),
Node 24.22.2, OpenCode 1.19.x. The upstream evidence below was gathered against
2.1.3 first and re-checked against 2.1.4 before the pin (investigation A9a/A9b);
file:line references are to upstream's tree at those tags.

## TL;DR

context-mode 2.0.0 shipped on 2026-11-04 and is a rewrite: one dependency-free
package, `node:sqlite` instead of `better-sqlite3`, one `hook.mjs`, one store per
project under `~/.context-mode`. Everything RiotBox built around 1.0.169 either
changed meaning or stopped existing: the store location, the stats counters, the
plugin layout, the doctor, the Node floor. Nothing about the move was a bump.

Eight decisions follow. Two carry a risk the user accepted: concurrent runs of
one project share a store that 2.x's PID-based owner sweep cannot reason about,
and the exit report undercounts replaced `Read`, `Grep` and `WebFetch` output.
Both are recorded as Open, not fixed.

## 1. Migrate inside #60, before the OpenCode V2 switch

**Decided.** The migration lands on the #60 branch, ahead of the switch to
OpenCode V2.

**Why.** 2.x ships a single OpenCode plugin (`opencode/plugin.js`) that loads on
OpenCode V1 (1.19.4) and on V2. It exports `default = { id, server, setup }` plus
named `id`, `server`, `setup` and `setupLegacy`. OpenCode 1.19.4's `readV1Plugin`
takes `mod.default` when it has `id`, `server` or `tui`
(`packages/opencode/src/plugin/shared.ts:272-297`; `plugin/index.ts:114-119`).
1.0.169's plugin is V1-only, so staying on it would have meant doing the V2 work
twice: once against a plugin that cannot load there, then again after the bump.
Upstream's V1/V2 support is mksglu/context-mode#1171.

**Rejected: migrate after V2.** It leaves the V2 branch with no working Context
Mode, or with a 1.x plugin that cannot load. Either way the feature is dark for
the length of the gap.

**Rejected: migrate on a separate branch first.** The two changes share the
OpenCode shim and the Node pin; splitting them means one is written against a
tree the other is about to rewrite.

**The shim re-exports `default` only.** On older OpenCode 1.x builds without
`readV1Plugin`, `getLegacyPlugins` walks `Object.values(mod)` and calls `.server`
on every object it finds, so re-exporting `setup` and `setupLegacy` would register
them as plugins as well (`plugin/index.ts:99-112`). A default-only re-export gives
exactly one `server()` registration on both loaders. The plugin finds its sibling
files from `import.meta.url`, which is the target module's URL rather than the
shim's, so it keeps working through the shim (`src/core/ops/bundle-dir.ts:26-30`).

## 2. Node: both pins move to 24.22.2, in the commit that moves the pin

**Decided.** `CONTEXT_MODE_NODE` and `PI_NODE` go from 22.23.4 to 24.22.2 (the
newest 24.x LTS) in `dcd5baa`, the same commit that moves `CONTEXT_MODE_VERSION`.

**Why.** 2.x needs Node 24.15.0 or later (`engines`), because it opens
`node:sqlite`. Below that floor the hook prints `Node v22.23.4 is below 24.15.0`
and does nothing. 1.x's `better-sqlite3` was built for the Node 22 ABI, so the
old and new halves cannot share an interpreter: the move has to be one commit or
the tree between the two does not run.

**Rejected: split the Node versions.** Keeping Pi on 22 while Context Mode moves
to 24 fails on Pi itself. The Pi extension runs in-process and opens `node:sqlite`
inside Pi's own Node (`src/entries/pi.ts:67`), so Pi must be on 24.15 or later
too. Splitting would also have kept two interpreters in the image for no reader of
the older one.

**Not covered.** The OpenCode path runs the plugin under OpenCode's embedded Bun.
Bun 1.4.4 reports `v26.3.0` and loads `node:sqlite` with FTS5, but OpenCode's own
embedded Bun version was not tested. The 24.15 floor is not enforced there by
RiotBox.

## 3. Store: a bind mount at `~/.context-mode`, not `CONTEXT_MODE_DATA_DIR`

**Decided.** `<project state>/context-mode` is bind-mounted read-write at
`~/.context-mode` on every launch (`678a8fb`), created with `ensure_real_dir`
like the other state-dir sources. It is not gated on `RIOTBOX_CONTEXT_MODE`,
because a plugin copied in from the host writes the same store. Claude, OpenCode
and Pi in one session share it, and `session-reset`/`session-remove` delete it
with the state dir. Old 1.x stores (`~/.claude/context-mode`,
`~/.pi/agent/context-mode`, `~/.local/share/opencode/context-mode`) are left in
place, unread and unimported. An enabled session prints one
`[context-mode] NOTE:` line naming each non-empty one.

**Why a mount at all.** The store must survive the container, and the data root is
a constant: `DATA_ROOT = "~/.context-mode"` (`constants.ts:155,157`). The
read-only 0555 sentinel the image used to place there as a barrier against 1.x's
event bridge is wrong for 2.x. Run as uid 1000 against a 0555 root, the hook exits
0 with no stdout and logs `EACCES ... mkdir '.../projects/<key>'` to stderr, so
the output passes through whole and the feature reports itself on while saving
nothing. The sentinels were removed in `dcd5baa`.

**Rejected: `CONTEXT_MODE_DATA_DIR=<session path>`.** 2.1.4 reintroduced the
variable (#1318) as a full override of the data root (`constants.ts:158`;
`src/core/project/config-dir.ts:158-171`). It looks like the cleaner mechanism,
and riotbox does not use it. The variable has now meant three different things:
the store's parent directory in 1.x (which riotbox exported for OpenCode and Pi),
nothing in 2.0 (removed), and the whole data root in 2.1.4. A stale 1.x-style
value, or one passed through by a user, would silently relocate every store off
the mount. `context_mode_setup` therefore unsets `CONTEXT_MODE_DATA_DIR` before
the feature check, and the default passthrough set never forwards it. The mount
alone places the store, so a later upstream change of meaning cannot move it.

**Rejected: a per-run store.** A store per run would remove the shared-owner
problem below and make the exit report exact. It would also throw away what the
store is for: `ctx_search` over what earlier runs of the project parked. 2.x
keys the store on the project (a hash of the git common dir, so every worktree
of a repo shares one `context.db`; `resolve.ts:155-174`), and a per-run store
would work against that design.

**Rejected: a shared PID namespace** (for example `--pid=host`) so the owner sweep
can see across containers. It would trade away a containment boundary, letting
the agent see and signal other processes, for a retention heuristic. The cost of
leaving it is bounded (below).

**Accepted risk, recorded Open in `THREAT_MODEL.md`.** Concurrent runs of a
project share the store. 2.x marks a project owned by writing
`owners/<uuid>.pid` containing `process.pid`, and tests liveness with
`kill(pid, 0)` (`owners.ts:20-44`). A second container sees the first's PIDs from
its own namespace: `ESRCH` counts as dead and deletes the owner file, and the
dead-project sweep and row retention then run under a live run
(`src/entries/server.ts:153-171`; `src/core/store/cleanup.ts:33-60,90-138`). The
opposite error also occurs: a PID that happens to be alive in the new namespace
keeps a dead owner's project from ever being swept. Both are conservative about
what they delete, because only upstream's own retention rules select rows
(sources idle 30 days, 500 MB per project, projects idle 14 days). No data
outside those rules goes. The user accepted this on 2026-11-05/06.

## 4. Plugin source: the npm package, under the lockfile's integrity hash

**Decided.** The Claude plugin is staged from the npm package installed with
`npm ci --ignore-scripts` against `container/context-mode-package-lock.json`
(one package, sha512 integrity), at `~/.riotbox/context-mode-plugin/v2.1.4`. The
separate tag-plus-SHA git clone is gone, with `CONTEXT_MODE_PLUGIN_REF`,
`CONTEXT_MODE_PLUGIN_SHA` and the "same release" check (`dcd5baa`).

**Why.** In 2.x the npm package and the git `plugins/claude-code/` tree carry the
same bundles; `diff -rq` shows only `.claude-plugin/marketplace.json`, the Gemini
`hooks/hooks.json` and `SHA256SUMS` differing. The npm package's
`.claude-plugin/marketplace.json` declares `"source": "./"`, so RiotBox registers
the package as its own marketplace. The package has no dependencies, so
`node_modules` needs nothing else. The lockfile's integrity hash becomes the one
pin, and `npm ci` rejects an `ARG` the lockfile does not satisfy (`EUSAGE`).
This closes the gap the native-plugin record accepted: "an unlocked `npm install`
and a 60 MB tree".

**The Gemini `hooks/hooks.json` is deleted** from the staged tree. Claude Code
always loads `<plugin>/hooks/hooks.json`, and upstream deletes it from its own
`plugins/claude-code` for the same reason (`build/main-tree.mjs`).

**Rejected: keep the git clone.** It would pin the same release twice, in two
forms, and the build would need a check that they agree. With the package
carrying the identical tree, the clone is redundant weight and a second supply
chain input.

## 5. Stats: the exit report, ledger and ctx-stats rebuilt on `context.db`

**Decided** (`1ffd8c2`, `1360a62`). The stats shim runs
`container/context-mode-stats.mjs` on the pinned Node. It opens every
`~/.context-mode/projects/*/context.db` read-only through `node:sqlite` with a
one-second busy timeout.

- **Kept out** is `MAX(sandbox_bytes - returned_bytes, 0)` per `events` row over
  work calls. It excludes `ctx_stats`, `ctx_doctor`, `ctx_upgrade`, `ctx_purge`,
  `ctx_index` and the retrieval tools. **Re-read** is `returned_bytes` of
  `ctx_search` and `ctx_resume`. The 1.x rule stands: print only bytes withheld
  from the model, no percentage, re-reads as a separate term. Upstream's own
  `ctx_stats` nets per (session, agent) unit and prints a percentage
  (`src/core/tools/stats.ts:91-95,162-200`), which is the thing RiotBox rejects,
  so `GROUPS` is not reused.
- **Scoping a run** uses a per-store `sqlite_sequence` watermark taken at start
  (`seq` is `INTEGER PRIMARY KEY AUTOINCREMENT`, `schema.ts:30`; rows are deleted
  only by `ctx_purge`, `purge.ts:51,59`), plus the `agent` column. `session_id`
  cannot be used: it varies by agent and by resume. A store recreated during the
  run (dead-project sweep or a heal) makes the run unknown.
- **Ledger records gain `"schema": 2`.** `tool_calls` replaces `hook_log_bytes`.
  `ctx-stats` sums schema 1 and 2 and labels the 1.x boundary in every view.
- **CI's test image gains Node 24.22.2** (`1488d5e`), SHA256-checked, with
  `RIOTBOX_REQUIRE_CM_NODE=1`, so the store cases run instead of skipping and
  reporting a pass.

**Known lower bound, Open: replaced `Read`, `Grep` and `WebFetch` output is not
measured.** 2.x journals `events` rows only for shell commands, edits, tool errors
and `ctx_*` calls. A clean `Read`, `Grep` or `WebFetch` gets none, even when the
hook replaces its output; it appears only in `sources`, which records what was
indexed and not what the model received instead. The report says so, and the image
build feeds the real hook a large `Read` and fails if it starts to add a row.
Follow-up: [#61](https://github.com/trevor-vaughan/claude-riotbox/issues/61).

**Rejected: count `sources`.** It would mean estimating, because nothing in
`sources` says what the model received. The reports state only measured bytes. An
estimate would put the report on the same footing as upstream's headline figure,
which this design exists to avoid. It is deferred to #61, not refused.

**Same-agent concurrent runs can't be told apart,** because no column identifies a
run. Their figure is an upper bound. This is the same limit 1.x had and is
documented as open.

## 6. Settings RiotBox does not use

**`CONTEXT_MODE_REQUIRE_SECURITY` is deliberately not set** (`0ce3db3`). With it at
`1`, every `PreToolUse` is denied when a Claude deny-rules file exists but cannot
be read or parsed (`src/core/policy/decide.ts:33,57-61`). Only `claude-code` reads
deny files (`user-deny.ts:21-29`). RiotBox runs Claude with
`--dangerously-skip-permissions` and writes no `permissions.deny`, so no RiotBox
control rests on those rules, and the container plus `RIOTBOX_NETWORK` are the
boundary. Setting it would let one malformed project `.claude/settings.local.json`
deny every tool call in a session, which costs availability and protects nothing
RiotBox relies on. A venom case asserts the variable stays unexported.

**There is no outbound opt-out to set.** 2.x makes no call at startup and ships no
telemetry; upstream lists every call site and guards the list with a test
(`README.md:567-579`; `docs/architecture/DEVIATIONS.md:146`). The one an agent can
reach is the `ctx_doctor` version check: npm dist-tags, then `git ls-remote`
(`src/core/ops/doctor-env.ts:90-99,174-199`). It is on demand, fails soft after a
10 s timeout per source, and has no off-switch. `RIOTBOX_NETWORK=none` and
`RIOTBOX_EGRESS=1` both block it, because neither the npm registry nor GitHub is
on any agent's egress allowlist (`02424d1`). 2.1.4 removed `ctx_upgrade`'s git
clone, so that tool now only prints the agent's own update command.

## 7. Health check: not `context-mode doctor`

**Decided** (`dcd5baa`, `97ad930`). 2.x's `context-mode doctor` is not the build or
`riotbox doctor` gate. It checks each detected agent's own setup, and exits 1 for
agents that are installed but that upstream's `context-mode setup` never
configured: `pi FAIL not set up, run context-mode setup`. RiotBox wires per
session and never runs `setup`, so it would exit 1 on every correct image. Running
`setup` at build would write agent config RiotBox regenerates per session.

**Instead,** the build and `riotbox doctor` check RiotBox's own wiring, through
`scripts/lib/context-mode-probe.sh`: `context-mode --version` equals
`CONTEXT_MODE_VERSION`; the shim runs `CONTEXT_MODE_NODE`; the OpenCode adapter
imports with a default export carrying `id`, `server` and `setup`; `pi/index.js`
exists; the staged tree is at the pin and has a plugin manifest; its hook table
equals `container/context-mode-hooks-expected.json`; the real `PreToolUse`
command run with no Node on `PATH` decides `WebFetch` and stays silent for a plain
`ls`; and a `~/.context-mode` mounted the way a session mounts it is writable.

**Rejected: pass flags to make upstream's doctor pass** (`--agents`, or stubs).
With stub binaries on `PATH` it fails on "found only shim script(s)" instead, so it
tests the stub and not the wiring.

## 8. Release volatility

2.0.0 shipped on 2026-11-04. 2.1.4 was out within roughly a day, and fixes keep
landing daily. 2.1.4 changed two things this migration depends on while the
investigation ran: `ctx_upgrade` lost its git clone (#1309), and
`CONTEXT_MODE_DATA_DIR` came back with a new meaning (#1318). The adoption record
already weighed cadence against adoption ("223 npm versions in five months",
[context-mode-adoption.md](context-mode-adoption.md)); the pace is now faster.

**Decided.** Pin the latest stable at bump time. On each bump, re-check the A9a
findings items that moved between 2.1.3 and 2.1.4: outbound calls (1), store
layout and `CONTEXT_MODE_DATA_DIR` (3), and per-agent wiring (5). The three build
guards that fail on upstream drift are the tool: the hook-table comparison, the
OpenCode and Pi export checks, and the stats probe that requires a replaced `Read`
to add no row.

**Rejected: float on the latest.** The lockfile's integrity hash is the only
control on what is installed, and a floating version removes it.

## What this costs, and what is left open

| Item | State |
|---|---|
| Concurrent runs share a store across PID namespaces | **Open**, accepted. `THREAT_MODEL.md` |
| Replaced `Read`, `Grep`, `WebFetch` output unmeasured | **Open**, [#61](https://github.com/trevor-vaughan/claude-riotbox/issues/61) |
| Same-agent concurrent runs' figure is an upper bound | **Open** |
| OpenCode's embedded Bun not checked against the 24.15 floor | **Open** |
| 1.x stores remain on disk, unread | By design, until the user deletes them |
| Release cadence: a bump needs the A9a re-check | Ongoing |

## What was verified, and how

The upstream claims were measured by running code, not by reading docs, under
`docker.io/library/node:24` (`v24.22.2`) with `--network=none` unless noted: the
`ctx_doctor` offline and online outputs, the 0555 `EACCES` behaviour, the store
layout and owner-file lifecycle, the doctor exit codes with stub agents, and a
deterministic `context.db` from a canned `PostToolUse` payload. The OpenCode
loader paths were read from OpenCode 1.19.4's source. The OpenCode V2 loader and
OpenCode's embedded Bun were not run.
