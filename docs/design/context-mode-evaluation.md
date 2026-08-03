# Context Mode Evaluation — Is It a Valuable Addition to RiotBox?

**Status:** Adopted as an opt-in (`RIOTBOX_CONTEXT_MODE=1`). Of the two gates, only the Node floor is closed — pinned via `ARG CONTEXT_MODE_NODE` in the `Containerfile`, independent of `NODE_DEFAULT`. The licence gate is still a proposal: adoption assumes ELv2 is acceptable as the image's one non-OSI component, and merging this branch is what turns that assumption into the maintainer's decision (see [Decision](#decision)). What shipped differs from the plan below; see [What actually shipped](#what-actually-shipped), which also corrects one claim the evaluation got wrong. The evaluation body is otherwise as written on its original date; the exceptions are the agent-support subsection — rescoped, with a paragraph added, because its heading read as a claim about RiotBox — and the [Decision](#decision) section, whose gate framing was rewritten after the feature shipped. It is kept as the rationale the README links to.

**Evaluation date:** 2026-07-28
**Issue:** [#5 — Investigate incorporation of Context Mode](https://github.com/trevor-vaughan/claude-riotbox/issues/5)
**Evaluated against:** [mksglu/context-mode](https://github.com/mksglu/context-mode) npm `context-mode@1.0.169`, git `06276b95` (2026-07-28), site [context-mode.com](https://context-mode.com/).

## TL;DR

Context Mode solves a problem RiotBox genuinely has — autonomous sessions die of context exhaustion — and it solves it at a layer nothing in the image currently occupies: it intercepts *tool calls* before their output enters the transcript, parks the raw bytes in a local SQLite FTS5 store, and hands the agent a search tool instead. That is complementary to headroom, which compresses payloads in flight at the HTTP layer.

It also clears the issue's hard constraint outright. There is no telemetry to disable: the only outbound call in the package is an npm version check that fails soft. Verified by running `doctor` inside a network namespace with no connectivity — exit 0, one WARN.

Three things stand between "interesting" and "shipped":

1. **It will break the image build on a Node 20 host.** Context Mode hard-fails install on Linux below Node 22.5, and RiotBox's Containerfile defaults to Node 20. Solvable, but it is a real blocker, not a footnote.
2. **It is Elastic Licence 2.0** — source-available, not OSI open source. It would be the first such component in an otherwise MIT/Apache image. That is a maintainer policy call, not an engineering one.
3. **Its savings are compliance-dependent** on the path that matters most to RiotBox (Bash), where the hook nudges rather than compels. Upstream's own numbers put the hook path at ~98% and the instruction-only path at ~60%.

Recommendation: adopt as an opt-in (`RIOTBOX_CONTEXT_MODE=1`), mutually exclusive with `RIOTBOX_HEADROOM=1`, following the CodeGraph integration pattern — *if* the ELv2 licence is acceptable to the project.

## What Context Mode actually does

The mechanism matters more than the marketing, because the mechanism is what determines whether it fits.

A `PreToolUse` hook inspects each tool call before it runs. For tools whose output is likely to be large, it returns a decision to Claude Code:

- **WebFetch / WebSearch are hard-denied and redirected.** The hook emits `permissionDecision: "deny"` with a reason instructing the model to call `ctx_execute` or `ctx_fetch_and_index` instead (`hooks/core/formatters.mjs:56-63`). Those MCP tools do the fetch out-of-band, store the response, and return a summary.
- **Bash gets a nudge** — "May produce large output. Use ctx_…" — tuned for unbounded commands like `find /` or `cat large-file` (`hooks/core/routing.mjs:246-247`). Claude Code ignores `updatedInput.command` substitution under an `allow` decision, so upstream implements even the redirect as a deny carrying the payload in the reason string (`hooks/core/formatters.mjs:21-28`).
- Routing tables cover the equivalent tool names across 17 agent platforms — `Bash`, `Read`, `Grep`, `Glob`, `WebFetch`, and their per-platform aliases (`hooks/core/routing.mjs:505-555`).

Stored content is queried back through `ctx_search` against SQLite FTS5. Note that this is **lexical full-text search, not embedding-based semantic search**, despite the landing page's wording. There is no model to download and no inference cost — which is also why it needs no offline model baking, unlike headroom's ~350 MB.

The rest of the surface is `ctx_index` (index files/directories into the store), `ctx_stats`, `ctx_doctor`, `ctx_purge`, and `ctx_insight` — the last of which merely opens `context-mode.com/insight` in a browser (`src/cli.ts:1220-1228`); it uploads nothing.

## What we verified

Everything below was run against `context-mode@1.0.169` installed globally on Node v25.6.1 in a CentOS Stream 10 container.

### Telemetry: none. Constraint satisfied without configuration.

The issue's requirement is "telemetry must be disabled by default." Context Mode has nothing to disable.

- **Exactly one `fetch()` call exists in the entire source tree** (`src/server.ts:3017`), and it is the user-initiated URL fetch that backs `ctx_fetch_and_index` — i.e. a feature, not a beacon.
- The only other outbound endpoint is `https://registry.npmjs.org/context-mode/latest`, called from `src/cli.ts:390` and `src/server.ts:783` to warn about new versions. It sends no payload beyond the HTTPS request itself.
- `https://context-mode.com/insight` appears three times and is only ever passed to a browser-open helper.
- There is no analytics SDK anywhere — no PostHog, Segment, Sentry, Amplitude, or Mixpanel dependency. `package.json` lists eight runtime dependencies, all functional.
- The "331,200 developers" figure on the site comes from npm download counts scraped by a scheduled GitHub Action into `stats.json` (`.github/workflows/update-stats.yml`), not from any client-side reporting.

**Offline behaviour, verified empirically:**

```console
$ unshare -rn context-mode doctor
...
▲  npm (MCP): WARN — local v1.0.169, could not reach npm registry
└  Diagnostics complete!
$ echo $?
0
```

With no network at all, `doctor` completes and exits 0. The version check degrades to a warning.

One caveat worth recording: **there is no environment variable to suppress the version check.** Context Mode honours no `DO_NOT_TRACK`, and the source explicitly rejects bespoke opt-out env vars as a design stance (`src/security.ts:421`, `src/server.ts:1173`). RiotBox's convention for headroom and CodeGraph is an explicit, layered disable (`Containerfile:339-351`); here there is no lever to pull. The exposure is one unauthenticated GET to a public registry per server start, which is strictly less than the npm traffic the image already generates, but it is not zero and it cannot be turned off.

### Storage lands exactly where RiotBox wants it

```console
$ context-mode doctor
sessions: /home/llm/.claude/context-mode/sessions
content:  /home/llm/.claude/context-mode/content
stats:    /home/llm/.claude/context-mode/sessions
```

Storage roots at the *platform config directory* — `.claude` for Claude Code, `.config/opencode` for opencode (`src/adapters/detect.ts:337-355`). In RiotBox, `~/.claude` **is** the bind-mounted session directory (`~/.local/share/riotbox/<session>/`). So per-session isolation, host non-contamination, and cleanup via `riotbox session-remove` all come for free — no plumbing required. This is a better fit than either headroom (needed an explicit state path) or CodeGraph (writes into the project tree).

The store contains verbatim tool output — command results, file contents, fetched pages. It carries the same sensitivity as a session transcript and would need the same treatment in `THREAT_MODEL.md`.

### It installs cleanly and works on a modern Node

`npm i -g context-mode` completed in 3s, 139 packages, no native compilation (`better-sqlite3` resolved a prebuilt binary). `doctor` exits 0 and reports FTS5/SQLite working.

### Upstream supports both RiotBox agents

Upstream ships adapters for both agents RiotBox ships. The first integration wired
Claude Code only; a later branch wired opencode as well. See
[What actually shipped](#what-actually-shipped).

Claude Code is the reference platform. opencode has a real adapter — 1,563 lines across five files implementing opencode's TypeScript plugin paradigm (`tool.execute.before`, `tool.execute.after`, `experimental.session.compacting`). Upstream documents one gap: opencode has no `SessionStart` hook at all, which the adapter attributes to upstream issues #14808 and #5409 (the "Constraints" list in `build/adapters/opencode/plugin.js`). That degrades session-resume attribution, not core routing.

### Project health is strong

19,408 stars, 1,375 forks, 20+ human contributors beyond the author, 117 open issues, actively pushed. Source is TypeScript with a visible test suite (`vitest`), benchmark harness, and unusually candid inline documentation — the code cites its own issue numbers and prior failed fixes.

The flip side: **223 npm versions in five months** (0.4.0 on 2026-02-23 → 1.0.169 on 2026-06-29). Pinning is mandatory, and keeping the pin current is ongoing toil.

## Fit against RiotBox

**The problem is real here.** RiotBox exists to run agents autonomously for long stretches. The binding constraint on a long autonomous run is the context window, and the thing that fills it is tool output — exactly what Context Mode targets.

**The tool coverage matches RiotBox's workload.** An early concern was that Context Mode is tuned for MCP servers (Playwright snapshots, GitHub issue dumps) while RiotBox sessions are shell-and-filesystem heavy. The routing table refutes that: `Bash`, `Read`, `Grep`, and `Glob` are all first-class routed tools.

**It does not impose its own security policy.** `src/security.ts` re-enforces the *user's own* `permissions.deny` globs at the hook layer rather than inventing new restrictions. RiotBox sets `permission = "allow"` and runs `--dangerously-skip-permissions`, so there are no deny patterns to enforce and this subsystem is inert. That is the right answer for a box whose premise is unbridled autonomy.

**But it introduces denials into a no-friction environment.** PreToolUse hooks fire regardless of `--dangerously-skip-permissions` — hooks are not permission prompts. So a RiotBox agent *will* see `WebFetch` denied and be told to use `ctx_fetch_and_index`. The capability is preserved and the redirect is equivalent, but it is the first component in the image that tells the agent "no."

### Overlap with headroom

Both attack context bloat; they do it at different layers and do not collide:

|                | headroom                                 | Context Mode                                    |
|----------------|------------------------------------------|-------------------------------------------------|
| Layer          | HTTP proxy between agent and API         | PreToolUse hook + MCP server inside the agent    |
| Mechanism      | Compresses payloads in flight            | Keeps output out of the transcript entirely      |
| Guarantee      | Unconditional — the proxy sees everything | Compliance-dependent for Bash; hard for WebFetch |
| Recall         | Reversible copies, model retrieves on demand | `ctx_search` over FTS5                       |
| Cost           | ~350 MB of baked models, offline inference | SQLite only, no models                         |
| Licence        | Apache-2.0                               | Elastic-2.0                                      |

They would compose — Context Mode shrinks what enters the transcript, headroom compresses what remains — but the marginal benefit of running both is unproven, and stacking two interception layers doubles the surface where a session can misbehave. Two independent opt-in flags with undocumented interaction is a worse user experience than one clear choice.

**Recommendation: make them mutually exclusive**, the same way `RIOTBOX_NESTED` and `RIOTBOX_SOCKET` are. The launcher already has the pattern for refusing a contradictory pair.

## Blockers and risks

### 1. Node floor breaks the build (blocker)

Context Mode hard-fails installation on Linux below Node 22.5 unless Bun is the installing runtime. This is not a warning — `scripts/postinstall.mjs` calls `process.exit(1)`, deliberately, because `engines.node` is cosmetic under npm's default `engine-strict=false`. Upstream's reasoning: on Node < 22.5 without `node:sqlite`, `better-sqlite3`'s native addon hits a V8 `madvise` bug causing sporadic SIGSEGV ([nodejs/node#62515](https://github.com/nodejs/node/issues/62515)).

RiotBox's Containerfile defaults to Node 20:

```dockerfile
ARG NODE_VERSIONS="20"
ARG NODE_DEFAULT="20"
```
— `Containerfile:106-107`

Those args are overridden by `scripts/build.sh` with whatever nvm versions it finds on the host, so the failure is host-dependent: a maintainer on Node 22+ sees a clean build, a user on Node 20 sees the image build abort. That is the worst kind of bug — invisible to the person who shipped it.

**Fix:** install Context Mode under an explicitly pinned Node ≥ 22.5 from nvm, independent of `NODE_DEFAULT`, and leave the agent's default Node alone. The `nvm exec <version> npm i -g …` pattern keeps the two decoupled. A `riotbox doctor` check should assert the resulting binary actually runs.

### 2. Elastic Licence 2.0 (policy call, not engineering)

RiotBox is MIT. CodeGraph is MIT. headroom is Apache-2.0. Context Mode is [Elastic Licence 2.0](https://github.com/mksglu/context-mode/blob/main/LICENSE) — source-available, **not** OSI-approved. Its limitations:

> You may not provide the software to third parties as a hosted or managed service, where the service provides users with access to any substantial set of the features or functionality of the software.
>
> You may not move, change, disable, or circumvent the license key functionality in the software […]

Neither limitation binds RiotBox's actual usage. RiotBox is a local developer tool, not a hosted service, and the OSS package has no licence-key gate to circumvent — the commercial tier is the hosted Insight dashboard at $20/seat/month, which lives entirely on their side.

The redistribution question is also softer than it looks: the rpm/deb packages ship RiotBox's own scripts, and `riotbox build` pulls Context Mode from npm onto the user's machine at build time. RiotBox never redistributes their bits.

So this is not a legal blocker. It is a **project policy question**: does RiotBox want a non-OSI component in the image, and does it want to inherit whatever ELv2 becomes? That is the maintainer's call, and it should be recorded either way.

### 3. Savings are compliance-dependent where it matters most

Upstream's own compatibility table is refreshingly honest (`README.md:1410`):

| Path                     | Reported savings |
|--------------------------|------------------|
| Hooks (Claude Code auto) | ~98%             |
| Instruction-only         | ~60%             |

The hook path is far better, and RiotBox would use the hook path. But within the hook path, WebFetch/WebSearch are compelled while **Bash is only nudged** — the model can ignore the suggestion and run `cat huge.log` anyway. Their headline benchmark (376 KB → 16.5 KB, 96%, `BENCHMARK.md:10-15`) is measured on 21 curated scenarios with cooperative routing; it is a ceiling, not an expectation. Treat all of these as vendor claims. We have not measured Context Mode against a real RiotBox session, and we should before making it a default.

### 4. It writes hooks into `settings.json` — the CodeGraph problem, again

Context Mode installs `PreToolUse`, `PostToolUse`, `PreCompact`, `SessionStart`, `UserPromptSubmit`, and `Stop` hooks. RiotBox already learned what that costs: session `settings.json` is never synced in either direction, so wiring written by one image outlives that image, and RiotBox had to build a stripper that removes CodeGraph's hook when the binary is gone (see the CodeGraph section of `README.md` and `container/codegraph-setup.sh`).

Adding a second hook-writing tool means a second stripper, or generalising the existing one. Prefer generalising — a table of `(marker, binary, keys-to-strip)` beats a second bespoke script.

Upstream has its own scar tissue here: `hooks/pretooluse.mjs:15-18` records that an earlier version deleted user-written hook configs without consent, which they call "the documented cause of the regression." Their fix landed; ours should not depend on it.

### 5. Release cadence

223 versions in five months. Pin it (`ARG CONTEXT_MODE_VERSION=`), bump it deliberately, and expect the pin to be stale often. This is the same deal RiotBox already accepted for headroom and CodeGraph.

## What actually shipped

Adoption happened, and the plan in the next section is a record of what was proposed rather than a checklist of outstanding work. Three of its points did not land as written:

- **Item 2's "generalise rather than duplicate" landed for the writer, not the stripper.** The atomic JSON writer was extracted to `scripts/lib/json-write.sh` as `json_write_atomic`, sourced by `container/entrypoint.sh` ahead of both setup scripts and shipped by the `COPY scripts/lib/` the image already had; `codegraph_write_json_atomic` and `context_mode_write_json_atomic` are gone, and `tests/lib-json-write.venom.yml` covers the contract. The strippers stayed separate, because they share a shape and no body: `codegraph_strip_session_wiring` prunes a `UserPromptSubmit` command and the `mcp__codegraph__*` permission from `settings.json`, while Context Mode's stripper prunes riotbox's own hook entries from `settings.json` *and* the `mcpServers` entry from `.claude.json`, then reports which of the two it actually removed. (It was `context_mode_strip_session_wiring` at the time; the opencode round moved it to `agent_claude_context_mode_strip` in `agents/claude/context-mode.sh`.)
- **The first integration wired no opencode adapter, so `tests/context-mode-opencode.venom.yml` (item 6) had nothing to exercise.** Every stanza it wrote was Claude Code — `context-mode hook claude-code …` commands under `CLAUDE_CONFIG_DIR`, which opencode never reads. `context_mode_setup` therefore warned, stripped any wiring an earlier Claude session left in the same session directory, and skipped wiring for any agent other than `claude`. **This is no longer the case**: a third round of work wired opencode through the agent registry and item 6's suite now exists and is populated. See [the opencode round](#the-opencode-round) below; the rest of this bullet describes the state between the first integration and that branch.
- **This document's `WebSearch` and `Glob` claim is wrong.** "WebFetch / WebSearch are hard-denied and redirected" (above) and "WebFetch/WebSearch are compelled" (below) both overstate the coverage, as does listing `Glob` among the routed tools. The matcher that actually decides which tools reach the hook is `CONTEXT_MODE_MATCHER` (in `container/context-mode-setup.sh` then, in `agents/claude/context-mode.sh` since the opencode round), reproduced verbatim from upstream's `PRE_TOOL_USE_MATCHERS`, and it names `Bash`, `WebFetch`, `Read`, `Grep`, `Agent`, and every MCP tool. Neither `WebSearch` nor `Glob` appears in it, so a `PreToolUse` hook never fires for them and their output lands in the transcript in full. `Agent` — subagent calls — is intercepted and went unmentioned in this evaluation. The README documents the shipped set.

Items 1, 3, 4, 5, and 7 landed as proposed: the pinned-Node install and its build-time guards (`Containerfile`), the launcher's mutual-exclusion refusal (`libexec/launch.sh`), the `riotbox doctor` check (`scripts/preflight.sh`), the README and `THREAT_MODEL.md` entries, and — item 5 — no `.git/info/exclude` or overlay-ignore change, which was checked rather than skipped: the store lives in the session directory, and `OVERLAY_IGNORED_NAMES` in `scripts/lib/overlay-ignore.sh` still lists `.codegraph` alone. Items 2 and 6 landed except for the deviations above. The head-to-head measurement demanded in [Decision](#decision) before Context Mode could become a *default* has still not been made — it is opt-in for exactly that reason.

A second round of work (`f8a4f8f`..`6c27c03`) closed three gaps the first integration left open:

- **The hook subset is gone; all six are wired.** The first integration wired `PreToolUse` and `SessionStart` only. That left the session DB — the store `SessionStart` replays and `/resume` restores from — with no writer at all, so continuity never engaged and an autocompact lost the resume snapshot `PreCompact` exists to write. One `context_mode_hook_table` drives wiring, stripping and the build guards (in `container/context-mode-setup.sh` then, in `agents/claude/context-mode.sh` since the opencode round).
- **The head-to-head measurement this document demands is now possible.** A session prints bytes kept out on exit (`container/context-mode-summary.sh`), read from upstream's own counters rather than from the humanized statusline. Before it, an enabled run and a run the model ignored looked identical from outside, which is why the measurement had never been made.
- **The event bridge the four new hooks reach is neutralized**, and the limits of that neutralization are recorded in `THREAT_MODEL.md` rather than overstated.

**The exit report's formula deliberately diverges from upstream's, and the divergence is the point.** The renderer first mirrored `statusline` and `ctx_stats` exactly — `bytesAvoided + snapshotBytes + eventDataBytes` as "kept", over that plus `bytesReturned` as a percentage — on the reasoning that two numbers for one store must not disagree. Reading `build/session/analytics.js` showed that formula counts things that are not savings: `eventDataBytes` is `SUM(LENGTH(data))` over every `session_events` row, the continuity bookkeeping each `PostToolUse` writes whether or not anything was redirected, and `snapshotBytes` is the `PreCompact` resume snapshot, which is context added *back* after a compact. The denominator holds only retrieval cost, so the percentage is pinned near 100% by construction and reads *lowest* exactly when the feature is working hardest — a session that redirected nothing printed `11.7 KB kept out (100%)`. The report now prints `bytesAvoided` alone as "kept out", the `bytesReturned` delta beside it as a re-read cost, and no percentage. It will therefore show a smaller number than `context-mode statusline` for the same store; ours is the saving, theirs is the saving plus this feature's own accounting.

**The silence rules were then removed outright, and that reversal is worth recording.** Splitting the counters made a zero report possible for the first time, and the rules were re-derived to suppress it: a session that wrote continuity events but redirected nothing printed nothing at all, on the reasoning that a zero is not a result worth a block of output. Using it disproved that. The report is the only evidence a session leaves, so "no report" had to carry two unrelated meanings at once — *the feature engaged and saved nothing*, and *the feature never engaged* — and the first is precisely the measurement this document asks for while the second is a bug. A user cannot tell them apart, and neither could we without reading the store by hand. The renderer now always prints for a wired session, and `eventDataBytes` is printed beside the zero rather than being excluded from the report entirely: it is the counter that distinguishes "the hooks fired and withheld nothing" from "the hooks never fired". It is still never added to the saving — that remains upstream's error, not ours.

**It is labelled "hook log on disk", and the unit is load-bearing.** The term first read "event bookkeeping", which put a number that is not context bytes on a line of context bytes and invited it to be read as a token cost. Reading the bundle settles it: `session_events` rows are consumed only by aggregate queries (`COUNT`, `SUM(LENGTH(data))`, `GROUP BY category`) and by `getMcpToolUsage`; nothing feeds them to a hook's `additionalContext`, so they never reach a model's context and cost zero tokens. What `hooks/sessionstart.mjs` does inject is the routing block, the session directive, and snapshot-derived content — which is why `snapshotBytes`, the counter that genuinely re-enters context after a compact, stays out of the savings figure. Stating the unit on the line is what keeps a proof-of-life signal from being mistaken for a price.

**`PostToolUse` costs ~112 ms per tool call, and interpreter startup is nearly all of it.** This is the one cost of the full hook set that could plausibly outweigh its benefit: `PostToolUse` fires on nearly every tool call, and each fire spawns the pinned Node. Upstream's `hooks/posttooluse.mjs:8` promises "<20ms", but that is the SQLite work, not the process. Measured against the real `context-mode@1.0.169` inside `quay.io/centos/centos:stream10` on Node v22.23.1 — the same version `ARG CONTEXT_MODE_NODE` pins — 50 invocations per condition, each piping a 2 KB `Write` payload that actually lands a row in `session_events`: **112.6 ms/call against an empty store, 112.5 ms/call against a store already holding 350 events with WAL open.** Warming the store changes nothing measurable, so the first-ever write is not a special case. The breakdown is the useful part: `node -e ''` alone is 64.7 ms/call on the same container, and importing the hook's module graph without touching the DB is 94.7 ms/call, so roughly 85% of the wall clock is interpreter startup plus module load and only ~17 ms is the SQLite work — upstream's claim, honoured. Nothing in RiotBox's control moves the other 95 ms short of not spawning a process per tool call.

At ~112 ms the hook stays. It is comfortably below the ~150 ms line the implementation plan set for reopening the decision, and it is what buys the session DB that `SessionStart` replays and `PreCompact` snapshots — the whole reason the four writers were wired. The cost is real rather than negligible, though, and it is worth stating in the units a long run feels: an agent making 2,000 tool calls pays about 3.7 minutes of wall clock for continuity, serialized into the tool-call path. That figure scales with Node's startup time on the host, not with the size of the store, so a slower machine pays proportionally more and no amount of store pruning helps. If it ever needs to come down, dropping `PostToolUse` alone would retain `UserPromptSubmit`, `PreCompact` and `Stop` — which fire per prompt, per compact and per turn, orders of magnitude less often — at the cost of the per-tool-call events those three have nothing to write.

### The opencode round

A third round (branch `feat/context-mode-opencode`, design in `docs/design/2026-07-31-context-mode-opencode-design.md`) wired the opencode adapter and moved the per-agent wiring behind registry verbs. `container/context-mode-setup.sh` now names no agent: each agent supplies `context_mode_store_dir`, `context_mode_wire`, `context_mode_strip` and `context_mode_build_assert` in `agents/<name>/context-mode.sh`, and every caller probes with `declare -F`. What that branch established is recorded below in the two registers this document uses elsewhere.

**Verified by running it, against `context-mode@1.0.169` and `opencode 1.18.10` as installed in the image:**

- **The adapter initialises under opencode's embedded bun.** Loaded through a local plugin file, `ContextModePlugin(ctx)` returns without error under **bun 1.3.14** and yields seven hook keys: `tool`, `tool.execute.before`, `tool.execute.after`, `event`, `chat.message`, `experimental.session.compacting`, `experimental.chat.system.transform`.
- **The Node floor does not apply to this path.** bun's SQLite is **3.53.0 with FTS5 compiled in**, checked by creating an FTS5 virtual table and matching against it from inside the loaded plugin. `build/db-base.js` bridges `bun:sqlite` to the better-sqlite3 API, so the native addon that forced `ARG CONTEXT_MODE_NODE=22.23.1` is never loaded here.
- **Eleven `ctx_*` tools arrive in-process, not over MCP.** The plugin imports `build/server.js` with `CONTEXT_MODE_EMBEDDED_PLUGIN_TOOLS=1` and registers every entry of `REGISTERED_CTX_TOOLS` as a native opencode tool: `ctx_batch_execute`, `ctx_doctor`, `ctx_execute`, `ctx_execute_file`, `ctx_fetch_and_index`, `ctx_index`, `ctx_insight`, `ctx_purge`, `ctx_search`, `ctx_stats`, `ctx_upgrade`. **No `mcpServers` entry is written for opencode, and none is needed.** That same env var is what skips `main()`, where the `registry.npmjs.org` version check lives — so the one residual outbound GET has no counterpart on this path.
- **Local plugins load from `plugins/` (plural).** A file placed in the singular `plugin/` never loaded. RiotBox writes exactly one file there, `riotbox-context-mode.js`, re-exporting the vendored adapter by absolute path.
- **`CONTEXT_MODE_DIR` governs the storage resolvers behind the `ctx_*` tools.** With it set, `resolveSessionStorageDir` and `resolveContentStorageDir` return `<override>/sessions` and `<override>/content` tagged `source: "override"`.

**Read from source, not observed end to end:**

- **The pin does not cover the plugin's own session database.** That path comes from `adapter.getSessionDir()` directly (`build/adapters/opencode/plugin.js`), which honours `CONTEXT_MODE_DATA_DIR` and otherwise derives from `${XDG_CONFIG_HOME:-~/.config}/opencode` — not from `CONTEXT_MODE_DIR`. In the image the two coincide, because `XDG_CONFIG_HOME` is unset and `~/.config/opencode` *is* the session bind mount, so both stores land in the session directory either way. Risk 1 of the design asked for the store path to be confirmed by observation before the feature was documented as pinned; what was confirmed is the resolver, not a store created by a live opencode session.
- **No opencode session has been run end to end.** `tests/context-mode-opencode.venom.yml` is shell-level and hermetic — it sources the scripts and asserts what riotbox writes, strips and refuses to touch — for the same reason the Claude suites are: exercising the routing needs a model and credentials CI does not have. Nothing on this branch measures a saving on opencode.

**Two degradations are documented rather than fixed.** opencode has no `SessionStart` hook upstream, so resume attribution is weaker than on Claude Code; and `opencode --pure` disables external plugins outright, so Context Mode cannot engage at all — riotbox warns on stderr when it sees that flag with the toggle on, and changes nothing else, because `--pure` is the user's explicit instruction.

`riotbox ctx-stats` needed no change. `container/context-mode-summary.sh` already resolved the store through `CONTEXT_MODE_DIR` and already stamped `agent` into every ledger record, so opencode runs aggregate alongside Claude ones with no schema bump; `tests/context-mode-ledger.venom.yml` pins that field. The [Decision](#decision) below is untouched by all of this: the head-to-head measurement it demands before Context Mode could become a *default* still has not been made, and a second agent does not make it.

**Unverified: the image has never been built.** `podman build` fails in every container this branch was developed in (`mounting an overlay over build context directory: … userxattr: invalid argument`), so `task container:build` could not be run even once. Everything above the `Containerfile` line — the shell functions in `container/context-mode-setup.sh` and `container/context-mode-summary.sh`, and the Venom suites that exercise them by sourcing the scripts directly — was verified that way, and the `Containerfile` blocks that could not be sourced were verified by running their bodies inside `quay.io/centos/centos:stream10` against the real `context-mode@1.0.169`, as Task 6 of the implementation plan describes. What that technique cannot reach is the image build itself: the `COPY`/`chmod` layers that ship `context-mode-summary.sh` and set its permissions, the nvm-resolved Node path baked into the generated shims, the `--help` grep, `context-mode doctor` running inside the built image, and the two sentinel `RUN` layers, all as they behave once composed into actual `Containerfile` layers rather than as standalone shell run against a bare CentOS container. A real `riotbox rebuild` — not `riotbox build`, which would reuse a cache that predates this branch — is required before this branch is trusted, and should be the first thing done with a working `podman build`.

## What adoption would look like

If the licence is acceptable, the work follows the CodeGraph integration almost exactly — that commit (`7c6f886`) is the template:

1. **Containerfile** — `ARG CONTEXT_MODE_VERSION=1.0.169`, installed under a pinned Node ≥ 22.5 via nvm, below the `LLM_TOOL_UPDATE` cache-bust boundary alongside headroom/opencode/Claude Code/CodeGraph.
2. **`container/context-mode-setup.sh`** — runs at session start when `RIOTBOX_CONTEXT_MODE=1`; wires the MCP server and hooks into the session's `settings.json`; strips its own wiring when the binary is absent (generalise CodeGraph's stripper rather than duplicating it).
3. **Launcher** — `RIOTBOX_CONTEXT_MODE=1`, accepting only the literal `1` (matching `RIOTBOX_HEADROOM`); refuse to start when both it and `RIOTBOX_HEADROOM=1` are set, mirroring the `RIOTBOX_NESTED`/`RIOTBOX_SOCKET` guard.
4. **`riotbox doctor`** — assert the binary runs on the pinned Node and that FTS5 is functional; flag unrecognised toggle values.
5. **`.git/info/exclude`** — nothing needed; the store lives in the session dir, not the project tree. Confirm this holds under overlay mode, where the session dir is already handled.
6. **Tests** — `tests/context-mode.venom.yml` for the Claude path, `tests/context-mode-opencode.venom.yml` for opencode, `tests/doctor-context-mode.venom.yml` for the preflight, plus a mutual-exclusion case in the launcher suite.
7. **Docs** — a README section parallel to "Headroom context compression (opt-in)"; a `THREAT_MODEL.md` entry covering the FTS5 store as transcript-grade sensitive data and the unsuppressable npm version check; this document linked as the rationale.

**Before it becomes a default**, measure it: one representative RiotBox task run three ways (bare, headroom, Context Mode), comparing tokens consumed and task outcome. Their 96% is measured on their scenarios; ours is the only number that should drive a default.

## Decision

**Context Mode is a valuable addition, conditionally.** It targets RiotBox's actual binding constraint, occupies a layer nothing else in the image occupies, satisfies the telemetry requirement with no configuration at all, and lands its state exactly where RiotBox's session model wants it. Adopt it as an opt-in behind `RIOTBOX_CONTEXT_MODE=1`, mutually exclusive with `RIOTBOX_HEADROOM=1`.

Two gates stood before implementation. One is closed on the facts; the other is a decision this branch proposes rather than records — see [What actually shipped](#what-actually-shipped) for the code:

- **Licence:** the maintainer must accept an Elastic-2.0 (source-available, non-OSI) component in an otherwise MIT/Apache image. No legal blocker was found for RiotBox's usage or distribution model, but the precedent is the maintainer's to set. *Proposed, not accepted. The branch adopts Context Mode on the assumption that ELv2 is acceptable, and documents the licence and its consequences in `THREAT_MODEL.md` and in the README's licence note; no maintainer decision is on record, and nothing written by this branch can stand in for one. Merging it is what makes the assumption a decision. Whoever does that should replace this note with a pointer to the record — a comment on [issue #5](https://github.com/trevor-vaughan/claude-riotbox/issues/5), or the merge itself.*
- **Node floor:** the install must be pinned to Node ≥ 22.5 independent of `NODE_DEFAULT`, or the image build breaks for any user on a Node 20 host. *Pinned via `ARG CONTEXT_MODE_NODE` plus a generated shim that execs that interpreter.*

Do **not** make it a default, and do not enable it alongside headroom, until the head-to-head measurement above exists.

**Re-evaluation signals** if we defer:

- Upstream relicenses to an OSI licence, or ships a licence-key gate that changes the ELv2 calculus.
- The Bash path gains compelled routing rather than a nudge.
- `better-sqlite3` stops being load-bearing (upstream migrating fully to `node:sqlite` would drop the Node 22.5 floor to whatever `node:sqlite` requires and remove blocker #1).
- Release cadence settles enough that pinning stops being weekly toil.

## Reproducing this evaluation

```sh
git clone --depth 1 https://github.com/mksglu/context-mode.git   # 06276b95
npm i -g context-mode@1.0.169
context-mode doctor            # storage paths, FTS5, hook wiring
unshare -rn context-mode doctor  # offline behaviour — expect exit 0 + one WARN
```

Source claims in this document cite paths inside that clone. No RiotBox session was measured; that gap is deliberate and named in [Decision](#decision).
