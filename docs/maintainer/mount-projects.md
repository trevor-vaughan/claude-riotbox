# Maintainer notes — `scripts/mount-projects.sh`

## Per-path ownership branch (introduced 2026-05-19)

`setup_projects` calls `_mount_path_is_unowned` once per resolved
project path. Each path is independently routed to one of:

| Ownership | Mode                 | Suffix                                  |
|-----------|----------------------|-----------------------------------------|
| owned     | default              | `:z`                                    |
| owned     | `RIOTBOX_READONLY=1` | `:ro,z`                                 |
| owned     | `RIOTBOX_OVERLAY=1`  | `:ro,z` lower + session-dir `:z` upper  |
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
fires before any filesystem side effects (session dir, overlay tree)
so a failed launch leaves no state behind. Use `return 1`, not
`exit 1`, so test harnesses can invoke `setup_projects` in a
subshell and inspect the failure.

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
