# riotbox-core

Maintainer-facing reference for the compiled half of RiotBox's host-side core:
what it does today, how bash calls it, how it is built, tested and released.

- **Why there is a Go binary at all** → [decisions/session-core-language.md](decisions/session-core-language.md)
- **Installing it as a user** → [README § Install](../../README.md#install)
- **Its place in the threat model** → [THREAT_MODEL § riotbox-core binary and release signing](../../THREAT_MODEL.md#riotbox-core-binary-and-release-signing)

## What it is

`riotbox-core` is a static Go binary (`CGO_ENABLED=0`) that the bash CLI runs as
a subprocess, one verb per call. The decision record plans to move the whole
session-state and overlay core into it, one subsystem at a time. So far only
session keys have moved: the key of a resolved project set, which picks the
session dir, the state dir and the container's `riotbox.session` label, and the
set identity a multi-project container name is built from. Everything else is
still bash.

## Layout

| Path | What it is |
|---|---|
| `cmd/riotbox-core/` | `main`: verb dispatch and exit codes |
| `internal/sessionkey/` | `Key`, `Identity`, `SetHash`; `testdata/` holds the golden vectors and their generator |
| `scripts/build-core.sh` | The one definition of a local build, shared by `task go:build` and `install.sh --build` |
| `scripts/lib/riotbox-core.sh` | Locates the binary and refuses a missing or mismatched one (`riotbox_core_require`, `riotbox_core_problem`) |
| `libexec/riotbox-core` | The built binary. Gitignored; produced by `task go:build`, `install.sh` or the packages |
| `.goreleaser.yaml` | The release build: per-arch binaries, archives, rpm/deb, checksums, SBOMs, signature |

## Verb contract

Every verb prints to stdout and nothing else on success. Directory arguments are
resolved absolute paths, the way `resolve_projects` leaves them; the binary does
not canonicalize them.

| Invocation | Stdout |
|---|---|
| `riotbox-core version` | The build version followed by a newline. `-ldflags -X main.version=` sets it from `VERSION`; an unstamped build prints `dev`. |
| `riotbox-core session-key <dir>...` | The session key: a readable prefix, `-`, and the 16-hex `SetHash`, at most 255 bytes. When no readable prefix survives, the key is the hash alone. |
| `riotbox-core set-identity <dir>...` | Three lines: the sanitized basename of the bytewise-first dir, the number of distinct dirs after it, and `SetHash`. |

Exit codes are the same for every verb:

| Code | Meaning |
|---|---|
| 0 | Output written |
| 1 | Writing stdout failed (for example `ENOSPC`); the error goes to stderr |
| 2 | Bad usage: no verb, an unknown verb, `version` with arguments, or a key verb with no dirs. The usage text goes to stderr |

The set is the arguments sorted bytewise with duplicates dropped, so argument
order and repeats never change a key. `SetHash` is the first 16 hex characters
of the SHA-256 of the set's paths, each followed by a NUL byte. The package doc
in `internal/sessionkey/sessionkey.go` has the prefix and truncation rules.

## Calling it from bash

- Call it only through an adapter that runs `riotbox_core_require` first and
  then `"${RIOTBOX_CORE}" <verb> "$@"`, as `session_key` and
  `compute_multi_project_identity` in `scripts/mount-projects.sh` do. The
  require check fails with a fix hint when the binary is missing, not
  executable, exits non-zero, or prints a version other than the app tree's
  `VERSION`. A binary from another release would compute keys by that
  release's rules. `install.sh --binary` from a checkout ahead of its release
  is how that pairing would happen, so it refuses a git checkout that is not
  exactly the commit tagged `v<VERSION>` with clean tracked files.
- Capture the output with `x="$(adapter …)" || return 1`. Never read it through
  process substitution (`< <(...)`): bash discards that command's exit code,
  so a refused or failed binary would look like empty output.
- The check runs on every call. The adapters run inside command substitutions,
  so a cache in a shell variable would never be reused.

`riotbox doctor` runs the same check (`preflight_check_riotbox_core` in
`scripts/preflight.sh`) and reports a failure as
`riotbox-core matches this install`, exit code 25.

## Why `legacy_session_key` is still bash

`legacy_session_key` reproduces the keys of releases before 0.6 so that
`migrate_session_key` can find and move their sessions. Its output depends on
the user's locale. For a set, it sanitizes the first basename with GNU sed's
`[^a-zA-Z0-9_.-]`, and in a UTF-8 locale that range matches letters such as
`é`. Measured with GNU sed in the dev container:

| Locale | `printf 'café' \| sed 's/[^a-zA-Z0-9_.-]/-/g; …'` |
|---|---|
| `en_US.UTF-8` | `café` |
| `C` | `caf` |

The same set therefore had a different key depending on who launched it.
Matching that would mean reproducing glibc's locale collation in Go. The
function is frozen and used only by the one-time key move, so it stays in bash.

## The one deliberate difference from v0.7.0

`Key` and `Identity` match v0.7.0's bash byte for byte with one exception: a
newline in the basename of a set's bytewise-first path. v0.7.0 sanitized that
basename with sed, which works line by line, so the newline survived and split
`compute_multi_project_identity`'s three-line output. Go maps the newline to `-`
like any other disallowed byte. Such a set gets a new key, and a v0.7.0 session
for it is not found under that key. A newline in a single project's path, or in
a later member of a set, still produces v0.7.0's key.

## Tasks

| Task | What it does |
|---|---|
| `task go:build` | Runs `scripts/build-core.sh` to write `libexec/riotbox-core`. Skipped when none of its inputs changed: non-test Go sources, `go.mod`, `go.sum`, `VERSION`, the build script |
| `task go:test` | Runs every Ginkgo suite and renders the report with ginkgoleaf: `tree` by default, `text` with `MODE=llm`. Output lands in `.test-output/go/` |
| `task go:lint` | `go tool golangci-lint run ./...` |
| `task fmt` | Alias for `task go:fmt`: `go tool golangci-lint fmt ./...`, applying the formatters `.golangci.yml` enables (gofmt, goimports) |
| `task test` | `go:build`, then `go:test`, then the Venom suites. The suites run against the host-built `libexec/riotbox-core`, because the test image has no Go. `MODE=llm` applies to both halves: ginkgoleaf `text` for Go, and `.taskfiles/scripts/venom-output.sh`'s errors-only summary for Venom |
| `task lint` | Includes `go:lint` alongside shellcheck and hadolint |
| `task release:package` | Local release dry run; see [Releasing](#releasing) |
| `task clean` | Removes everything the build produces, `libexec/riotbox-core` and `dist/` included, plus Task's `.task/` checksum cache so the next `go:build` rebuilds |

`scripts/build-core.sh` builds with `GOTOOLCHAIN=local`, `-trimpath` and
`-ldflags "-s -w -X main.version=<VERSION>"`, the same flags as the release.
`GOTOOLCHAIN=local` makes a Go older than `go.mod`'s `go` line (currently
1.26.4) fail with the required version in the message instead of downloading a
newer toolchain. Edits to Go sources take effect only after a rebuild.

Ginkgo, ginkgoleaf, golangci-lint and GoReleaser are pinned in the `tool` block
of `go.mod` and run with `go tool <name>`. None of them is compiled into
`riotbox-core`.

## Tests

Every Go test is a Ginkgo/Gomega spec; there are no standard-library table tests.

### Golden vectors

`internal/sessionkey/testdata/keys.tsv` holds 27 vectors: the exact output of
v0.7.0's `session_key` and `compute_multi_project_identity`. They cover single
projects, sets, duplicates, non-ASCII and non-UTF-8 bytes, newlines, and paths
on either side of every truncation boundary. Every byte field is hex-encoded so
any byte survives the file. The spec "against the
v0.7.0 bash golden vectors" checks `Key` and `Identity` against each row. A row
whose identity column is `-` has no identity contract (the newline case
above), and that case has its own spec under `Identity`.

Regenerate the vectors only from v0.7.0, the last release in which bash
computed keys itself. The generator sources the tree it is given; pointed at a
later tree, it would ask the current `riotbox-core` and compare Go with itself.
The command, from the header of `testdata/gen-keys.sh`:

```sh
tree="$(mktemp -d)"
git archive v0.7.0 scripts | tar -x -C "${tree}"
internal/sessionkey/testdata/gen-keys.sh "${tree}" > internal/sessionkey/testdata/keys.tsv
```

### Venom suites and helpers

`tests/riotbox-core.venom.yml` covers the bash side: the adapters
delegate to the binary; a missing, mismatched, non-executable or failing
binary is refused; `resolve_projects` stops instead of using an empty key;
preflight exits 25. `tests/install-rootless.venom.yml` and
`tests/setup.venom.yml` cover the install flags. They use these helpers in
`tests/lib/`:

| Helper | Purpose |
|---|---|
| `go-stub.sh` | A fake `go` that answers `go build … -o <out>` by copying the host-built binary, or fails the way a too-old Go does. The test image has no Go toolchain |
| `fake-release.sh` | Fake `curl` and `cosign` that serve a release from a local directory, with variants for a duplicated checksum line, a missing member and a symlink member, and a configurable `cosign version`. Real Sigstore verification happens only against a real release |
| `answer-prompts.sh` | Drives `setup.sh`'s interactive prompts, answering `[b/r]` and taking each y/n default. `ANSWER_PROMPTS_TIMEOUT` (default 60 seconds) bounds a run |
| `libexec-glob-coverage.sh` | Fails when a `libexec/` entry is not a top-level `*.sh` file |

`libexec-glob-coverage.sh` exists because `.goreleaser.yaml` packages
`./libexec/*.sh` rather than the directory. That keeps a developer's
`task go:build` output from being packaged beside the release build. The cost
is that a non-`.sh` helper added to `libexec/` would be silently left out of
every rpm and deb. The check does not read `.goreleaser.yaml`'s other entries:
it only confirms the `./libexec/*.sh` entry exists, then fails on every file
under `libexec/` (other than `libexec/riotbox-core`) that is not a top-level
`.sh`. Adding a non-`.sh` file to `libexec/` therefore takes two changes:
list it in the `nfpms` contents of `.goreleaser.yaml`, and change the check so
it accepts that file. Listing it alone leaves the check red.

## Releasing

The steps are the ones in [README § Releasing](../../README.md#releasing):
`task release:bump`, then push the tag. Pushing the tag runs
`.github/workflows/release.yml`, which has two jobs.

- `gate` has a read-only token. It installs `task` with the upstream
  install script, checks that the tag equals `VERSION`, and runs `task go:lint`
  and `task go:test MODE=llm`.
- `publish` needs `gate` and holds `contents`, `id-token` and
  `attestations` write. It runs exactly what the `SECURITY` comment above
  the job lists:
  - SHA-pinned actions: `checkout`, `setup-go` (which downloads the Go
    toolchain), `cosign-installer` and `attest-build-provenance`;
  - the syft release tarball (v1.55.0), fetched with `curl` and checked
    against a sha256 hard-coded in the workflow;
  - `.taskfiles/scripts/changelog-section.sh` from this repository, for the
    release notes;
  - `go tool goreleaser release`, version-pinned in `go.mod` and verified by
    `go.sum`, with `GORELEASER_CURRENT_TAG` set to the pushed tag so that
    another tag on the same commit cannot be released by mistake.

  `attest-build-provenance` then attests every archive, package, SBOM and
  `checksums.txt`.

The split exists because the OIDC token is available to every step of a job
that has `id-token: write`, and cosign keyless signing accepts that token. An
unpinned installer such as `curl … | sh` in the same job could sign anything
as this repository's release workflow. `gate` takes everything `publish` does
not need: the `task` install script, which is unpinned, and the lint and test
runs.

GoReleaser v2.17.0 is the pinned version. Later v2 releases need a newer Go
than `go.mod`'s floor of 1.26.4. The release produces:

| Asset | Notes |
|---|---|
| `riotbox-core_<ver>_linux_amd64.tar.gz`, `riotbox-core_<ver>_linux_arm64.tar.gz` | One member, `riotbox-core`, owned `root:root`. What `install.sh --binary` downloads |
| `riotbox-<ver>-1.x86_64.rpm`, `riotbox-<ver>-1.aarch64.rpm` | The app tree under `/opt/riotbox`, with `riotbox-core` in `/opt/riotbox/libexec` |
| `riotbox_<ver>_amd64.deb`, `riotbox_<ver>_arm64.deb` | As the rpms |
| `<artifact>.sbom.json` | SPDX SBOM per archive and package, generated by syft |
| `checksums.txt` | SHA-256 of every asset above |
| `checksums.txt.sigstore.json` | Sigstore bundle: cosign's keyless signature of `checksums.txt` |

Binaries and packages are reproducible: their file times come from the commit
(`mod_timestamp`, nfpm `mtime`) and the build embeds no wall-clock time.

### Dry run

`task release:package` runs `goreleaser check`, then a snapshot
release into `dist/` with signing and SBOMs skipped, and lists the result.
Snapshot versions end in `-snapshot` (`~snapshot` in package names). The task
sets `GORELEASER_FORCE_TOKEN=github` because GoReleaser refuses to start when
several forge tokens are present; a snapshot publishes nothing, so the token is
never used.

### Verifying a release by hand

Download the assets, then check the signature
the way `install.sh --binary` does, and the checksums:

```sh
ver=0.8.0   # the release to check
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity "https://github.com/trevor-vaughan/claude-riotbox/.github/workflows/release.yml@refs/tags/v${ver}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --check --ignore-missing checksums.txt
```

`install.sh --binary` requires cosign 2.6.2 or newer on the 2.x line, or 3.0.4
or newer on 3.x. Older releases either cannot read the bundle format or lack
the fix for GHSA-whqx-f9j3-ch6m. Use a cosign at least that new when verifying
by hand.

To check which workflow run built an artifact:

```sh
gh attestation verify riotbox-<ver>-1.x86_64.rpm --repo trevor-vaughan/claude-riotbox
```
