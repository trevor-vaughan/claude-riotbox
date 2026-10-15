# Invariants of `scripts/mount-projects.sh`

Seven things this script must keep doing. Each was a bug once, and each is cheap to
reintroduce by a refactor that looks like a simplification. Read this before
changing the file.

## Per-path ownership branch (introduced 2026-05-19)

`setup_projects` calls `_mount_path_is_unowned` once per resolved
project path. Each path is independently routed to one of:

| Ownership | Mode                 | Suffix                                  |
|-----------|----------------------|-----------------------------------------|
| owned     | default              | `:z`                                    |
| owned     | `RIOTBOX_READONLY=1` | `:ro,z`                                 |
| owned     | `RIOTBOX_OVERLAY=1`  | `:ro,z` lower + state-dir `:z` upper    |
| not owned | (any)                | `:O` (podman overlay, ephemeral writes) |

**Do not** reintroduce a function-level `mount_suffix` variable
that's computed once before the per-path loop. The branch must
remain per-dir so a mixed-ownership multi-project set works
correctly.

## Engine guard

The unowned branch emits `:O`, which is podman-specific. The engine
guard in `setup_projects` (immediately after `resolve_projects`)
checks `CONTAINER_CMD` and returns 1 with a clear error if any
resolved path is unowned and the runtime is not podman. The check
fires before any filesystem side effects (session dir, state dir, overlay tree)
so a failed launch leaves no state behind. Use `return 1`, not
`exit 1`, so test harnesses can invoke `setup_projects` in a
subshell and inspect the failure.

## Mount sources never nest in the session dir (introduced 2026-10-13)

The session dir is mounted read-write at `~/.claude`, so the container can
replace anything inside it with a symlink before the next launch, and podman
would mount whatever the link names. Every other mount source RiotBox creates
for a session — headroom, git-ai, each `overlay/<name>`, and every directory an
agent's `host_sync` copies — comes from `RIOTBOX_STATE_DIR`
(`${XDG_DATA_HOME}/riotbox-state/<key>/`), which is never mounted whole. Host
files bind-mounted in place (credentials, `auth.json`, `~/.claude/plugins/`) and
the Context Mode ledger are not session-created and stay where they are.

- Create a source with `ensure_real_dir` (`scripts/lib/session-state.sh`), never
  a bare `mkdir -p`: it replaces a link instead of following it. It checks only
  the last component; the state root and key dir are created by RiotBox alone.
- Take paths from `RIOTBOX_STATE_DIR` / `RIOTBOX_STATE_ROOT` as
  `resolve_projects` / `resolve_data_roots` set them; do not spell them again.
  (`scripts/tokscale-riotbox.sh` and `scripts/git-ai-riotbox.sh` do not source
  this file and keep their own `RIOTBOX_STATE_ROOT` default, which is their
  test seam.)
- A new state subdirectory that replaces something an older release kept in the
  session dir gets a `<legacy>:<new>` pair appended to `SESSION_STATE_MIGRATIONS`
  in `scripts/lib/session-state.sh`, in the same commit as the code that reads
  it. `migrate_session_state` runs each pair once per session and records its
  legacy name in `<state dir>/.migrated`; a recorded pair never runs again
  automatically, so a new pair's legacy path is imported only at each session's
  first launch or overlay command after the upgrade. The marker is appended one
  line per record: `<name>` when the pair ran, then also `failed:<name>` when it
  left data stranded (`migrate_legacy_state` returned 2: the move failed, or both
  copies exist). A pair is failed while its last line is `failed:<name>`; a
  later `<name>` makes it done. The plain line comes first so a reader that knows
  only plain names still never retries it. Each call prints a one-line notice
  per already-failed pair whose legacy path is a non-empty real dir, and appends
  `<name>` for one whose legacy path is gone, empty or not a real dir. Only
  `migrate_failed_state` (`riotbox session-migrate`, `libexec/migrate-session.sh`)
  retries failed pairs, under the same lock, with `--replace-empty` (an empty
  real new dir, which the stranding launch went on to create, is moved over)
  and only after `_refuse_if_session_running` finds no created, running or
  paused RiotBox container mounting the session or state dir
  (`running_session_mounts` in `scripts/lib/running-sessions.sh`, shared with
  overlay-accept/reject; fails closed). That check narrows the race with a
  launch but does not close it: a launch drops `.migrate.lock` after its
  migration pass, well before its container exists. Notices and hints name the projects from the host-only
  `<state dir>/projects` record (`recorded_projects`, now in
  `scripts/lib/session-state.sh` with `quote_words`); `member_set_hint` prints
  the whole-set command for one member of a multi-project set, for the overlay
  commands and session-migrate alike. The pass holds an exclusive flock on `<state dir>/.migrate.lock`
  (separate from the host_sync `.sync.lock`, so the two never nest), because
  concurrent launches and overlay commands would otherwise overwrite each
  other's records. `setup_projects` runs the migration before any `-v` flag is
  built and skips it under `RIOTBOX_DRY_RUN=1`.
