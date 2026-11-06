# Moving RiotBox from OpenCode 1 to OpenCode 2

**Decision:** Install OpenCode 2 only, floating to the latest 2.x at build time
with a 2.0.0 floor. Gate the build on a smoke that loads the wired plugins into
the real binary. Disable OpenCode's hosted fallback model unless the user opts
in, reset V2's service config at every start, and allow only `models.opencode.ai`
for the catalogue.

**Date:** 2026-11-06 · **Issue:** [#60](https://github.com/trevor-vaughan/claude-riotbox/issues/60) · **Branch:** `60-opencode-v2` · **Commits:** `b3d5d4d`..`02594a2`

> **Frozen record.** Written after implementation. For the current
> implementation, read [THREAT_MODEL § opencode auth surface](../../../THREAT_MODEL.md#opencode-auth-surface),
> [the agent contract](../agent-contract.md), `container/opencode/smoke.sh` and
> the headers of the files under `agents/opencode/`. The Context Mode half of
> #60 is in [context-mode-2x-migration.md](context-mode-2x-migration.md).

**Verified against:** OpenCode v2.2.5, context-mode 2.1.4, git-ai v1.7.6,
headroom 0.43.0. `file:line` references are to upstream's tree at v2.2.5 and
are copied from the commit messages, comments and THREAT_MODEL text on this
branch; this record re-verified one of them (see decision 4).

## Decisions

| # | Decision | Reason | Commit |
|---|---|---|---|
| 1 | V2 only, no side-by-side install. A renamed `opencode2` binary was considered and dropped. | Both versions share the binary name and the config and data paths, so a second install would share state with the first. The floor is not a courtesy: V1 plugins do not load in V2. | `e5fb4bd` |
| 2 | The install floats to the latest 2.x, with a 2.0.0 floor. The Containerfile uses `https://opencode.ai/v2/install --no-modify-path`. | Matches the latest-at-build policy for Claude Code and Pi core. The V1 installer (`opencode.ai/install`) refuses to install 2.x, so it cannot be used. The build fails on any 1.x, and fails when it cannot read a bare `X.Y.Z` out of `opencode vX.Y.Z`, so the `sort -VC` floor check cannot pass vacuously. The installer's `opencode2` shim is removed because moving the binary would leave it dangling. | `e5fb4bd` |
| 3 | A build-time plugin smoke is the gate. `container/opencode/smoke.sh` loads the wired plugins into the real binary and fails the image build if any does not load. | The venom suites run a fake opencode, so nothing else proves a plugin loads. The driver uses the background service and polls for up to 30 s, because `plugin.list` answers from its current inventory before plugins finish loading and, under `api --standalone`, the private server serves only that first request, so the list is always empty. A plugin that fails to load is listed with state `failed`; an empty list fails as missing plugins. | `b3d5d4d`, `3cecb54`, `9d4cc97` |
| 4 | No integration was disabled. Context Mode, git-ai and headroom all load on 2.2.5. | The smoke passed for all three on the synthesized image (offline, `--network none`) and a throwing `zz-bad.js` fails it with exit 1, naming the file. The Context Mode shim re-exports the default alone because V2's loader requires a default export with an id and a setup or effect function (`packages/core/src/plugin/module.ts`, "Plugin must export a default definition with an id and an effect or setup function"); it reads no named exports. | `3cecb54` |
| 5 | The merged config adds `opencode` to `disabled_providers`. A user opts back in by naming the provider: a top-level `model` or `small_model` on `opencode/...`, a `provider` or `providers` entry keyed `opencode`, or `opencode` in `enabled_providers`. Then no disable is written. | With no provider credentials, V2 runs the prompt on the free models of its built-in `opencode` provider, the hosted free model, and sends the prompt and code context to `https://opencode.ai/inference/systemone/v1` (`packages/ai/src/providers/opencode.ts:8`). V2 turns the disable into a `provider.use` deny policy (`packages/core/src/config/normalize.ts:421-428`, `packages/core/src/config/plugin/policy.ts:63`), so an unconfigured session fails with "No model is available" instead of sending anything. A capture on v2.2.5 shows no traffic to opencode.ai. | `73716aa` |
| 6 | `~/.config/opencode/service.json` is removed at every container start and never synced from the host. The registration under `XDG_STATE_HOME` of the same name stays. | The V2 background service config has `env`, copied into the service process; `remote`, an internet tunnel; and `password`, reused across restarts (`packages/cli/src/server-process.ts:151`). `~/.config/opencode` persists across sessions, so a value written by one session's agent, or carried in from the host, would apply to every later session. Each start now gets a fresh password and the defaults. | `fe1622c` |
| 7 | `--pure` is gone. The wrapper no longer warns about it; the token passes through and V2 rejects it. | V2 has no `--pure` (`Unrecognized flag: --pure`, exit 1) and no flag that skips external plugins. To run without Context Mode, set `RIOTBOX_CONTEXT_MODE=0`. The `--auto` injection rules were re-checked against v2.2.5 and hold. | `e80469b`, `4186bbd` |
| 8 | The egress allowlist for opencode is `models.opencode.ai`; `models.dev` is dropped. | V2 fetches its model catalogue from `https://models.opencode.ai` (`packages/core/src/models-dev.ts:494`, overridable only by `OPENCODE_MODELS_URL`) with no fallback host, and has no code path that contacts `models.dev`. `opencode.ai` stays out of the allowlist, so under `RIOTBOX_EGRESS=1` the hosted models stay blocked for a user who opted in under decision 5 until they add it to their own `egress.conf`. | `054731d` |
| 9 | The first V2 launch in an existing session imports that session's OpenCode 1 session database. The import is one-way. | Rolling back means an older image with a fresh session. Context Mode 1.x stores are not imported; startup prints a notice naming them (see [context-mode-2x-migration.md](context-mode-2x-migration.md)). Stated in the README upgrade note. | `02594a2` |
| 10 | `external_directory` is left at V2's default, and `permission = "allow"` stays forced. | `external_directory` defaults to allow in V2, so the default grants nothing more than before, and `permission = "allow"` grants it anyway. The container is the boundary: the agent reaches only what is mounted. `--auto` and the config key are both load-bearing (config-side vs client-side), recorded in THREAT_MODEL. | `02594a2` |

## What was not verified

- Behaviour on 2.x releases after 2.2.5. The smoke is the control: it re-runs on
  `riotbox update` and fails the build when a wired plugin stops loading.
- The OpenCode 1 session import beyond the behaviour stated in the README; no
  rollback path exists by design.
