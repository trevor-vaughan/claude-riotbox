# Should RiotBox adopt Context Mode?

**Decision:** Yes — as an opt-in (`RIOTBOX_CONTEXT_MODE=1`), mutually exclusive
with `RIOTBOX_HEADROOM=1`, and never a default.

**Date:** 2026-07-28 · **Issue:** [#5 — Investigate incorporation of Context Mode](https://github.com/trevor-vaughan/claude-riotbox/issues/5)

Two gates stood before implementation:

| Gate | State |
|---|---|
| Install pinned to Node ≥ 22.5, independent of `NODE_DEFAULT` | **Closed** — `ARG CONTEXT_MODE_NODE` plus a generated shim that execs that interpreter |
| Maintainer accepts an Elastic-2.0, non-OSI component in an otherwise MIT/Apache image | **Open** — assumed, not recorded. See [Decision](#decision). |

> **This is a frozen record of what we believed on 2026-07-28.** It is not a
> description of the current implementation, and two of its claims turned out to
> be wrong. For how Context Mode actually works today — what is wired, what it
> costs, and what is still unproven — read
> [How Context Mode works in RiotBox](../context-mode.md).

**Evaluated against:** [mksglu/context-mode](https://github.com/mksglu/context-mode) npm `context-mode@1.0.169`, git `06276b95` (2026-07-28), site [context-mode.com](https://context-mode.com/).

## Where this evaluation was wrong

Read the body below with these two corrections in hand:

- **`WebSearch` is not intercepted, and neither is `Glob`.** This document claims
  WebSearch is "hard-denied and redirected" and lists Glob among the routed tools.
  The matcher that actually decides is `CONTEXT_MODE_MATCHER`, reproduced verbatim
  from upstream, and it names `Bash`, `WebFetch`, `Read`, `Grep`, `Agent` and every
  MCP tool — no WebSearch, no Glob. Their output lands in the transcript in full.
  `Agent` (subagent calls) *is* intercepted, and went unmentioned here.
- **"Upstream supports both RiotBox agents" was true of upstream, not of RiotBox.**
  The first integration wired Claude Code only. opencode was wired later; see
  [context-mode-opencode.md](context-mode-opencode.md).

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
[What happened next](#what-happened-next).

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

## What happened next

Context Mode was adopted, in three rounds. **The implementation is documented
separately — see [How Context Mode works in RiotBox](../context-mode.md).** This
section records only how the plan below fared, so the plan is read as a proposal
rather than as a checklist of outstanding work.

**Landed as proposed:** the pinned-Node install and its build-time guards, the
launcher's mutual-exclusion refusal, the `riotbox doctor` check, the README and
`THREAT_MODEL.md` entries, and the tests. Item 5 — no `.git/info/exclude` or
overlay-ignore change — was checked rather than skipped: the store lives in the
session directory, and `OVERLAY_IGNORED_NAMES` in `scripts/lib/overlay-ignore.sh`
still lists `.codegraph` alone.

**Landed differently:**

- **Item 2's "generalise rather than duplicate" applied to the writer, not the
  stripper.** `json_write_atomic` was extracted to `scripts/lib/json-write.sh` and
  the two per-feature copies deleted. The strippers stayed separate, because they
  share a shape and no body.
- **Item 6's opencode suite had nothing to exercise for two rounds.** The first
  integration wired Claude Code only. opencode was wired in the third round; see
  [context-mode-opencode.md](context-mode-opencode.md).

**Still outstanding:** the head-to-head measurement that [Decision](#decision)
demands before Context Mode could become a *default*. A second agent does not
supply it, and the feature is opt-in for exactly this reason.

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

Two gates stood before implementation. One is closed on the facts; the other is a decision this branch proposes rather than records:

- **Licence — open.** The maintainer must accept an Elastic-2.0
  (source-available, non-OSI) component in an otherwise MIT/Apache image.
  - No legal blocker was found for RiotBox's usage or distribution model, but the
    precedent is the maintainer's to set.
  - The branch adopts Context Mode *assuming* ELv2 is acceptable, and documents
    the licence and its consequences in `THREAT_MODEL.md` and the README's licence
    note. No maintainer decision is on record, and nothing written by the branch
    can stand in for one.
  - **Merging is what turns the assumption into a decision.** Whoever does that
    should replace this note with a pointer to the record — a comment on
    [issue #5](https://github.com/trevor-vaughan/claude-riotbox/issues/5), or the
    merge itself.
- **Node floor — closed.** The install must be pinned to Node ≥ 22.5 independent
  of `NODE_DEFAULT`, or the image build breaks for any user on a Node 20 host.
  - Pinned via `ARG CONTEXT_MODE_NODE` plus a generated shim that execs that
    interpreter.

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