- `resolve_projects` refuses a project that resolves to `/` (compared with
  `-ef`): its key would be empty and its session dir the data dir itself. A
  project that is an ancestor of the data dir (`$HOME`) is not refused; it
  mounts `riotbox/` and `riotbox-state/` read-write at `/workspace`. That is a
  documented limitation
  ([THREAT_MODEL § Session state directory](../../THREAT_MODEL.md#session-state-directory)),
  not something this layout prevents.
- `.projects` is the one file `setup_projects` writes into the session dir.
  Write it only by staging in `riotbox/.projects.XXXXXX` and `mv -T`, after
  removing a link or non-regular entry there, never with a redirect: a
  redirect follows a planted link. Read it only through `session_projects` and
  print it through `terminal_clean` (both in `scripts/lib/session-state.sh`).

`tests/session-state.venom.yml` ("with every feature on, no mount source except
the session dir itself lies inside the session dir") and the `host_sync` case in
`tests/agents.venom.yml` fail if a source moves back inside.

## `host_sync` runs under the per-project sync lock (introduced 2026-10-13)

Sessions of one project share the session dir and the state dir, and every
agent sync replaces its copies by remove + `mv -T` from a staging dir. Two
launches syncing at once collide on those renames, and the loser aborts with
`changed during sync`. `setup_projects` therefore opens
`${RIOTBOX_STATE_DIR}/.sync.lock` on a dynamically allocated fd, takes
`flock --exclusive` on it, runs every agent's `host_sync`, and closes the fd —
which releases the lock — on every exit from the loop, including a failed
`host_sync`. Keep the close on every return path; a leaked fd keeps holding the
lock, and every later launch of the project waits on it.

The lock file is opened without a link check because it sits at the state dir's
top level, which no container can reach (only subdirs are mounted). Do not move
it into a mounted subdir. `flock` is a host prerequisite for this reason, and
`riotbox doctor` reports it missing as `flock available` with exit code 24
(`scripts/preflight.sh`). `tests/session-state.venom.yml` ("concurrent
setup_projects runs of one project all succeed") is the regression test: 20
rounds of two parallel runs, which failed 16 of 40 runs without the lock.

## Symlink canonicalization invariant

`_mount_path_is_unowned` calls `[ -O "$p" ]`, which follows symlinks.
This is correct *only because* `resolve_projects` has already
canonicalized every entry in `PROJECT_DIRS` via `cd "$p" && pwd -P`.
If a future refactor of `resolve_projects` skips canonicalization,
the `-O` test could be applied to a symlink whose target is
foreign-owned and silently take the owned branch (re-introducing the
original bug). Preserve `pwd -P`.

## `chcon` invariant

`mount-projects.sh` must NEVER invoke `chcon` directly. `chcon` runs
inside podman at runtime when it processes the `:z` flag — that's
the only place it belongs. The venom suite (`tests/mount-modes.venom.yml`)
includes a chcon-stub assertion across every testcase that catches
any direct invocation. If you find yourself wanting to call `chcon`
from this script, the answer is almost certainly "emit a different
suffix instead."

## Triple-format `ovl` token

`--format=triple` emits one of three mode tokens: `rw`, `ro`, or
`ovl`. `ovl` corresponds to a `:O` suffix and is currently emitted
only for unowned paths. Internal tools that switch on the mode
token should add an `ovl)` branch alongside `rw)` and `ro)`.
