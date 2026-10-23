# Should the session-state and overlay core stay in bash?

**Decision:** No. Port the host-side core to Go, one subsystem at a time. The
core covers session-state migration, overlay apply, lock handling, the overlay
ignore rules and running-container mount scans, and it ships as one static
binary (working name `riotbox-core`). The user-facing CLI (`bin/riotbox`,
`libexec/`), the agent manifests and the container scripts stay in bash and
call the binary. Every Go test is written in Ginkgo/Gomega and rendered by
ginkgoleaf.

**Date:** 2026-10-22 · **Branch:** `34-core-language` · **Issue:** #34

> **Decision only; no code has moved.** This record fixes the direction, the
> boundaries and the toolchain. The port itself is separate work, planned per
> subsystem. Until a subsystem is ported, the rule from #34 holds: do not add
> new persisted state to it in bash.

## The problem

Four host-side files carry the session lifecycle:

| File | Lines | Role |
|---|---|---|
| `scripts/overlay.sh` | 1,461 | `overlay list/diff/accept/reject`, the change walk, per-overlay locks |
| `scripts/mount-projects.sh` | 1,224 | session keys, mount resolution, config sync; sourced by every `libexec/` verb |
| `scripts/lib/session-state.sh` | 749 | state-dir layout, one-time migration, `replace_entry` |
| `scripts/lib/running-sessions.sh` | 181 | scans running containers' mounts |

Since the base release, `overlay.sh` grew from about 430 lines and
`mount-projects.sh` from about 600. Together they now implement:

