# Where should the state RiotBox mounts into a session live?

**Decision:** Beside the session dir, never inside it. Every mount source
RiotBox creates for a session, other than the session dir itself, moves to
`${XDG_DATA_HOME}/riotbox-state/<key>/`, a directory that is never mounted
whole. Existing sessions migrate once per entry, recorded so a container cannot
trigger it again.

**Date:** 2026-10-13 · **Branch:** `16-pi`

> **Frozen design record.** For how the layout behaves today, read
> [README § Session state directory](../../../README.md#session-state-directory),
> [THREAT_MODEL § Session state directory](../../../THREAT_MODEL.md#session-state-directory)
> and [mount-projects.md](../mount-projects.md).

## The problem

The per-project session dir `${XDG_DATA_HOME}/riotbox/<key>/` is bind-mounted
read-write at `/home/llm/.claude`. Six other mount sources nested inside it:

| Source (in the session dir) | Container path |
|---|---|
| `headroom/` | `~/.headroom` |
| `git-ai/` | `~/.git-ai` |
| `overlay/<name>/` | `/mnt/overlay[/<name>]` |
| `.config-opencode/` | `~/.config/opencode` |
| `.local-share-opencode/` | `~/.local/share/opencode` |
| `.pi-agent/` | `~/.pi/agent` |

Anything in the container could replace one of them with a symlink — even a
relative one. The next launch's host-side code then followed it (`rm -rf`,
`tar -x`, `cp`, `mkdir -p`) and podman mounted the link's target read-write: an
arbitrary host directory. RiotBox supports concurrent sessions on one project,
so the swap can land between the host-side sync and podman resolving `-v`; no
guard inside the scripts can close that window.

Mapping the code turned up three related defects, fixed in the same change:

1. `session-remove --all` and `session-reset all` removed every `riotbox/*/`
   except `backups/`. On a rootless install that directory also holds the app
   tree, so they uninstalled RiotBox. The exact-key form had no marker check, and
   a key containing `../` resolved outside the data dir.
2. `agents/claude/sync-settings.sh` writes into the session dir with `cp`, which
   follows a planted link at its destination.
3. `json_write_atomic` took the mode of a symlink (`stat -c %a` reports the
   link's own 0777) and wrote the replacement 0777.

## Options considered

- **Guard every nested path before use.** Rejected: a check-then-use guard is
  exactly what the concurrent-session race defeats.
- **A sibling inside `riotbox/`** (for example `riotbox/<key>.state/`). Rejected:
  every `riotbox/*/` enumerator, `install.sh`'s app tree and `backups/` live
  there, and the first defect above is what sharing that directory costs.
- **Mount the state read-only.** Not possible: headroom, git-ai, the overlay
  upper dirs, opencode's data dir and Pi's sessions are written by the agents.
- **Beside `riotbox/`, never mounted whole** (chosen). The precedent is
  `riotbox-context-mode/`, the Context Mode ledger. The container sees only the
  subdirectories that are mounted, so it cannot replace a mount source.

## What shipped

```
${XDG_DATA_HOME}/riotbox/<key>/          # unchanged: mounted at ~/.claude; keeps .projects
${XDG_DATA_HOME}/riotbox-state/<key>/    # 0700 (its root too), never mounted whole
    opencode-config/  opencode-data/  pi-agent/  headroom/  git-ai/  overlay/<name>/
    .sync.lock     # host-only; serializes launches' host_sync
    .migrated      # host-only; one record per line: <name> (ran), failed:<name> (stranded)
    .migrate.lock  # host-only; serializes the migration pass
```

- `resolve_data_roots` (scripts/mount-projects.sh) is the one place both roots
  are derived; `resolve_projects` sets `RIOTBOX_STATE_DIR` beside
  `RIOTBOX_SESSION_DIR`.
- `scripts/lib/session-state.sh`: `ensure_real_dir` creates each source and
  replaces, never follows, a link or file found there; `migrate_session_state`
  is the one entry point for the one-time move (below), and
  `migrate_failed_state` the one for the user's retry of a failed one.
- `agent_<name>_host_sync <session_dir> <state_dir>`: opencode and Pi write only
  under the state dir; Claude keeps its tree in the session dir, which is the
  `~/.claude` mount root and so cannot itself be replaced.
- Session commands act only on directories carrying `.projects`, accept an
  exact key only as a single path component (not empty, `.` or `..`), and
  remove both directories. `resolve_projects` refuses a project that resolves
  to `/`, whose empty key would make the data dir itself the session dir.
- `json_write_atomic`, used by the in-container setup scripts, reads the mode
  with `stat -L`; a dangling link gets 0600.

The first plan for Claude's sync removed a link before each `cp`. Review showed
that a running session can re-plant the link between the remove and the copy,
so it shipped differently: every copy is built in a private
`riotbox/.claude-sync.*` dir (never mounted, same filesystem as the session
dir) and renamed into place with `mv -T`, which never follows a link at the
destination and fails, aborting the sync, when something is re-planted where a
directory goes.

opencode and Pi got the same treatment for the same reason: each extracts into
a `.sync.*` dir in the state dir and renames it over `opencode-config/` or each
allowlisted `pi-agent/` entry. Two launches of one project syncing at once then
collided on the renames and aborted as if tampered with, so `setup_projects`
holds an exclusive `flock` on `riotbox-state/<key>/.sync.lock` across the
`host_sync` loop. `flock` (util-linux) became a host prerequisite and a
dependency of the rpm and deb packages, and `riotbox doctor` checks for it
(exit code 24).

`.projects`, the one file `setup_projects` itself writes into the session dir,
had the same defect and predates this layout: a planted `.projects -> ~/.bashrc`
had the next launch overwrite that host file. It is now staged in
`riotbox/.projects.XXXXXX` and renamed into place after a link or non-regular
entry is removed. Its readers use `session_projects` (one nofollow,
non-blocking open, at most 64 KiB) and print it through
`scripts/lib/terminal-clean.jq`, the sanitiser now shared with the git-ai
report.

### Migration

`migrate_session_state` runs each entry of `SESSION_STATE_MIGRATIONS`
(`.config-opencode` → `opencode-config`, `.local-share-opencode` →
`opencode-data`, `.pi-agent` → `pi-agent`, `headroom`, `git-ai`, `overlay`) that
`<state>/.migrated` does not list yet, and records each one after it succeeds.
`setup_projects` calls it before any `-v` flag is built, and only outside
`RIOTBOX_DRY_RUN`; `scripts/overlay.sh` calls it too, so `riotbox overlays` sees
pending data before that project's next launch. The pass holds a `flock` on
`<state>/.migrate.lock`. For each entry it runs:

| Legacy entry | Action |
|---|---|
| absent | nothing |
| a symlink, or not a directory | removed without being followed; warning |
| a directory, new absent | `mv -T`; one notice |
| a directory, new present | both left untouched; warning naming both; never merged; recorded failed |
| the move fails | warning naming `riotbox session-migrate` and the manual `mv`; legacy left in place, so the data is recoverable; recorded failed |
| the moved entry is no longer a directory | removed from the state dir; warning |

Every row but a failed removal is recorded, so its warning prints once and no
launch or overlay command runs it again. The last row exists because `rename(2)` moves the entry itself: a
legacy dir swapped for a link between the check and the move lands as a link,
and a launch would mount its target. Removing an entry that must go and cannot
fails the launch, leaves the entry unrecorded, and the next run retries it.

After moving `overlay/`, every non-directory entry directly under it is removed:
each `overlay/<name>` is a mount source of its own, and the legacy tree was
container-authored.

The record was added after review. The first version migrated on every launch,
so a running container could plant a legacy entry — `~/.claude/overlay/<name>/upper/…`
from a `RIOTBOX_READONLY=1` session — and have the next launch import it as
trusted pending overlay data. A single "migrated" flag would have stranded the
data of any pair a later release adds, so the marker lists each pair. What is
left is one import window per pair: at a session's first launch or overlay
command after the release that adds it.

Failed pairs were later split from done ones (follow-up #10). Recording a failed
move as done stranded the legacy data with a warning printed once and easily
missed. A stranded pair (failed move, or both copies existing — in both the
user must act) is now recorded as `<name>` then `failed:<name>`; the plain line
keeps the old reader's never-retry behaviour. Launches and overlay commands
print a one-line notice per failed pair while its legacy dir is non-empty, and
quietly record it done once the dir is gone or empty: an empty dir holds
nothing to recover (podman leaves empty mountpoints there), and closing the
record then shrinks what a later retry could import. Only `riotbox
session-migrate`, run by the user, retries failed pairs: an automatic retry
would let a container hold the import window open by making the move fail. The
stranding launch goes on to create the new dir, so the retry may move over it
while it is an empty real dir (`rename(2)` does that atomically and fails if it
filled meanwhile); a first launch keeps treating it as a second copy. The retry
refuses, failing closed, while a created, running or paused RiotBox container
mounts the session, whose writes would otherwise land in a dir RiotBox no longer
uses. That narrows the race with a launch rather than closing it (a launch
past its migration pass, with no container yet, is not seen); closing it would
mean holding `.migrate.lock` across the launch, which was not worth
restructuring launch locking for a user-run recovery command.

`riotbox tokscale` and `riotbox git-ai` read only the state root, so a project
set's old opencode, Pi and git-ai data is invisible to them until its next
launch or overlay command (`riotbox overlays`, `overlay-diff`, `overlay-accept`
and `overlay-reject` run the whole migration, not only `overlay`).

### Rollback

Each entry moves back by hand; an older RiotBox reading the legacy paths then
sees its data again, and running this release again migrates it forward. The
commands, for every session at once, are in
[README § Going back to an older release](../../../README.md#going-back-to-an-older-release).

## Hardening found alongside

Reviewing every host-side reader of the moved state turned up readers that
trusted container-written content. Each was fixed on the same branch:

- **`riotbox git-ai`** accepts a `.riotbox-version` stamp only as a regular
  file holding a plain version (it named a cache path and a download URL, so a
  traversal stamp could run a planted binary on the host), skips a store that
  contains a symlink, re-scans its private copy after copying and fails closed,
  gives git-ai an empty `config.json`, and passes the text report through the
  shared terminal sanitiser.
- **`riotbox tokscale`** scans the state root and passes a scan root only when
  its last component is a real directory, not a symlink.
- **`riotbox overlay-accept`/`overlay-reject`** refuse while a running
  container labelled `riotbox.session` has a read-write mount overlapping this
  overlay, or when the engine cannot say. `overlay-accept` applies a private
  snapshot, never follows a link in the overlay or the project, and validates
  every entry before the review and again after the confirmation.

## What was verified, and what was not

Verified by running, at commit `3931e6b`:
`tests/session-state.venom.yml` (each migration branch; the migration record,
including a pair added later and concurrent first launches; relative, absolute
and dangling links at every legacy and new path and at `.projects`; the
conflict branch never merges; concurrent `setup_projects` runs of one project
all succeed), `tests/session-commands.venom.yml` (against a real `./install.sh`
tree, the app tree survives `session-remove --all` and `session-reset all`;
planted `.projects` links and control characters), `tests/agents.venom.yml`
(no agent's `host_sync` mounts from inside the session dir) and
`tests/sync-claude-settings.venom.yml` (links re-planted at Claude's targets
just before the rename). The updated mount, overlay, git-ai and tokscale suites
were run by the commits that changed them, not again for this record. The full
suite was re-run at `8c406c5` against the pre-change baseline (24 known
failures, recorded locally before this hardening began): exactly those 24
failed, and none new.

Not verified: a real podman launch under SELinux enforcing (`chcon` of the state
dir is exercised only through a stub); an upgrade of a real session directory
created by an older release while that release's container is still running; a
real migration across filesystems (`riotbox/` and `riotbox-state/` on different
disks), where `mv -T` is a non-atomic copy-then-delete. The consequences of that
case are in [THREAT_MODEL § Session state
directory](../../../THREAT_MODEL.md#session-state-directory).

## Known limitation

A project that is an ancestor of the data dir — `$HOME`, say — still mounts
`riotbox/` and `riotbox-state/` read-write. This layout does not change that,
and RiotBox does not refuse such a project (only `/`). It is documented
([THREAT_MODEL § Session state
directory](../../../THREAT_MODEL.md#session-state-directory)), not fixed; the fix
needs its own decision.

## Out of scope

- Mountpoint files podman creates inside the session dir for nested credential
  binds: podman resolves mount destinations inside the container, so a link
  there does not redirect a host path.
- Packaged installs (`/opt/riotbox`): their app tree is not under the data dir,
  so the session-command defect never applied.
- The contents of each mounted subdirectory stay container-controlled; host code
  reading them (`riotbox overlay-*`, `riotbox git-ai`, `riotbox tokscale`) has to
  treat them as untrusted, as the section above describes.
