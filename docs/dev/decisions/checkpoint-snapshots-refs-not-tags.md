# Should a pre-session checkpoint be a commit and a tag, or a ref?

**Decision:** A ref. Each session snapshots the project into
`refs/riotbox/checkpoints/<timestamp>` through a throwaway index and
`git commit-tree`. No branch commit, no automatic tag, no worktree or index
change.

**Date:** 2026-08-04 · **Branch:** `fix/checkpoint-ref-snapshots` · **Verified against:** git 2.52.0

> **Frozen record.** For how checkpoints behave today, read
> [Built-in protections and Recovery in the README](../../../README.md#built-in-protections)
> and [Checkpoint snapshots and the backup store in the threat model](../../../THREAT_MODEL.md#checkpoint-snapshots-and-the-backup-store).
> The design spec and plan behind this work lived under the gitignored
> `docs/superpowers/` tree and are not retained; this record is the only
> surviving statement of why.

## TL;DR

The old checkpoint ran `git add -A` on the user's real index, committed the
result to the user's current branch, and tagged it `riotbox-checkpoint/<ts>`.
It worked, and it charged the user for the privilege: a commit they did not
make on the branch they were working on, a tag that changed what
`git describe --tags` reported, a `git push --tags` that would publish the
agent's safety net to the team remote, and a hard failure on any host that
forces `commit.gpgsign` or installs a `pre-commit` hook.

Every one of those costs comes from *where the snapshot is stored*, not from
what it stores. Moving it to `refs/riotbox/checkpoints/*` — a namespace git's
porcelain does not walk — removes all of them and keeps the capture identical.
The cost we accepted in exchange: the snapshots are invisible to every git
command a user already knows, so RiotBox has to be their entire discovery
surface (`riotbox checkpoints`, `checkpoint-tag`, `checkpoint-prune`).

## What we found

Each of these was run, in this container, on git 2.52.0. Where a claim is a
reading rather than a run, it says so.

**An auto-created tag cannot be made `describe`-safe.** `git help -c` lists 974
configuration variables and not one of them configures `git describe`; grepping
that list for `describe` returns nothing. `git describe --exclude` exists, but
it is an argument the *caller* passes — a tool that creates a tag has no way to
tell the user's future `describe` invocations, or their build scripts, or their
CI, to ignore it. So "create a tag but keep it out of the way" is not a thing
git supports. That single fact is what killed the tag design: the safety net
cannot be made to not change the meaning of the user's own version strings.

**`git stash create` cannot capture untracked files.** Its synopsis is
`git stash create [<message>]` — no `-u`, and no error when you pass one:
`git stash create -u "probe"` produced a stash whose subject was
`On main: -u probe`, with two parents and a tree containing only the modified
tracked file. `--include-untracked` is swallowed the same way. Since a
checkpoint that silently drops the agent's most likely casualty — a new,
uncommitted file — is worse than no checkpoint, the stash machinery was out.

**`git commit-tree` ignores `commit.gpgsign`.** With `commit.gpgsign=true` and
an unusable `user.signingkey`, `git commit` failed with
`gpg: signing failed` / `fatal: failed to write commit object`, while
`git commit-tree` on the same repo returned a commit whose object carries no
`gpgsig` header. The same property covers hooks: `commit-tree` runs none, so a
`pre-commit` hook, a conflicted merge, and an in-progress rebase can neither
break a checkpoint nor be broken by one.

**`refs/riotbox/*` does not travel by accident.** `git clone --bare` of a repo
holding a snapshot produced a store with zero `refs/riotbox` refs; a default
`git fetch` and `git fetch --tags` brought none; `git push --all` followed by
`git push --tags` put `refs/heads/main` and `refs/tags/v9.9` on a remote and
nothing else. (`git fetch <repo> --all --tags`, which the README used to
recommend, is not even a valid command any more: *fatal: fetch --all does not
take a repository argument*.) This is the property that makes the namespace
safe, and it is also the property that makes an explicit refspec mandatory
everywhere RiotBox moves a snapshot — the backup push, and the recovery
instructions.

Note the limit of that invisibility: it is git's *porcelain* that ignores the
namespace, not its plumbing. `git rev-list --all` does include `refs/riotbox`,
so a whole-repo rewrite tool (`git filter-repo`, `git filter-branch --all`) can
rewrite the local snapshot refs. Read from the `--all` definition and confirmed
by `git rev-list --all` listing a snapshot commit; the rewrite tools themselves
were not run.

**`git clone --bare` hardlinks, and the isolation guarantee was false.** A
plain `git clone --bare` of a local repo left every loose object with a link
count of 2 — one name in the project, one in the "isolated" backup. Making the
object writable in the *project* and overwriting it in place gave
`git fsck` in the backup `error: inflate: data stream error` and
`object corrupt or missing`, without anything ever touching the backup
directory. The same test against a clone made with `--no-hardlinks
--dissociate` left link counts at 1 and the backup intact. RiotBox had been
promising a backup the agent could not reach while handing the agent
read-write access to the same inodes. `--dissociate` is the second half:
a local clone copies `objects/info/alternates` verbatim, so a project made
with `clone --shared`/`--reference` would have given the backup a pointer into
a store RiotBox does not own — and in a multi-project launch, one the agent
may be able to delete.

**Seeding the throwaway index by copying beats `read-tree`.** `git add -A`
against a temp index seeded with `cp .git/index` vs one seeded with
`read-tree HEAD`, on a 3000-file repo: 11 ms vs 96 ms when the design was
measured, 7 ms vs 72 ms re-measured here. The absolute numbers move with the
machine; the ~10x does not, and the reason is stable — a `read-tree`-seeded
index has no stat cache, so it re-hashes every file on every launch.

**An unignored artifact tree is what actually costs time.** A 4000-file
untracked directory added 836 ms to `git add -A` when unignored and 53 ms when
excluded at design time; re-measured here, 395 ms cold (≈90 ms with a warm
cache) versus 7 ms excluded. This is why the managed `.git/info/exclude` block
is written *before* the snapshot rather than as a courtesy: the runtime
artifacts it lists (`.headroom/`, `.codegraph/`, `venom*.log`) are exactly the
shape of tree that makes a checkpoint slow enough to be resented.

## What we decided

- **Snapshots go to `refs/riotbox/checkpoints/<timestamp>`**, built in a
  throwaway index seeded from the real one and sealed with `git commit-tree`.
  A clean tree needs no new object, so the ref points at `HEAD`; an unborn
  `HEAD` with content gets a parentless snapshot; an unborn `HEAD` with nothing
  in the directory is skipped with a message.
- **No tag is ever created automatically.** `riotbox checkpoint-tag <ts>`
  creates `riotbox-snapshot/<ts>` on request, lightweight (an annotated tag
  would need an identity and would be signed on a host forcing `tag.gpgsign` —
  the exact dependency this design exists to avoid), and it tells the user
  plainly that the tag is real and will show up in `git tag`, `git describe
  --tags` and `git push --tags`. `riotbox-checkpoint/*` is now read-only
  history: listed separately, deletable via `checkpoint-prune --legacy`, never
  created.
- **Pruning is explicit only.** No retention default, no automatic expiry. One
  selector is required (`--keep`, `--older-than`, `--legacy`), the selection is
  printed before the confirmation, and any ref the backup store has no copy of
  is marked as the only copy. `--older-than` is the one GNU-`date` dependency,
  and it fails closed: no cutoff, no deletions.
- **Backups are keyed on the mangled canonical project path**, not the
  basename, so `~/work/a/web` and `~/work/b/web` no longer share a store where
  each launch force-overwrote the other's branches. A pre-existing basename
  store is migrated only when its recorded `remote.origin.url` proves it
  belongs to this project.
- **Snapshot refs are pushed to the backup without `--force`.** Timestamps are
  unique per launch, so force could only ever let a tampered local ref
  overwrite a pristine backup copy. Heads and tags keep `+`, because rewriting
  is expected there.

## What we did not verify

- **Any git older than 2.52.0.** Every fact above was checked in this
  development container, and `libexec/checkpoint.sh` runs on the *host*. The
  properties relied on are old and stable (`commit-tree` has never signed;
  `refs/*` outside `heads`/`tags` has never been fetched by default), but they
  were not re-run against an older git. `git restore`, which the recovery
  documentation now leads with, needs git ≥ 2.23; nothing enforces that.
- **The practical size ceiling.** The measurements above are a 3000-file repo
  and a 4000-file artifact tree. Nothing was run against a repository large
  enough to make a per-launch `git add -A` painful, and there is no
  size-based bail-out — only the existing warning above 100 untracked files or
  50 MB.
- **The rewrite tools.** That `git filter-repo` and `git filter-branch --all`
  would rewrite local snapshot refs is inferred from `git rev-list --all`
  including them; neither tool was run (`git-filter-repo` is not installed in
  this container).
- **Secrets are still captured, and this design does not fix that.** The
  snapshot takes everything `git add -A` sees, so an untracked, un-ignored
  `.env`, token or private key is copied into the snapshot ref *and* pushed to
  the backup store, where it outlives deletion of the file. The managed exclude
  block covers runtime artifacts only and was never a secret filter. This
  repository's own history contains the matching lesson from the era when
  checkpoints committed to the user's branch: commit `1447f69` swept a 446 KB
  `wireplumber-0.5.10-1.el10.src.rpm` into permanent history. Moving the
  snapshot out of the branch means an accident like that no longer lands in
  history the user pushes — but it still lands in the snapshot and the backup,
  and `riotbox checkpoint-prune` only deletes the former.

## Correction — 2026-08-04, same branch

Two gaps recorded above were closed by the exclusion work on this same branch,
hours after the record was written. The record is left as written; this section
says what changed rather than rewriting history.

- **"Secrets are still captured, and this design does not fix that."** Partly
  fixed. `_MANAGED_BLOCK` gained a secret group — `.env`, `.env.*`, `*.pem`,
  `*.key`, `id_rsa*`, `id_ed25519*`, `.npmrc`, `.netrc`, `*.p12`, `*.pfx` — so
  the common cases are excluded even when the project forgot to gitignore them.
  The underlying statement is still true for anything the block cannot name: a
  credential in a file called `config.local.yaml` is still swept in. The block
  is a denylist, not a secret scanner, and should not be read as one.
- **"There is no size-based bail-out."** Fixed. Untracked files above
  `RIOTBOX_SNAPSHOT_MAX_MB` (default 10) are skipped, with a report naming each
  file and its size, stating that it is in neither the snapshot nor the backup.
  Tracked files are never skipped at any size — they are already in git, so
  they cost nothing extra and dropping them would lose data. The report is
  deliberately not suppressed by `RIOTBOX_CHECKPOINT_QUIET`, which silences the
  advisory bloat warning; this one announces data left unprotected.
- The same change added a bulk group (`node_modules/`, `.venv/`, `target/`,
  `vendor/`, and similar). Measured on an 87 MB, 1780-file `node_modules`: a
  full checkpoint went from 3589 ms to 98 ms and the backup store from 172 MB
  to 104 KB. Exclusion happens before hashing — a 200 MB untracked file costs
  3086 ms to add and 4 ms to exclude.
- Note these patterns only affect **untracked** files. A tracked
  `vendor/lib/dep.go` is still captured with its modifications, which is what
  makes an aggressive list safe for projects that deliberately commit those
  directories.