- four `flock` locks with a fixed acquisition order
  ([mount-projects.md § Locks](../mount-projects.md#locks-in-the-order-they-may-be-taken));
- per-pair migration records;
- a trusted project record;
- evidence rules for the one-time key move;
- v0.5.3 key compatibility;
- mount scans across concurrent sessions.

That is a state machine. Its persisted data is plain files (paths one per
line, NUL-separated keys hashed with sha256) because bash has nothing better.

The defects that cost the most during that growth came from the language, not
the design:

| Bug class | Fixes |
|---|---|
| `set -e` silently off under `\|\|`, in `$(...)`, or masked by `local` | `223aebf`, `8117b60`, `78cf35c`, `14540b6`, `e774166` (a dropped `set -e` that let `overlay accept` destroy data) |
| SIGPIPE under `pipefail` aborting the overlay change walk | `7c6f886` |
| An EXIT trap's failed `kill` turning a pass into exit 1 | described at `tests/lib/headroom-fakes.sh:62-64`; no commit message names it |
| `$'\n'` behaving differently when run as `sh` | reported in #34; no commit or comment found |

`385629e` raised shellcheck to `-o all`, whose SC2310/SC2312 checks now flag
the first class. Lint narrows the first class. It does nothing for the other
three, and it cannot give the code typed records or structured data.

Doing nothing means every new feature that needs session state either gets
blocked by the #34 freeze or gets written into the layer the freeze exists to
protect. The pod lifecycle in #8 is the next such feature.

## Decision drivers

1. **Errors that cannot be lost silently.** A failure must propagate, or a check
   must refuse to build the code that drops it.
2. **Nothing new on the user's host.** Today the host needs podman,
   fuse-overlayfs, git, jq and flock (`scripts/preflight.sh`).
3. **Path handling that resists symlink swaps.** The state layout in
   [session-state-dir.md](session-state-dir.md) exists because a container can
   swap a mount source for a link between a host check and its use.
4. **The port must be checkable.** About 300 Venom cases already exercise this
   core through the CLI and its exit codes, whatever language is behind it.

## Options considered

- **Stay in bash, keep the freeze, define triggers to revisit.** Rejected. It
  costs nothing and fails drivers 1 and 3. The freeze also blocks #8, or pushes
  #8's state somewhere ad hoc.
- **Port to Python 3, standard library only.** Rejected after first being
  chosen on this branch. Exceptions propagate by default, which is the best
  answer to driver 1, and the packages could have stayed `noarch`. It fails
  driver 2:
  - python3 ≥ 3.9 becomes a host prerequisite. RHEL 8 does not install it by
    default.
  - 3.9 reached upstream end of life in October 2025, so the minimum version
    becomes a treadmill.
  - Symlink-safe access means hand-written `dir_fd` and `O_NOFOLLOW` calls at
    every open.
  - Typing would need mypy on top. Each call also pays interpreter start-up,
    and a launch makes several calls.

  Keeping the packages `noarch` saves maintainers work; users gain nothing
  from it.
- **Port to Go** (chosen).

## Decision outcome

Go, because it is the only option that meets all four drivers:

- **Driver 2:** a `CGO_ENABLED=0` binary needs nothing on the host.
- **Driver 3:** `os.Root` (Go 1.24+) refuses any path that resolves outside a
  directory tree, symlinks included. That turns the defence from layout plus
  care into an API guarantee.
- **Driver 1:** the compiler and `go vet` type-check everything. errcheck, in
  golangci-lint, refuses a dropped `err`, which is Go's equivalent of a lost
  `set -e`.
- **Driver 4:** the Venom suites check the port unchanged.

Go's costs fall on the build and release pipeline, once. Python's costs would
have fallen on every user's host, permanently.

### Boundaries the port must keep

- **Entry point.** Bash invokes `riotbox-core <verb>` as a subprocess. Exit
  codes and stdout formats are the contract that the Venom suites already
  assert, and they do not change during the port.
- **Agent sync scripts stay bash and keep working.** `agents/*/sync-settings.sh`
  source `session-state.sh` for `replace_entry` and similar helpers. When
  session-state is ported, those helpers become `riotbox-core` verbs the scripts
  call. The shape of the agent contract ([agent-contract.md](../agent-contract.md))
  does not change.
- **Overlay ignore rules have one implementation, used in both places.**
  `scripts/lib/overlay-ignore.sh` is sourced on the host by `overlay.sh` and in
  the container by `container/entrypoint.sh:78`, for `overlay-setup.sh`'s
  teardown stats. It moves into `riotbox-core`. The image build gains a Go
  build stage that copies the binary into the image, and the container scripts
  call it. Keeping a bash copy beside a Go copy is what this boundary forbids.
  So is moving the name lists to a shared data file and writing the matcher
  twice.
- **Only the core moves.** Bash remains the right tool for chaining podman, git
  and flock calls, which is most of `bin/riotbox`, `libexec/` and the container
  scripts. Porting everything is not a goal.

### Toolchain

| Concern | Choice | Version at decision | Licence | Notes |
|---|---|---|---|---|
| Language | Go | 1.26 (go1.26.7 in the dev image) | BSD-3-Clause | ≥ 1.24 for `os.Root` and `go.mod` `tool` directives |
| Test framework | Ginkgo v2 + Gomega | v2.33.1, v1.44.0 | MIT | **All** Go tests, no stdlib table tests |
| Test output | [ginkgoleaf](https://github.com/trevor-vaughan/ginkgoleaf) | v0.1.1 | MIT | `tree` for `task test`, `text` for `task test MODE=llm` |
| Lint | golangci-lint v2 | v2.15.0 | GPL-3.0 | Run, never linked or shipped, so no effect on RiotBox's Apache-2.0 licence. Enable `errcheck` and `ginkgolinter`. |

Dev tools are pinned through the `go.mod` `tool` block and run with
`go tool <name>`, as ginkgoleaf itself does. This means no global installs and
no `$GOBIN`. Ginkgo, Gomega and ginkgoleaf are test-only imports and are not
compiled into `riotbox-core`.

**Venom stays the integration layer.** "All tests in Ginkgo" covers Go tests.
The Venom suites are the oracle the port is checked against. Rewriting them
during the port would leave nothing independent to check it with.

### Distribution

- `nfpm.yaml` moves from `arch: all` to one package per architecture: amd64 and
  arm64, cross-compiled from one runner. Release CI already installs Go for
  nfpm.
- The rootless `./install.sh` from a checkout requires the user to choose how
  `riotbox-core` arrives: `--build` compiles it with the local Go toolchain, or
  `--binary` downloads the release binary and verifies it against `SHA256SUMS`.
  The two flags are mutually exclusive, and giving neither is an error. An
  installer that silently picked one would either fetch code from the network
  or demand a toolchain the user did not know they needed. Both surprise the
  user, so the installer never picks.
- Edits to Go source no longer take effect on the next launch. They need a
  rebuild, which becomes a Taskfile target.

### Order

One subsystem per branch. Each must pass the unchanged Venom suites before the
bash it replaces is deleted:

1. **Lock handling and migration**, plus the build, packaging and test
   scaffolding. #34 names these parts first, and #8 would extend them.
2. **Overlay ignore rules and overlay apply**, including the image build stage.
3. **Running-container mount scans**, then the rest of `mount-projects.sh`.

No subsystem ships with both a bash and a Go implementation live.

### Consequences

- **Positive:**
  - The bash bug classes above are eliminated, either by the compiler or by a
    lint that fails the build. They no longer depend on a reviewer noticing.
  - The symlink-race defence becomes an API property.
  - Session records can be typed structs instead of line-per-path files.
  - #8's pod state has somewhere to live other than the frozen layer.
  - Logic that today can only be reached end to end gets unit specs.
- **Negative:**
  - The rpm and deb become per-architecture.
  - The release pipeline gains a build step.
  - Installing from a checkout gets heavier.
  - Source edits need a rebuild before they are live.
  - The host side runs two languages with a process boundary between them.
  - During the long migration, contributors must know which half owns what.
  - ginkgoleaf is pre-1.0 ("APIs may still change") with a single maintainer.
    That maintainer is RiotBox's, so API churn is ours to absorb.

## What was verified, and what was not

**Read from the repository on this branch:**

- the file sizes;
- the callers of each script (all host-side, invoked from `bin/riotbox` or
  sourced by `libexec/*.sh`);
- `scripts/lib/` being copied into the image at `Containerfile:734`;
- `overlay-ignore.sh`'s container use;
- `nfpm.yaml`'s `arch: all` and its depends list;
- the preflight checks, the lock order, the Venom case counts and the fix
  commits in the table.

**Run:**

- `go doc os.Root` against go1.26.7 in the dev image confirmed the API exists.
- The licences, latest releases and last push dates of the four Go
  dependencies were read through the GitHub API on 2026-10-22.

**Not verified:**

- The cross-compiled binary has not been built or run on arm64.
- Neither `riotbox-core`'s start-up time nor Python's has been measured. The
  start-up argument against Python rests on general behaviour.
- `$'\n'`-under-`sh` is cited from #34; no record of it was found.
- The Python 3.9 end-of-life date and RHEL 8's default install are from
  upstream documentation, not from a host.

## Settled after the first draft

- **Checkout installs** take `--build` or `--binary`; see Distribution above.
- **The LLM test-output mode** uses ginkgoleaf's `text` format. `shell` was the
  alternative. Its tab-separated records are more compact, but they carry only
  each spec's state and location, not the `expected:`/`actual:` detail. `text`
  is never coloured, and it ends in a one-line verdict and a Failures block
  with that detail. This was read from ginkgoleaf's README examples at v0.1.1,
  not run.
