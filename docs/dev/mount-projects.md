# Invariants of `scripts/mount-projects.sh`

Eight things this script must keep doing. Each was a bug once, and each is cheap to
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
  session dir gets a pair appended to `entries` in `internal/migrate/migrate.go`
  (the bash's `SESSION_STATE_MIGRATIONS`), in the same commit as the code that
  reads it. `migrate_session_state`, an adapter for `riotbox-core
  migrate-state` (`SessionState`), runs each pair once per session and records its
  legacy name in `<state dir>/.migrated`; a recorded pair never runs again
  automatically, so a new pair's legacy path is imported only at each session's
  first launch or overlay command after the upgrade. The marker is appended one
  line per record: `<name>` when the pair ran, then also `failed:<name>` when it
  left data stranded (the move failed, or both copies exist). A pair is failed
  while its last line is `failed:<name>`; a later `<name>` makes it done. The plain line comes first so a reader that knows
  only plain names still never retries it. Each call prints a one-line notice
  per already-failed pair whose legacy path is a non-empty real dir, and appends
  `<name>` for one whose legacy path is gone, empty or not a real dir. Only
  `migrate_failed_state` (`riotbox session-migrate`, `libexec/migrate-session.sh`,
  run by `riotbox-core migrate-failed`, `FailedState`) retries failed pairs,
  under the same lock, and may move over an empty real new dir, which the
  stranding launch went on to create,
  and only after `engine.RefuseIfRunning` finds no created, running or
  paused RiotBox container mounting the session or state dir
  (`Scan` in `internal/engine`, shared with overlay-accept/reject and the
  session-key move; fails closed). That check narrows the race with a
  launch but does not close it: a launch drops `.migrate.lock` after its
  migration pass, well before its container exists. Notices and hints name the projects from the host-only
  `<state dir>/projects` record (`records.Recorded` in Go, `recorded_projects`
  in bash), quoted as `quote_words` does; `member_set_hint` prints
  the whole-set command for one member of a multi-project set, for the overlay
  commands and session-migrate alike. The pass holds an exclusive flock on `<state dir>/.migrate.lock`
  (separate from the host_sync `.sync.lock`, so the two never nest), because
  concurrent launches and overlay commands would otherwise overwrite each
  other's records. `setup_projects` runs the migration before any `-v` flag is
  built and skips it under `RIOTBOX_DRY_RUN=1`.
- `.migrated` also holds one record that is not a migration:
  `project-headroom-notice`. A single-project launch with `RIOTBOX_HEADROOM=1`
  writes it, under the same lock, once `notice_project_headroom` (`riotbox-core headroom-notice`) has looked
  for headroom memory an older release left in `<project>/.headroom`. The
  record is written whether or not a notice printed, so the check runs once
  per session. A launch with headroom off writes nothing, so the first
  headroom launch still checks. The migration passes skip the record, since
  they read only the names in `entries`. The notice is
  advisory: if the check or the record fails, the launch warns and goes on.
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

## Locks, in the order they may be taken

1. `${RIOTBOX_STATE_ROOT}/.migrate.lock`, the state root's. Go only:
   `riotbox-core migrate-key` holds it for the key move, and
   `riotbox-core migrate-all` for `riotbox overlays`' session migration,
   taking 2 for each session inside it.
2. `<state dir>/.migrate.lock`, the session's. Go holds it for the state
   migration (`migrate-state`, `migrate-failed`, `migrate-all`) and the
   headroom notice (`headroom-notice`). Bash holds it for the project record:
   `setup_projects` wraps `record_projects` in `_with_migrate_lock`
   (`scripts/lib/session-state.sh`), its only caller.
3. `<state dir>/.sync.lock`, bash: a launch's `host_sync`, taken only after 2
   is released, so the two never nest.
4. `<state dir>/.overlay-<name>.lock`, bash: one `overlay-accept` or
   `overlay-reject` at a time per overlay (`_overlay_locked` in
   `scripts/overlay.sh`). Taken after `resolve_overlay` has released 1 and 2,
   and never held while taking any other; a second command refuses at once
   rather than waiting. Without it, one command could restore or delete the
   other's live `<name>.rejecting.*` dir or accept snapshot.

Go takes the `.migrate.lock` files with `lock.Acquire` (`internal/lock`), an
exclusive `flock(2)` lock, the kind `flock(1)` takes on the descriptor
`_with_migrate_lock` opens, so bash and Go holders of one file exclude each
other. Both try without blocking first and print the same wait message before
blocking. Go's descriptor is close-on-exec, so a child process such as the `mv`
it runs cannot keep the lock after `riotbox-core` exits.

Inside a container, the headroom helpers take their own start lock in
`/tmp/riotbox-headroom-<uid>/proxy.lock`, which is container-local and
meets none of these.

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

## One injective session key per project set (introduced 2026-10-14)

`session_key` is the only derivation of a session's key; `resolve_projects`
builds `RIOTBOX_SESSION_DIR` and `RIOTBOX_STATE_DIR` from it, and
`libexec/launch.sh` labels containers `riotbox.session=<basename of the session
dir>`. The key is a readable prefix plus `-` and a set hash: the first
16 hex of the SHA-256 of the real paths, sorted bytewise with duplicates dropped,
each NUL-terminated. The prefix is the path with `/` mapped to `-` for one
project and `<first_seg>-<n_more>more` for a set
(`compute_multi_project_identity`, which a set's container name also uses), and
is trimmed so the key fits NAME_MAX (255 bytes). The prefix is for people only:
never decode a key back into paths, and never re-derive one in a test (call
`session_key`). The keys before this mapped `/` to `-` and nothing more, so
`/t/a-b/app` and `/t-a/b/app` shared a session; a set's 8-hex hash was taken
over those mangled paths and collided the same way.

The computation was bash (`session_set_hash`) until v0.7.0. It now lives in
`riotbox-core`: `Key`, `Identity` and `SetHash` in `internal/sessionkey`.
`session_key` and `compute_multi_project_identity` are adapters that check the
binary matches `VERSION` and call its `session-key` and `set-identity` verbs,
and they fail rather than print an empty key when it does not. The contract,
and the one place the Go output differs from v0.7.0's, are in
[riotbox-core.md](riotbox-core.md).

Container names are not keys. `generate_container_name` gives each launch
`riotbox-<basename>-<rand8>` (one project) or
`riotbox-<first_seg>-<n_more>more-<hash>-<rand8>` (a set). The readable part
is trimmed so the name fits 64 characters, and `<rand8>` is 8 random hex
digits on every launch. It never asks the engine which names are taken. Two
concurrent launches could both find a name free and then clash on `--name`,
since the gap between naming and `run` includes the TTY prompts. So never
look a session's container up by name: use the `riotbox.session` label, or
the mounts, as `Scan` in `internal/engine` (riotbox-core)
does. That also catches v0.5.3's unlabelled `riotbox-<dir>` containers.

`legacy_session_key` reproduces those old keys byte for byte, in the user's
locale, and exists only for `migrate_session_key`. That move runs before
anything touches the session dirs in `setup_projects` (not under
`RIOTBOX_DRY_RUN`), in `libexec/launch.sh` before the overlay snapshot check, in
both overlay resolvers, and in `session-migrate`, and in `session-remove` and
`session-reset` by path. A new command that resolves a set to its session must
call it too. It moves the old pair only when the old record, or for a
record-less session the old `.projects`, names the launched set; it writes no
record (only a launch may let `overlay-accept` act); it moves the dir holding
the evidence last so an interrupted move can finish; and it refuses while a
running container mounts the old dirs. Backup stores
(`libexec/checkpoint.sh`) keep the unhashed mangling deliberately: each store
records its project in `remote.origin.url`, and a push into a store whose origin
differs is refused.

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
