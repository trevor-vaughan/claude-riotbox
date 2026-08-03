# Context Mode Rollup — Accumulating Savings Beyond the 7-Day Window

**Status:** Implemented 2026-07-30. What shipped differs from this design in six places; see [What actually shipped](#what-actually-shipped). The design body below is kept as written, as the rationale the README links to.
**Depends on:** Context Mode (`RIOTBOX_CONTEXT_MODE=1`), shipped in `eabfa1c`.
**Related:** [Context Mode Evaluation](./context-mode-evaluation.md), `container/context-mode-summary.sh`.

## TL;DR

The exit report tells you what one session withheld from the model. It cannot tell you whether Context Mode is worth leaving on, because the counters it reads are pruned after seven days and there is nothing that accumulates across sessions.

This design records one small JSON file per session exit into a user-owned directory outside `RIOTBOX_DATA_DIR`, and adds `riotbox ctx-stats` to aggregate them. The capture reuses the atomic writer already in the image; the reader never starts a container.

## Why a scanner cannot work

The obvious design — walk the session directories and total up what is in the stores — cannot work, and the reason decides everything else.

`bytesAvoided` is `SUM(session_events.bytes_avoided)`, and `hooks/sessionstart.mjs` calls `cleanupOldSessions(7)`. That call is a hardcoded literal at every call site in the package, with no configuration knob, and it deletes `session_events`, `session_meta` and `session_resume` for any session older than a week. Anything reading the stores after the fact therefore sees at most seven days, no matter how often it runs.

The parked content is not affected by that sweep — `build/session/purge.js` is the only thing that deletes chunks, reachable solely through `ctx_purge`, as `hooks/sessionstart.mjs:444` states outright: *"ctx_purge is the only wipe mechanism."* So retrieval keeps working across the boundary while the measurements do not.

**Totals beyond seven days have to be captured at session exit.** They cannot be re-derived later.

## What this does not do

Stated up front because each was considered and dropped:

- **No control group.** This cannot answer "how much did Context Mode save compared to not running it." A session with the feature off produces no counters at all, and the comparable metric would be token usage — `tokscale`'s domain, not this one. The ledger measures what the feature withheld, not what you would have spent without it.
- **No rotation.** A record is roughly 200 bytes. A thousand runs is 200 KB. The schema is documented and the directory is yours to prune.
- **No syncing or backup.** The ledger lives in your XDG data directory. RiotBox writes to it and reads from it; it does not manage it.

## Storage shape: a file per run

Records are written one file per run rather than appended to a shared JSONL. Both were considered.

A single append-only file is nicer to read and `O_APPEND` makes short-line appends atomic — but only on local filesystems. That guarantee does not hold on NFS, and a data directory on a network mount is a normal setup. One file per run removes the assumption entirely: two concurrent sessions never write the same path, so there is no interleaving to reason about and no lock to take. Pruning becomes `rm`. The cost is a file per session and a reader that globs, which is why the reader streams with `reduce inputs` rather than slurping.

## Ledger location and mount

**Host path:** `${RIOTBOX_CONTEXT_LEDGER:-${XDG_DATA_HOME:-$HOME/.local/share}/riotbox-context-mode}/runs/`, created `0700` before `podman run`.

Deliberately outside `RIOTBOX_DATA_DIR`. Session directories are subject to `riotbox session-reset` and `session-remove`, and a history that a routine cleanup silently erases is not a history. `RIOTBOX_CONTEXT_LEDGER` is settable in `~/.config/riotbox/config`, which `libexec/launch.sh` already sources, so the knob costs nothing to add.

**Container path:** `/home/llm/.riotbox-ledger`, mounted `:z` from `scripts/mount-projects.sh` beside the existing headroom block.

**Mount conditions:** `RIOTBOX_CONTEXT_MODE=1` **and** `RIOTBOX_READONLY` unset.

That second condition is the audit boundary. `libexec/audit.sh` exports `RIOTBOX_READONLY=1`, and a workspace untrusted enough to be mounted read-only should not be handed the ledger. This matters because the mount is an ordinary read-write bind mount — "write-only drop" is a convention this design follows, not something podman enforces. A session can read the directory back, and the filenames and records name your other project sets. Untrusted sessions therefore do not get it, and their runs go unrecorded.

## Record schema

One file per run, named `<compact-UTC>-<SESSION_ID>.json` — for example `20260730T144803Z-a3f9c1d4e8b27f60.json`. `SESSION_ID` is already passed into the container (`libexec/launch.sh`) and is unique per container, so two concurrent sessions sharing a project set and a timestamp cannot collide.

```json
{
  "schema": 1,
  "started_at": "2026-07-30T14:02:11Z",
  "ended_at": "2026-07-30T14:48:03Z",
  "session_id": "a3f9c1d4e8b27f60",
  "project_set": "riotbox",
  "agent": "claude",
  "kept_out_bytes": 219184,
  "re_read_bytes": 21500,
  "hook_log_bytes": 8412,
  "retained_total_bytes": 221184,
  "baseline_unknown": false
}
```

`kept_out_bytes`, `re_read_bytes` and `hook_log_bytes` are this run's deltas — the same three numbers the exit report prints, from the same read of the store, so the ledger and the on-screen summary cannot disagree.

`retained_total_bytes` is the seven-day figure at exit. It is recorded because it is the only way to see the pruning boundary in hindsight: a retained total that drops between consecutive runs is the sweep, not a bug.

`baseline_unknown` marks a run whose start snapshot could not be read (a concurrent session holding the write lock, per `context_mode_summary_init`). Those runs are recorded and flagged rather than dropped, and the reader excludes them from totals — a run that happened is data even when its start snapshot is not.

`project_set` is the host's `session_key`, which the container does not currently know. This requires one plumbing change: `libexec/launch.sh` passes `-e RIOTBOX_SESSION_KEY`.

## Capture path

`context_mode_summary_init` gains one line: stamp `started_at` when the session is wired.

`context_mode_ledger_append` is new, in `container/context-mode-summary.sh`, called from `context_mode_summary_print` on the before/after JSON that function has already read. One read of the store feeds both the report and the record.

**One refactor is required.** The delta arithmetic — three subtractions, the clamps, and the `baseline_unknown` branch — currently lives inside `context_mode_render_stats`'s jq program. The ledger needs the same four numbers, and a second copy of clamping logic is the kind of duplication that drifts into two different answers for one store. It is extracted into `context_mode_compute_deltas`: stdin JSON in, `"kept re_read total hook_log"` or `"UNKNOWN total"` out. `render_stats` formats it; `ledger_append` records it. Pure computation on one side, pure formatting on the other.

The extraction is guarded by the seventeen existing summary tests, which pin every printed number and must stay green through it.

The write is `json_write_atomic "${dir}/${stamp}-${SESSION_ID}.json" "${json}"` from `scripts/lib/json-write.sh` — already in the image (`Containerfile:621`) and already sourced by the entrypoint ahead of the summary script. In-dir staging plus rename means a partially written record is never observable, and mode handling is inherited rather than reimplemented.

## Reader: `riotbox ctx-stats`

`scripts/ctx-stats.sh`, routed in `bin/riotbox` like every other verb, with a usage stanza and `--help`. Pure host-side `jq` over the drop directory; no container is started.

| Invocation | Output |
|---|---|
| `riotbox ctx-stats` | Aggregate: run count, date range, totals for kept-out / re-read / hook log, how many runs saved nothing, how many were excluded as `baseline_unknown` |
| `--by-project` | The same columns grouped by `project_set` |
| `--runs [N]` | Per-run table, newest first (default 20, `--runs all` for everything) |
| `--json` | The aggregation as JSON, for scripting |

The zero-saving run count is the number that answers the original question. "47 runs, 41 of them saved nothing" is the keep-or-kill signal, and it is only visible once runs are counted rather than summed.

Records are streamed with `reduce inputs` rather than slurped, so the file count does not bound memory. An empty or missing directory prints "no runs recorded yet" and the path it looked in, and exits 0 — an empty ledger is a state, not an error.

## Error handling

On the capture side, one rule: **a ledger failure never reaches the session's exit code.** `context_mode_ledger_append` is called `|| true` from the teardown, exactly as the report is, and returns 0 on every give-up path.

| Condition | Behaviour |
|---|---|
| Session not wired | Skip. An unwired run has nothing true to say about the feature. |
| Mount absent (old launcher, or `RIOTBOX_READONLY`) | Skip silently. The mount and the feature are emitted by the same condition, so absence means not configured. |
| Ledger directory unwritable, disk full, `json_write_atomic` fails | Skip, return 0, no warning — a teardown that complains about its own bookkeeping is worse than one that says nothing. |
| Deltas malformed | Skip. The formatter already rejects that shape; the recorder must not write what the report refuses to print. |
| `baseline_unknown` run | Record it, flagged. Excluded by the reader, not at the source. |

On the read side the tradeoff inverts, because a silent skip there corrupts a total. `ctx-stats` skips any file that is not a valid record **and reports the count of skipped files** in its output.

## Testing

Three venom suites, driving pure seams directly rather than through the image, matching how the existing summary coverage works.

**`tests/context-mode-ledger.venom.yml`**
- `compute_deltas` returns the numbers the formatter prints (the refactor's guard)
- a well-formed record for a normal run
- `baseline_unknown` recorded and flagged
- unique filenames for two runs sharing a project set and timestamp but differing in `SESSION_ID`
- skip-and-return-0 for: unwired session, absent directory, unwritable directory

**`tests/ctx-stats.venom.yml`**
- all four views over a fixture directory with known numbers
- empty directory
- a malformed file counted as skipped and excluded from totals
- `--json` shape stable

**`tests/mount-modes.venom.yml`** (extended)
- the mount flag appears with `RIOTBOX_CONTEXT_MODE=1`
- absent by default
- absent under `RIOTBOX_READONLY=1` — the audit boundary, and the assertion that matters most

The seventeen existing testcases in `tests/context-mode-summary.venom.yml` stay green throughout.

## Documentation

- README: the subcommand, the ledger location, the record schema, and why the ledger survives `session-reset`
- `bin/riotbox`: usage stanza and per-verb `--help` for `ctx-stats`
- This document: the rationale for the location, the storage shape, and the audit exclusion

## What actually shipped

Six changes, all made during review and all in the same direction: refusing to present a number the data does not support.

**The reader validates `.schema == 1`, not `has("schema")`.** The design's predicate checked that a version field exists without ever reading it. A ledger holding one `schema:1` record and one `schema:2` record with renamed fields reported "2 runs, kept out 1.0 MB, 1 run saved nothing" — the newer record's bytes silently absent from the total and the record itself misfiled as a run that saved nothing. Records from a newer schema now get their own disclosure line, separate from unreadable ones, because "upgrade riotbox" and "this file is corrupt" call for different actions.

**A record with `baseline_unknown: false` and null deltas is skipped, not counted.** The schema's contract is that `false` promises the three deltas are numbers. The `// 0` fallback was laundering a broken promise into a real zero-saving data point, inflating the count of runs that saved nothing with runs that were never measured at all.

**`--by-project` renders an all-unmeasured project as `unmeasured`, not `0 B`.** `0 B` is the literal reading — those bytes genuinely did not contribute — but it is the same fabricated figure the design forbade in `--runs`, derived from the same data.

**`--runs 0` is rejected at parse time with exit 2.** It otherwise sliced to an empty array and printed "no runs recorded yet" against a full ledger, conflating "nothing recorded" with "nothing shown" — the exact distinction the empty-state message exists to draw.

**Two different view selectors are an error, not last-wins.** `--runs 5 --by-project` silently discarded an argument the user typed, with no cue distinguishing "your 5 was ignored" from "5 applied and you only have that many projects".

**`project_set` is type- and emptiness-checked.** With `IFS=$'\t'`, tab is IFS whitespace, so an empty field collapses and shifts every column — a 1 MB run printed its byte figure in the run-count column and `0 B` in the byte column, while the aggregate view reported the same ledger correctly. Not reachable from the shipped writer, but the reader's posture is to distrust the file on disk, and it already type-checks `ended_at` for the same reason.

Three of these were found by mutation testing rather than by reading: the reviewers changed the code to be wrong and checked whether any test noticed. Summing `retained_total_bytes` instead of `kept_out_bytes`, dropping excluded runs from the run count, and removing `--by-project`'s exclusion of unmeasured runs all passed a green suite before the fixtures were made able to tell the difference.
