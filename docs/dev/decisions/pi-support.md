# How should RiotBox add Pi as a third agent?

**Decision:** Add [Pi](https://pi.dev/) as a native RiotBox agent. Pi core floats
to the latest release, installed from the lockfile pi.dev publishes for that
release; the extensions that give it parity with Claude Code are pinned in a
committed lock. Pi runs without approval prompts and trusts project resources.
git-ai and Context Mode are wired; forge MCP and headroom are not. pi-memory/QMD
is deferred.

**Date:** 2026-10-13 · **Issue:** [#16](https://github.com/trevor-vaughan/claude-riotbox/issues/16) · **Branch:** `16-pi` · **Verified against:** Pi 1.2.0, context-mode v1.0.169, git-ai v1.7.5

> **Frozen design record.** This is what was believed and decided on the date
> above. For how Pi behaves today, read [README § Using pi](../../../README.md#using-pi),
> [THREAT_MODEL § Pi auth surface](../../../THREAT_MODEL.md#pi-auth-surface) and the
> headers of the files under `agents/pi/` and `container/pi/`.

## Context

Issue #16 asked for two things: Pi with as much parity to Claude Code and opencode
as practical, and every Pi package RiotBox includes pinned and chosen for
reputability and maintainability.

The user supplied a handoff archive from a host-native Pi experiment. It informed
this design, but its recorded tests were for a different package set and are
historical evidence, not proof for RiotBox. The archive is untrusted input and
was never committed.

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | No `@gotgenes/pi-permission-system`; Pi runs without approval prompts | The container is RiotBox's security boundary, as for Claude (`--dangerously-skip-permissions`) and opencode (`permission = "allow"` plus `--auto`). Pi's own `docs/security.md` says approvals are not a boundary and that containerisation is "usually the strongest practical option". User decision. |
| D2 | pi-memory + QMD deferred to a follow-up issue | See [Deferred](#deferred). |
| D3 | Pi core floats: the build resolves `@earendil-works/pi-coding-agent@latest` and installs it from `https://pi.dev/api/installer/releases/<ver>/{package.json,package-lock.json}` | Matches the latest-at-build policy for Claude Code and opencode (user decision). Upstream's per-release lock keeps every transitive dependency exactly as upstream shipped that release. Upstream `install.sh` was rejected: it is interactive, and its managed install lives under `~/.pi/agent/install`, which the session bind mount of `~/.pi/agent` would shadow. The extensions' peer ranges on Pi are `*`. |
| D4 | Extensions: `pi-subagents@0.77.0`, `@juicesharp/rpiv-ask-user-question@2.13.8`, `@juicesharp/rpiv-todo@2.13.8` (which pulls `@juicesharp/rpiv-config@2.13.8`) | Parity with Claude Code's Task, AskUserQuestion and TodoWrite. All MIT, no install scripts; see [Reputability](#reputability-2026-10-13). gotgenes' subagents package was rejected: about 15K downloads a month and 255 stars, and its advantage, forwarding approvals from child agents, is moot under D1. |
| D5 | Two install prefixes. Core: upstream's lock, `npm ci --ignore-scripts --omit=dev`. Extensions: committed `container/pi/package.json` + `package-lock.json`, `npm ci --ignore-scripts --omit=dev --legacy-peer-deps` | The issue requires included packages to be pinned, and the extensions are. A floating core cannot share a committed lock, so one shared lock was rejected. `--legacy-peer-deps` keeps a second Pi core out of the extension tree; Pi's loader supplies the SDK modules extensions import. That pattern was proven for Pi 1.1.0 in the handoff and will be re-proven on every build by the SDK smoke. For Pi 1.2.0 the smoke was run against the scratch install and in a `podman run` of the layer's `RUN` body in `quay.io/centos/centos:stream10` (commit `872ea63`). Follows the `container/context-mode-package-lock.json` precedent. `package.json` overrides `@juicesharp/rpiv-config` to `2.13.8` so rpiv's `^` range cannot drift from the locked shared config. |
| D6 | Own `ARG PI_NODE=22.23.3`, installed through nvm | Pi needs Node 22.19 or later. Same version as `CONTEXT_MODE_NODE`, so nvm reuses it and Context Mode's Pi extension runs on the ABI it was installed with, but the two can move independently. |
| D7 | Host sync copies an allowlist of `~/.pi/agent`; RiotBox owns `settings.json` `packages` | Host `packages` entries are absolute host paths or npm/git specs. Pi expands only `~/` (`dist/utils/paths.js` `normalizePath`), never `$HOME` or `${VAR}`, and installs missing npm/git sources at startup (`dist/core/package-manager.js` `resolvePackageSources`), which would be unpinned runtime installs. Passing host packages through was rejected for both reasons. |
| D8 | Also sync `~/.pi/agent/extensions/`; do not sync `~/.agents/skills/` | User decision. Extensions are host-authored code, the same trust class as the Claude hooks and opencode plugins RiotBox already copies. |
| D9 | Force `defaultProjectTrust: "always"` | Parity: Claude and opencode load project config unconditionally in RiotBox, and Pi's print mode with `ask` silently skips a project's `.pi/` resources. User decision. |
| D10 | Wire git-ai and Context Mode. Do not wire forge MCP (user decision) or headroom | git-ai v1.7.5 ships `src/mdm/agents/pi.rs`; context-mode v1.0.169 ships `src/adapters/pi/` and declares `pi.extensions` and `pi.skills` in its `package.json`. headroom-ai 0.39.0's `wrap` has no Pi target. |
| D11 | `agent_pi_env_vars` is the same eight keys opencode lists | `libexec/passthrough-vars.sh` unions every agent's list into every container. Listing Pi's roughly 45 provider keys would forward them into Claude and opencode sessions too. Other keys go through the existing `RIOTBOX_PASSTHROUGH_EXTRA_VARS`. This also showed that `THREAT_MODEL.md`'s claim that one manifest's keys do not widen the others was wrong; it was corrected. |

## Additions from planning research

Checked against Pi 1.2.0 and the pinned extensions in a scratch install on
2026-10-13:

- The extension lock was generated with
  `npm install --package-lock-only --legacy-peer-deps --ignore-scripts`: 10
  packages, no install scripts, no Pi core.
- **Pi silently skips a `packages` path that does not resolve** — no error, no
  warning. `container/pi/smoke.mjs` therefore asserts that every declared package
  contributed an extension that registered tools, plus the parity tools
  `subagent`, `ask_user_question` and `todo`.
- Extensions in `~/.pi/agent/extensions/` are discovered as `.js` or `.ts`, not
  `.mjs`, so test fixtures use `.js`.
- The image had `ripgrep` but not `fd`, and Pi's `find` tool downloads an
  unpinned `fd` from GitHub into `~/.pi/agent/bin` when it is missing. EPEL's
  `fd-find` was added to the existing `ripgrep bats` dnf line.
- git-ai v1.7.5's Pi extension has no banner. `agent_pi_git_ai_strip` identifies
  it by two template lines, `// Optional user-owned override file. Managed
  installer never writes it.` and a line starting `const GIT_AI_BIN = '`, both of
  which must match whole within the first 12 lines. The generated file loads
  cleanly under Pi 1.2.0.
- Context Mode: PiAdapter defaults its DB to `~/.pi/context-mode/sessions`,
  outside the session mount. `CONTEXT_MODE_DATA_DIR=~/.pi/agent` relocates it,
  because PiAdapter inherits `BaseAdapter.getSessionDir()`. A faux turn with the
  context-mode package listed put `ctx_*` in the system prompt and the DBs in
  `.pi/agent/context-mode/sessions`. The `ctx_*` tools register lazily on
  `before_agent_start`, so a load-time smoke cannot see them.
- The build-time lock check, `container/pi/lock-integrity.sh`, came out of
  review: upstream's 1.2.0 lock omits `integrity` for seven first-party
  `@earendil-works` entries, which `npm ci` would install unverified.

## Deferred

- **pi-memory + QMD.** The image has no bubblewrap and the default user namespace
  cannot host a nested bwrap; QMD's GGUF models are about 2.5 GB; and pi-memory is
  the weakest repository considered (191 stars, 7 contributors). QMD's lock
  carries 7 affected package entries from 5 advisories (`simple-git`,
  `@simple-git/argv-parser`, `braces`), per the npm audit recorded in the handoff
  experiment (2026-10). The user's position, to carry into the follow-up, is
  that the handoff experiment did not exercise the vulnerable paths. The
  follow-up issue has not been filed yet.
- **The permission system** (D1).
- **DCP** (Dynamic Context Pruning, `@pi-vault/pi-dcp`). Rejected in the handoff
  experiment: version 0.10.0 failed 2 of its 60 policy checks (malformed
  ownership), and it is a single-maintainer project.
- **Generated `models.json` for custom endpoints.** The host `models.json` is
  synced; keys go through `RIOTBOX_PASSTHROUGH_EXTRA_VARS`.
- **Google Vertex and vertex-anthropic.** Both need separately verified native
  configuration, and Pi has no built-in `google-vertex-anthropic` provider (the
  handoff found none in Pi 1.1.0; Pi 1.2.0's `pi-ai` provider-key list has
  `google-vertex` and no `google-vertex-anthropic`).

Also out of scope: forge MCP and headroom (D10), and porting the handoff's skills,
since the host `skills/` sync covers skills the user owns.

## Reputability (2026-10-13)

Downloads are npm's last-month count (2026-09-12 to 2026-10-11). Stars and
contributors are from the GitHub API on the same day; contributors exclude
anonymous ones.

| Package | Downloads/month | Repository | Stars | Contributors | Licence |
|---|---|---|---|---|---|
| `@earendil-works/pi-coding-agent` (core, floats) | 16.1M | earendil-works/pi | 114.8k | 291 | MIT |
| `pi-subagents@0.77.0` | 609K | nicobailon/pi-subagents | 3.9k | 168 | MIT |
| `@juicesharp/rpiv-ask-user-question@2.13.8` | 299K | juicesharp/rpiv-mono | 892 | 40 | MIT |
| `@juicesharp/rpiv-todo@2.13.8` | 195K | juicesharp/rpiv-mono | 892 | 40 | MIT |
| `@juicesharp/rpiv-config@2.13.8` (dependency) | 456K | juicesharp/rpiv-mono | 892 | 40 | MIT |

The three rpiv packages share one monorepo, so its stars and contributors are
counted once, not three times. The rejected alternatives' numbers (gotgenes'
subagents, pi-memory) were taken during brainstorming and not re-fetched.

## Cross-agent effects of Pi's host sync

`scripts/mount-projects.sh` runs `host_sync` for every registered agent on every
launch, as it already did for opencode. So with Pi registered:

- A user without Pi sees a one-line notice on stderr, `Notice: <host Pi dir> not
  found on host — pi will use the container baseline.`, whatever `--agent` they
  chose.
- When the host has Pi credentials, `auth.json` and `mcp-auth.json` are
  bind-mounted read-write into Claude and opencode sessions too, the same as
  opencode's `auth.json` today.
- Context Mode detection is unaffected. Upstream's detection would pick `pi`
  whenever `~/.pi` exists, which is now every session, but the platform is pinned
  per agent through `context_mode_platform`, and for Claude `~/.claude` wins
  detection anyway.
- git-ai's Pi extension is written only into the session copy of
  `~/.pi/agent/extensions/`, never into the host directory.

## tokscale and a relocated Pi directory

`riotbox tokscale` scans every RiotBox session's `.pi-agent/sessions` regardless
of configuration. For the host's own Pi sessions it relies on tokscale, which
reads `PI_CONFIG_DIR`, not `PI_CODING_AGENT_DIR`. A user who relocated their Pi
agent directory with `PI_CODING_AGENT_DIR` must also set `PI_CONFIG_DIR` for
tokscale to see their native (non-RiotBox) Pi usage. The variable name was read
out of the tokscale binary's strings; the exact value tokscale expects was not
verified.

## Known limits

- **Pi silently skips unresolvable packages.** That is why the build smoke exists:
  without it, a Pi release that broke a pinned extension would ship a session
  where the extension quietly does nothing.
- **Pi prepends piped stdin to the first prompt** (its `docs/cli.md`). That does
  not carry through `riotbox run`: the launcher runs
  `podman run -it`, so the agent's stdin inside the container is a terminal even
  when the host side is a pipe (checked with a `[ -t 0 ]` probe under
  `podman run -it`, which also printed podman's "input device is not a TTY"
  warning).
- **The `riotbox run`-level tests need an image build.**
  `tests/pi-integration.venom.yml` (opt-in, `INTEGRATION=1`) runs a faux-provider
  turn and, with a key, live turns through `riotbox --agent=pi run`. `podman build`
  does not work in the dev container, so it has not run there.

## What was verified, and how

- **Run:** the shell-level suites (`tests/pi.venom.yml`,
  `tests/context-mode-pi.venom.yml`, and the Pi cases in `tests/agents.venom.yml`,
  `tests/git-ai.venom.yml` and `tests/tokscale.venom.yml`).
- **Run:** live turns with the user's NVIDIA key, directly in the dev container
  rather than through `riotbox run`: Pi with its built-in `nvidia` provider and
  model `nvidia/nemotron-3-ultra-550b-a55b`, and opencode with
  `OPENCODE_CONFIG_CONTENT` selecting `nvidia/nvidia/nemotron-3-ultra-550b-a55b`.
  Both passed.
- **Run:** `@latest` resolved to 1.2.0 both in the scratch install and in a
  `podman run` of the Pi layer's `RUN` body in `quay.io/centos/centos:stream10`
  (commit `872ea63`), where the generated shim reported `pi --version` 1.2.0. The
  seven missing `integrity` values were filled from the registry.
- **Read, not run:** the upstream behaviours cited in D3, D7 and D10, the
  Context Mode extension's routing (`tool_call` on `bash` only at v1.0.169), and
  the absence of a `google-vertex-anthropic` provider in Pi 1.2.0
  (`pi-ai/dist/env-api-keys.js`).
- **Not run:** a full `podman build` of the image, and the integration suite
  through `riotbox run`.

## Open follow-ups

- File the pi-memory/QMD follow-up issue, carrying the evidence in
  [Deferred](#deferred).
- Find the `PI_CONFIG_DIR` value tokscale expects, and document it.
- Run `tests/pi-integration.venom.yml` through `riotbox run` on a host where
  `podman build` works.
- The two Pi rows in [context-mode.md § Known gaps](../context-mode.md#known-gaps):
  no Pi session run end to end through `riotbox` with Context Mode on, and Pi's
  routing not asserted at build time.
