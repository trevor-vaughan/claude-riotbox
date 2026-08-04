# Should the agent run in a git worktree instead of the user's checkout?

**Decision:** No. The agent keeps working in the user's own checkout, and the
checkpoint/backup mechanism stays the thing that protects it. A worktree hides
the work the user most wants help with, and it does not isolate the repository
it would have to isolate to replace anything.

**Date:** 2026-08-04 · **Branch:** `fix/checkpoint-ref-snapshots` · **Verified against:** git 2.52.0

> **Frozen record.** For how the protections actually work today, read
> [Built-in protections in the README](../../../README.md#built-in-protections)
> and [the threat model](../../../THREAT_MODEL.md).

## TL;DR

"Give the agent its own `git worktree`" is the obvious next idea after
[checkpoint snapshots](checkpoint-snapshots-refs-not-tags.md), and it sounds
like it should subsume them: the agent gets a directory of its own, so it
cannot trample the user's files. Two runs killed it.

A worktree is a second **working tree**, not a second **repository**. It is
created from a commit, so it does not contain the user's uncommitted work — the
in-progress state that is the whole reason someone asks an agent for help. And
it shares the object store, the ref store and the config with the main repo, so
an agent locked inside one can still delete the user's branches and garbage
collect the checkpoint snapshots out of existence. It moves the files out of
reach and leaves the repository wide open, which is the wrong half.

It is therefore **complementary, not a substitute**. It remains genuinely
attractive for one specific problem — see [What it would
improve](#what-it-would-improve) — and that door is left open.

## What we found

Both of these were run, in this container, on git 2.52.0.

**A worktree does not contain the user's uncommitted work.** In a repo with a
committed `f.txt`, an uncommitted edit to it, and an untracked `wip.txt`:

```
$ git status --porcelain
 M f.txt
?? wip.txt
$ git worktree add ../agent-wt -b agent
$ cat ../agent-wt/f.txt
committed                     # the edit is not there
$ ls ../agent-wt
f.txt                         # wip.txt is not there
$ git -C ../agent-wt status --porcelain
                              # clean
```

The worktree is checked out from a commit, so it holds committed state and
nothing else. An agent placed in one is looking at the last commit, not at what
the user is actually working on. Closing that gap means committing or stashing
the user's work on their behalf before every session — exactly the kind of "a
commit they did not make" cost that the checkpoint design was rewritten to
avoid.

**The object and ref stores are shared, so the isolation stops at the files.**

```
$ git -C ../agent-wt rev-parse --git-common-dir
/tmp/wt/main-repo/.git                      # the MAIN repo's git dir
$ git -C ../agent-wt update-ref -d refs/heads/main
$ git rev-parse --verify refs/heads/main    # run from the MAIN checkout
fatal: Needed a single revision
```

`main` was destroyed in the user's own repository by a command run inside the
"isolated" worktree. The same shared store makes the checkpoint refs reachable
too — an agent confined to a worktree deleted a `refs/riotbox/checkpoints/*`
snapshot and collected the object away:

```
$ git -C ../agent-wt update-ref -d refs/riotbox/checkpoints/19700101-000000
$ git -C ../agent-wt reflog expire --expire=now --all && git -C ../agent-wt gc --prune=now
$ git cat-file -t <snapshot-sha>             # run from the MAIN checkout
fatal: git cat-file: could not get object info
```

Rewriting refs, force-pushing and pruning the shared object store are precisely
the destructive acts RiotBox exists to survive, and a worktree stops none of
them. The local snapshot ref is *already* assumed reachable by the agent — that
is why it is pushed to an off-mount bare backup — and a worktree would not
change that assumption in either direction.

## What it would improve

Recording this so a future reader knows the idea was weighed, not waved away.

`container/session-branch.sh` exists **only** because the agent and the user
share one working tree. It creates a `riotbox/<id>` branch at setup, and at
teardown it must check the base branch back out before it can fast-forward the
session branch into it — the two cannot both be checked out in one tree. When
uncommitted changes block that checkout it takes a sticky failure path
(`container/session-branch.sh:121-128`): the session branch is left checked
out, the merge is skipped, and every later session then takes the "already on a
session branch" path and silently stops branching or merging until the user
intervenes by hand.

If the agent had its own working tree, the session branch would never need to
be checked out in the user's tree at all, and that entire failure mode — plus
most of `session-branch.sh` — would disappear. That is a real, currently unpaid
cost of the shared-tree model. It is an open, unexplored option, not a decision
reversed here.

## What we decided

- **The agent runs in the user's checkout.** Uncommitted and untracked work is
  what it is usually asked to help with, and a worktree cannot show it that
  work without RiotBox first committing or stashing on the user's behalf.
- **Worktrees are not treated as a security boundary,** and nothing in the
  threat model may be relaxed on the strength of one. `--git-common-dir` points
  at the main repo; the ref and object stores are one store.
- **The checkpoint snapshot plus the off-mount bare backup stay the protection.**
  They defend against exactly the class of act a worktree leaves available.

## What we did not verify

- **A worktree plus a separate clone.** Real repository isolation — clone the
  project into a scratch directory, let the agent work there, merge back — was
  not investigated at all, and it is the variant that would actually address
  the shared-store finding above. It has a specific unknown against RiotBox's
  bind-mount model: a worktree's `.git` is a *file*, not a directory
  (`gitdir: /tmp/wt/main-repo/.git/worktrees/agent-wt`, confirmed here),
  pointing at a path outside the worktree — so a mount of the worktree alone
  hands the container a dangling pointer. Whether a clone-based layout mounts
  cleanly, and what it costs on a large repository, is unknown.
- **Merging the agent's work back.** No fast-forward, rebase or conflict flow
  was designed or run for a worktree-based session. The claim above is only
  that a worktree does not *start* with the user's uncommitted work, not that
  returning work from one is hard.
- **`git worktree` on the host's git version.** As with the checkpoint record,
  everything here is git 2.52.0 in this development container. `worktree` and
  `--git-common-dir` are old and stable, but were not re-run against an older
  git.
