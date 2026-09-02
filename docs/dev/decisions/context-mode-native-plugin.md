# Should RiotBox author Claude Code's Context Mode wiring, or install upstream's plugin?

**Decision:** Install upstream's plugin. Stage the marketplace tree in the image
at a pinned ref, register it against the session in place, and retire the six
hook stanzas and the `mcpServers` entry RiotBox used to write by hand.

**Date:** 2026-08-24 · **Issue:** [#17 — Context Mode: native plugin install and bun](https://github.com/trevor-vaughan/claude-riotbox/issues/17) · **Branch:** `feat/17-context-mode-native-plugin`

> **Frozen record.** Written after implementation, from what the work turned up.
> For the current implementation, read
> [How Context Mode works in RiotBox](../context-mode.md).

## TL;DR

The hand-authored wiring was inert on at least one system, and neither the build
guard nor `riotbox doctor` nor the exit report could tell. Upstream ships the
same six hooks and the same MCP server in a marketplace plugin, plus the slash
commands and skills the npm package does not carry, and it declares its own hook
commands — so there is no transcription to go stale.

The cost is real and is recorded below: RiotBox gave up the build-time assertion
on the matcher set, and it added a 60 MB tree and an unlocked `npm install` to
the image build.

*Correction:* the install is no longer unlocked — it is `npm ci --omit=dev`
against a lockfile RiotBox generates and commits. See the correction under *Why
`npm install --omit=dev`, and not something reproducible* below.

## The bug

`hookDispatch` (`src/cli.ts:158` upstream) closes fd 2 and reopens it on
`/dev/null` before doing anything — Claude Code reads any hook stderr as failure
— and then does `await import(join(getPluginRoot(), "hooks/pretooluse.mjs"))`.

`getPluginRoot()` branches on `detectPlatform()`. Every RiotBox image ships
Claude Code *and* opencode, so that detection has more than one config to choose
between and no way to know which agent is running; when it guesses an in-process
plugin platform it returns
`~/.cache/<platform>/packages/context-mode@latest/node_modules/context-mode`, a
path RiotBox's npm-global install never populates.

The import throws, into the stderr `hookDispatch` already pointed at
`/dev/null`. Nothing is printed, nothing routes, and the toggle, `riotbox
doctor` and the exit report all still report the feature as on. Because the
detection depends on what config happens to exist in a session, the same image
behaves differently on two machines. Upstream names this exact co-install
ambiguity as the reason it pins `CONTEXT_MODE_PLATFORM` for its own Copilot CLI
bundle.

Pinning `CONTEXT_MODE_PLATFORM` fixes the symptom, and it shipped first
(`3b4076a`) for exactly that reason — it is the smallest change that proves the
diagnosis. It is not what made the wiring worth retiring; the guard is.

## The old guard said what it was worth

The `Containerfile` block that asserted the dispatcher was a grep of its
`--help`, and the comment above it stated its own limit plainly: the dispatcher
"exits 0 and prints nothing for an event that does not exist, exactly as a valid
event fed empty stdin does — so invoking the dispatcher can only ever prove that
the CLI runs."

A Context Mode that reported itself enabled and routed nothing passed it. That
is the shape of the problem: RiotBox was asserting the existence of a CLI
surface, not the behaviour it needed, and the surface it was asserting was one
it only used because it wrote the stanzas that called it.

## What the plugin brings that the package does not

The npm package carries the hooks and the eleven `ctx_*` MCP tools. It does not
carry the user-facing surface: the `/context-mode:*` slash commands and the
bundled skills ship only in the marketplace plugin. There is no `commands/`
directory upstream — the commands *are* the eight entries under `skills/`, which
`.claude-plugin/plugin.json` declares with `"skills": "./skills/"`. Staging the
tree is what buys them.

The plugin also declares its own `hooks/hooks.json` and its own `mcpServers`
entry, which is the structural half of the decision: with upstream declaring
them, there is no RiotBox-side copy of the event set or the matchers left to
drift.

## A bare clone does not work offline

This was the finding that decided the shape of the build layer, and it is not
about the Node version.

Upstream's bundles mark `better-sqlite3`, `turndown`, `turndown-plugin-gfm` and
`@mixmark-io/domino` external. Without `node_modules`, every hook invocation
enters `hooks/ensure-deps.mjs` and shells out to `npm install`. Measured on a
bare clone under the pinned Node 22.23.1 with `--network=none`:

| Tree | Per-hook cost | Size |
|---|---|---|
| Bare clone | 120 s — `ensure-deps`' own `execSync` timeout — then a decision with rc=0 and `better-sqlite3` still absent | 14 MB |
| `npm install --omit=dev` at build time | 62 ms, `better-sqlite3` loads | 60 MB |
| After `ensure-deps` has run | — | 148 MB; it resolves devDependencies too |

`PreToolUse` fires on nearly every tool call. So the failure mode of the bare
clone is not "slower": it is two minutes per tool call, silently, with the FTS5
store — the entire feature — never coming up, and rc=0 throughout.

**The interpreter rewrite does not prevent it.** `ensure-deps` gates on
`existsSync(node_modules/better-sqlite3)` with no version condition. Upstream's
own comment is explicit that `hasModernSqlite()` exists "to skip the
SIGSEGV-prone child-process probe on modern Node, but NOT to skip installing
better-sqlite3."

### Why `npm install --omit=dev`, and not something reproducible

- **`npm ci` is impossible.** Upstream ships no `package-lock.json`, only
  `bun.lock`, which npm cannot read.

  *Correction:* this bullet is wrong, and the heading above it with it. `npm ci`
  is not impossible on a tree that ships no lockfile — one can be generated for
  it with `npm install --package-lock-only`, and that is what the layer now
  does. `container/context-mode-package-lock.json` is generated against the
  pinned commit, committed, and installed with `npm ci --omit=dev`, so every
  version in the tree is fixed and every entry carries an integrity hash npm
  verifies. The measurements in the table above stand unchanged: they were taken
  with `npm install --omit=dev` against the same package set. What replaced the
  reproducibility gap is a narrower one — `npm ci` does not by itself notice a
  lockfile a ref bump left stale, which is why the three-way ref/lockfile/package
  check in `tests/context-mode.venom.yml` exists. See
  [context-mode.md § What it costs](../context-mode.md#what-it-costs).
- **`bun install --frozen-lockfile --production` fails.** `package.json`
  declares no `trustedDependencies`, so bun skips `better-sqlite3`'s prebuild
  and falls through to node-gyp against its own spoofed `node -v v24.3.0`; the
  install script exits 1.
- **`--omit=dev` is what keeps it at 60 MB** rather than the 148 MB a full
  install lands, by leaving out typescript, tsx, vite, esbuild and rolldown.

What this does not buy is reproducibility. Without a lockfile npm re-resolves
the `^` ranges on every build, so the pinned ref fixes upstream's code and
nothing about its transitive dependencies. That is stated in the
`Containerfile`, in [context-mode.md § Known gaps](../context-mode.md#known-gaps),
and in `THREAT_MODEL.md`, because it is the one thing about this layer a reader
would otherwise assume was handled.

*Correction:* this paragraph no longer describes the build. The layer installs
from a committed lockfile — see the correction under the first bullet above.

## The routing probe

The replacement guard runs the real thing: it reads the `PreToolUse` command for
`WebFetch` out of the staged `hooks.json` — whatever the interpreter rewrite
produced, not a hardcoded string — feeds it a real `WebFetch` payload, and
requires a `hookSpecificOutput.permissionDecision` back. It would have caught
the original bug.

Two details are what make a pass mean anything, and both were established by
getting them wrong first.

**A private, seeded MCP sentinel directory.** `mcpRedirect()` returns `null`
unless `isMCPReady()` finds a `context-mode-mcp-ready-<PID>` file for a live
process, and no MCP server runs during a build — so an unseeded probe would fail
on every build for a reason unrelated to the tree it guards. Upstream's
`CONTEXT_MODE_MCP_SENTINEL_DIR` is the override for exactly this. It must point
somewhere private: upstream's default scan root is a hardcoded `/tmp`, and an
early version of this probe run on a developer host returned a decision and was
recorded as a pass while reading *that session's own running context-mode
server's* sentinel. The unseeded control run, which must return nothing, is what
makes the seeded run evidence rather than coincidence.

**`PATH=/usr/bin:/bin`.** With the build's PATH inherited, an un-rewritten
`node "…/pretooluse.mjs"` still answers `deny` — the `WebFetch` route is pure JS
and Node 20 runs it — so a probe inheriting the build PATH would pass on a tree
the substitution had missed. Worse, it would corrupt that tree: `ensure-deps`'
ABI heal fires below Node 22.5, `npm rebuild better-sqlite3` runs with the
build's network, and the tree comes back carrying the devDependencies
`--omit=dev` just excluded and a `better-sqlite3` the pinned Node can no longer
load — after the loader check had already passed. With no `node` resolvable, an
un-rewritten command produces nothing and fails the layer, which is the point.

## Host copies had to be excluded

`plugin_setup` merges `~/.host-plugins` over RiotBox's registry with host
entries winning. A host-installed `context-mode` would therefore displace the
staged tree with one that had been through neither the interpreter rewrite nor
the dependency install — Node 20, `ensure-deps`, 120 s per hook. Its
`known_marketplaces.json` `installLocation` also survived the container's
host-path rewrite walk pointing at a directory nothing here creates.

Context Mode is now skipped in the host-plugin copy loop while a staged tree
exists, and the registration is re-asserted after the merge rather than carving
an exception into each of the two merges and the path rewrite that follows them.
`context_mode_plugin_register` stays the one place that knows the shape of those
entries.

## What was retired, and what stayed

Retired: `agent_claude_context_mode_wire`, `context_mode_hook_table`,
`CONTEXT_MODE_MATCHER`, `CONTEXT_MODE_POST_MATCHER`, the three equality guards
that compared them to `hooks.json`, and the `hook <platform> <event>` dispatcher
assertion.

Stayed: `agent_claude_context_mode_strip`. Session directories outlive images. A
directory wired by the previous release still holds six stanzas dispatching
`<shim> hook claude-code <event>` and an `mcpServers` entry; `settings.json` is
deliberately never synced from the host, so nothing regenerates or removes them.
Reopened under this release beside the registered plugin, they would dispatch
every event twice against one server name two writers claim. The stripper is
what converges a reused directory on exactly one form of wiring, and it prunes
every key present in `.hooks` rather than a fixed list of the six, so an event
that leaves that list is not stranded forever.

**The verb that answers "does this agent have support" moved from `wire` to
`store_dir`.** Claude now has `store_dir`, `platform`, `strip` and
`build_assert`, and no `wire`; a probe on `wire` would read the best-supported
agent as unsupported.

## What this costs

**The matcher set is no longer asserted at build time, on either agent.**
`CONTEXT_MODE_MATCHER` and `CONTEXT_MODE_POST_MATCHER` were verbatim copies of
upstream's arrays, compared to `hooks.json` for equality, so a tool added or
dropped upstream failed the image build. There is no second copy to compare any
more. The staging layer still fails if `hooks.json` stops routing `WebFetch`
through `PreToolUse`, because that is the probe's entry point — but it says
nothing about the other five matchers. A version bump that quietly stopped
intercepting `Read` would now surface in a user session.

That is a genuine regression, accepted because keeping the copies meant keeping
the hand-authored wiring that made them necessary, and that wiring was inert.

*Correction:* the second half of that sentence claims more than the code
supports. The matchers were plain string constants and the guard compared them
against a `hooks.json` the build still stages and still parses, so the assertion
could have been kept with no wiring behind it. Keeping it would have cost a
hand-maintained transcription of upstream's two arrays, re-checked at every
version bump, carried in `agents/claude/context-mode.sh` beside the four verbs
that survived — a maintenance cost, which is what the coverage was actually
traded for, rather than a consequence forced by retiring the wiring.

*Correction (gate restored):* the regression this section describes stood for
one commit. `container/context-mode-hooks-expected.json` now holds the event set
and every event's matchers, and the staging layer projects the staged
`hooks.json` down to the same shape and requires equality before `npm ci` runs —
so a tool added or dropped upstream fails the image build, on the tree a session
actually loads. The transcription cost the correction above names is not paid:
the file is generated from the staged tree by a one-line `jq` recipe recorded
with the ref-bump steps in the `Containerfile`, and a reviewer reads its diff at
each bump. What stays true is the narrower claim in "What was retired": the
constants and the three equality guards in `agents/claude/context-mode.sh` are
gone, and nothing brought the hand-authored wiring back to get this coverage.

**A Claude session no longer prints a `[context-mode]` startup line.** The wire
verb printed it. The signal is now `[plugins] Context Mode <version> registered
at <path>`, emitted only by the call that changed something — so a session
directory already pointing at the staged tree prints nothing, and that silence
is normal.

*Correction:* the silence is normal in one common configuration and absent in
another. `plugin_setup` registers at step 3 and re-asserts after the host-plugin
merge — the second call only where `~/.host-plugins` is mounted — and that merge
overwrites the entry whenever the host tree carries a `context-mode` of its own.
There the re-assert has real work every run and the line prints every run, twice
on the first. "No write without a change" holds; "silent after the first run"
does not.

**The image grew.** 60 MB for the staged plugin, plus bun, which is installed as
a SHA256-verified release asset for `ctx_execute`'s TypeScript runtime.

## What was rejected

**Mirroring the store to a shared host directory.** #17 also asked for the
knowledge base to be reachable across sessions through a read-write mount.

The store already persists: `${RIOTBOX_DATA_DIR}/<session_key>` is a host
directory bind-mounted at `~/.claude`, so a project's content index survives
container exit and restart today. A shared mount would add reuse only across
*session keys* and across `riotbox session-reset` — and a reset that leaves the
knowledge base standing is not a reset.

Against that: the store holds verbatim tool output, so sharing it means a second
writable mount, readable by every session, enumerable by project name, and
outliving `riotbox session-remove` — plus a purge verb, a threat-model section,
and documented hazards around mtime-based pruning and WAL over virtiofs.

The cross-session ledger is the one deliberate exception to "a session's writes
live in its session directory," and it earns that because upstream prunes its
counters after seven days: that history cannot be re-derived. A content index
can be — re-indexing is automatic. If cross-session-key reuse later proves
valuable, it returns with a measurement behind it.

## An asymmetry worth knowing

`getAdapter`'s default branch returns `ClaudeCodeAdapter`, so an upstream rename
of the `claude-code` platform token is self-healing: a wrong token still lands
on the right adapter. `opencode` has no such fallback — a rename there silently
selects the Claude adapter for an opencode session. That asymmetry is why only
the opencode token got a build-time grep (`717a41e`), and why the Claude one did
not.

## What was verified, and how

Stated plainly, because the strongest claims here are the ones that were not
observed:

- **Run and passing.** `task lint`, `task test:lint`, and the venom suites,
  which are shell-level and hermetic — they source the scripts and assert what
  RiotBox registers, strips and refuses to touch.
- **Run, but not as a build.** Every `Containerfile` layer this branch adds. The
  bodies were extracted and run under `podman run` against the same base image:
  the clone, the dependency install, the loader check, both interpreter
  substitutions, and the routing probe including its unseeded control. The
  120 s / 62 ms figures and the three tree sizes come from those runs.
- **Not attempted, and why.** `podman build` does not work in this development
  container — `mounting an overlay over build context directory: … userxattr:
  invalid argument` from buildah, an environment limitation rather than a defect
  in the build. **No image on this branch has ever been built.** A real
  `riotbox rebuild` — not `riotbox build`, which reuses a cache predating this
  work — is required before the build path is trusted.
- **Not verified at all.** bun's `SHASUMS256.txt.asc` is published, but neither
  the signature nor its signing key is checked, here or in the refresh recipe in
  the `Containerfile`. The digests are transcribed by hand from the unsigned
  checksum file, which catches a retagged asset and nothing about a release that
  was already compromised when they were read.
- **Still not measured.** No head-to-head comparison against a session with the
  feature off exists. Context Mode stays opt-in for the reason
  [the adoption record](context-mode-adoption.md#decision) already gives, and
  fixing an inert integration does not change that — if anything it means every
  earlier impression of the feature's value on Claude was formed against
  something that may not have been running.
