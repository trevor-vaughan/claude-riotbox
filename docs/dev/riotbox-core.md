# riotbox-core

Maintainer-facing reference for the compiled half of RiotBox's host-side core:
what it does today, how bash calls it, how it is built, tested and released.

- **Why there is a Go binary at all** → [decisions/session-core-language.md](decisions/session-core-language.md)
- **Installing it as a user** → [README § Install](../../README.md#install)
- **Its place in the threat model** → [THREAT_MODEL § riotbox-core binary and release signing](../../THREAT_MODEL.md#riotbox-core-binary-and-release-signing)

## What it is

`riotbox-core` is a static Go binary (`CGO_ENABLED=0`) that the bash CLI runs as
a subprocess, one verb per call. The decision record plans to move the whole
session-state and overlay core into it, one subsystem at a time. What has moved
so far:

- session keys (the key of a resolved project set, which picks the session
  dir, the state dir and the container's `riotbox.session` label) and the set
  identity a multi-project container name is built from;
- the readers of a session's two project lists, and the test for whether a
  directory is a session;
- the root and session `.migrate.lock`, and most of the work done under them
  (the one-time state migration, its `session-migrate` retry, the headroom
  notice, and the one-time move of a session to its hashed key);
- the scan of running containers' read-write mounts, which the overlay
  commands and the moves above use to refuse while a container can write what
  they would change.

The bash functions these replaced keep their names as adapters. Overlay apply,
`record_projects` (which bash runs under the session's `.migrate.lock`), the
other locks and the rest of `mount-projects.sh` are still bash.

The egress proxy (`RIOTBOX_EGRESS=1`) was written in Go from the start; only
its launch gate, start-up glue, teardown trap and command-line parsing are bash
([egress.md](egress.md)).

## Layout

| Path | What it is |
|---|---|
| `cmd/riotbox-core/` | `main`: verb dispatch and exit codes |
| `internal/sessionkey/` | `Key`, `Identity`, `SetHash`; `testdata/` holds the golden vectors and their generator |
| `internal/records/` | `Recorded` (the launch's record in the state dir), `SessionProjects` (the container-written `.projects`), `IsSession`, `SameSet` |
| `internal/display/` | `Quote` and `QuoteWords`, a port of bash's `printf %q` in the C locale; `CleanLines`, which runs `scripts/lib/terminal-clean.jq` through `jq`; `CleanName`, one name or path cleaned onto one line, with a placeholder when `jq` fails |
| `internal/lock/` | `Acquire`: the `flock(2)` lock on a `.migrate.lock`, with the wait message |
| `internal/realpath/` | `Canonical` and `Lexical`, ports of GNU `realpath -m` and `realpath -ms` |
| `internal/engine/` | `Scan` (every live container's read-write mounts), `Reaches`, `Overlaps`, `RefuseIfRunning`, `OverlayUsers` |
| `internal/egress/policy/`, `envoyconfig/`, `state/`, `pod/` | The egress proxy: the `egress.conf` grammar, groups and resolution, Envoy's JSON, one session's host directory, and the engine side. See [egress.md](egress.md#where-the-code-is) |
| `internal/migrate/` | `SessionState`, `FailedState`, `AllSessions`, `HeadroomNotice`, `SessionKey`, and the `.migrated` marker. The list of migration pairs, which the bash kept in `SESSION_STATE_MIGRATIONS`, is `entries` in `migrate.go` |
| `scripts/build-core.sh` | The one definition of a local build, shared by `task go:build` and `install.sh --build` |
| `scripts/lib/riotbox-core.sh` | Locates the binary and refuses a missing or mismatched one (`riotbox_core_require`, `riotbox_core_problem`) |
| `libexec/riotbox-core` | The built binary. Gitignored; produced by `task go:build`, `install.sh` or the packages |
| `.goreleaser.yaml` | The release build: per-arch binaries, archives, rpm/deb, checksums, SBOMs, signature |

## Verb contract

Directory arguments are resolved absolute paths, the way `resolve_projects`
leaves them. Only the running-container verbs canonicalize them (see below).
`riotbox-core` with no arguments prints the verb list on stderr and exits 2.

Every verb parses its arguments the same way (`parseArgs` in
`cmd/riotbox-core/main.go`): `riotbox-core <verb> [--option <value>]... [--] [arg]...`.

- Options come first. Each takes the next argument as its value verbatim,
  whatever it starts with. A verb's options must each be given exactly once,
  except `migrate-key`'s `--legacy-key`, which may repeat, and the options a
  verb marks optional (the `egress-*` verbs' `--session` and `--save-to`),
  which may be left out but not repeated.
- The positionals start at the first argument that does not start with `-`,
  or after `--`. An argument that starts with `-` before them is read as an
  option, so a positional that may start with `-` needs the `--`.
- The engine and the `terminal-clean.jq` directory are always options
  (`--engine`, `--lib-dir`). The directories a verb acts on stay positional.

| Verb | Options | Positionals |
|---|---|---|
| `version` | | none |
| `session-key`, `set-identity` | | `<dir>...` (at least one) |
| `recorded-projects` | | `<state-dir>` |
| `session-projects` | | `<session-dir>` |
| `is-session` | | `<session-dir> <state-dir>` |
| `same-project-set` | | `<list> <list>` |
| `overlay-scan` | `--lib-dir`, `--engine` | `<overlay-dir> <project-dir>` |
| `migrate-state` | `--lib-dir` | `<session-dir> <state-dir>` |
| `migrate-failed` | `--lib-dir`, `--engine` | `<session-dir> <state-dir>` |
| `migrate-all` | `--lib-dir` | `<data-dir> <state-root>` |
| `headroom-notice` | `--lib-dir` | `<project-dir> <state-dir>` |
| `migrate-key` | `--lib-dir`, `--engine`, `--data-dir`, `--state-root`, `--legacy-key` (repeatable) | `<dir>...` (at least one) |
| `egress-up` | `--engine`, `--state-root`, `--system-conf`, `--user-conf`, `--image`, `--session-key`, `--owner-pid`, `--os-dir` (optional), `--project` (repeatable, optional) | `<name>` |
| `egress-down` | `--engine`, `--state-root` | `<name>` |
| `egress-sweep`, `egress-list` | `--engine`, `--state-root` | none |
| `egress-allow`, `egress-deny` | `--engine`, `--state-root`, `--system-conf`, `--user-conf`, `--session` (optional), `--save-to` (optional) | `<entry>` or `@group` |
| `egress-strict` | `--engine`, `--state-root`, `--system-conf`, `--user-conf`, `--session` (optional), `--save-to` (optional) | `on`, `off` or `clear` |
| `egress-groups` | `--engine`, `--state-root`, `--system-conf`, `--user-conf`, `--os-dir` (optional) | none |
| `egress-reload` | `--engine`, `--state-root`, `--system-conf`, `--user-conf`, `--session` (optional) | none |

Three exit codes hold for every verb:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | The verb's own failure, listed in its row below, or writing stdout failed (for example `ENOSPC`). Either way the reason is already on stderr, except where a row says the verb fails quietly |
| 2 | Bad usage: no verb, an unknown verb, the wrong number of positionals, or an option missing, repeated, unknown, not taken by the verb, or without its value. The usage text goes to stderr |

### Key verbs

| Invocation | Stdout |
|---|---|
| `riotbox-core version` | The build version followed by a newline. `-ldflags -X main.version=` sets it from `VERSION`; an unstamped build prints `dev`. |
| `riotbox-core session-key <dir>...` | The session key: a readable prefix, `-`, and the 16-hex `SetHash`, at most 255 bytes. When no readable prefix survives, the key is the hash alone. |
| `riotbox-core set-identity <dir>...` | Three lines: the sanitized basename of the bytewise-first dir, the number of distinct dirs after it, and `SetHash`. |

These print nothing on stderr unless writing stdout fails. The set is the
arguments sorted bytewise with duplicates dropped, so argument order and
repeats never change a key. `SetHash` is the first 16 hex characters of the
SHA-256 of the set's paths, each followed by a NUL byte. The package doc in
`internal/sessionkey/sessionkey.go` has the prefix and truncation rules.

### Record verbs

A list verb exits 1 when there is no list, just as its bash function returned
1, so the bash callers keep testing `if projects="$(recorded_projects …)"`.

| Invocation | Behaviour |
|---|---|
| `riotbox-core recorded-projects <state-dir>` | Prints the non-empty lines of `<state-dir>/projects`, one per line. NULs are dropped and an unterminated last line is not printed, as with bash's `while read`. Exit 1 when the record is absent, a link, not a regular file or has no non-empty line, printing nothing; exit 1 with `riotbox-core: <error>` on stderr when it cannot be read. |
| `riotbox-core session-projects <session-dir>` | Prints the non-empty lines of the first 64 KiB of `<session-dir>/.projects`, read with one `O_NOFOLLOW\|O_NONBLOCK` open and one read; NULs dropped, an unterminated last line kept. Exit 1, quietly, when `.projects` is absent, a link, not a regular file, unreadable or has no non-empty line. The bash discarded `dd`'s message, so this one prints none either. |
| `riotbox-core is-session <session-dir> <state-dir>` | Prints nothing. Exit 0 when `<session-dir>` is a directory (a link to one counts) that holds a `.projects` regular file (a link to one counts), or whose `<state-dir>` holds the launch's record as a regular file that is not a link; exit 1 otherwise. |
| `riotbox-core same-project-set <list> <list>` | Prints nothing. Exit 0 when the two newline-separated path lists name the same set (sorted bytewise, repeats dropped), 1 when not. |

### Migration verbs

Each of these says what it did on stderr in the bash's words, byte for byte,
and prints nothing on stdout except where noted. `--lib-dir` names the
directory holding `terminal-clean.jq`; the bash adapters pass
`"${_RIOTBOX_CORE_ROOT}/scripts/lib"`. Names a container chose are cleaned
with that filter before they are printed (see
[Differences from the bash it replaced](#differences-from-the-bash-it-replaced)).
The rules behind each verb are in the doc comments of `internal/migrate`.

| Invocation | Behaviour |
|---|---|
| `riotbox-core migrate-state --lib-dir <dir> <session-dir> <state-dir>` | Runs each migration pair `<state-dir>/.migrated` does not list yet, under the session's `.migrate.lock`, and records it. A pair left stranded (the move failed, or both copies exist) is recorded as failed and warned about, and still exits 0. Exit 1 when a step failed hard: creating the state dir, the lock, the marker write, an entry that must go and cannot be removed, or a `<state-dir>/overlay` that cannot be listed for its cleanup. That pair stays unrecorded, so the next call retries it. Run by `migrate_session_state`. |
| `riotbox-core migrate-failed --lib-dir <dir> --engine <engine> <session-dir> <state-dir>` | `riotbox session-migrate`: retries only the pairs recorded as failed, under the same lock, after `engine.RefuseIfRunning` finds no container that can write the session. Prints `Nothing to migrate.` on stdout when no pair needed a retry. Exit 1 when a pair is still stranded, the running check refuses or cannot ask, or a step failed. Run by `migrate_failed_state`. |
| `riotbox-core migrate-all --lib-dir <dir> <data-dir> <state-root>` | `riotbox overlays`' migration pass: under the state root's `.migrate.lock`, `migrate-state` for every session under `<data-dir>` (`IsSession`, names not starting with a dot), in bytewise name order. Creates nothing when there is no session. Stops at the first session that fails and exits 1; `overlay_list` maps that to its exit code 2. |
| `riotbox-core headroom-notice --lib-dir <dir> <project-dir> <state-dir>` | Once per session, under the session's `.migrate.lock`, which it takes itself: for each of `<project-dir>/.headroom` and `<state-dir>/overlay/*/upper/.headroom` that is a real directory, says it may hold headroom memory an older RiotBox left, and how to delete it or copy it to `<state-dir>/headroom`. Moves and deletes nothing. Records `project-headroom-notice` in `.migrated` whether or not it printed. Exit 1 when the check could not be recorded. Run by `notice_project_headroom`. |
| `riotbox-core migrate-key --lib-dir <dir> --engine <engine> --data-dir <dir> --state-root <dir> [--legacy-key <key>]... [--] <dir>...` | Moves the set's session from each old key, in the order given, to `session-key` of the dirs, when the old session's evidence shows it belongs to this set. Runs under the state root's `.migrate.lock`, after `engine.RefuseIfRunning`. A `--legacy-key` that is empty, `.`, `..` or contains `/` is refused before any file is touched: a one-line reason, then the usage text, exit 2. Exit 1 when a move or the running check fails; the caller must stop. Run by `migrate_session_key`, which computes the old keys with `legacy_session_key`. |

### Running-container verbs

The verbs that take `--engine` ask the container engine which live (created,
running or paused) containers have a path mounted read-write (`internal/engine`):
`overlay-scan` below, and `migrate-failed` and `migrate-key`, which refuse
while a container can write what they would move (`engine.RefuseIfRunning`). The `--engine` value is
the executable to run, a name looked up on `PATH` or a path; the bash adapters
pass `${CONTAINER_CMD:-podman}`. `CONTAINER_CMD` must therefore name an
executable. A shell function or alias of that name is invisible to the binary,
and so is an engine command with arguments in it. `bin/riotbox` sets it to
`command -v podman`, or `docker` when there is no podman; the test engine stub
is the executable `tests/lib/engine-stub/podman` for the same reason (see
[Venom suites and helpers](#venom-suites-and-helpers)).

Unlike the key verbs, these compare each directory argument in both
`realpath -m` and `realpath -ms` form (`internal/realpath`), because a mount
source may sit behind a link. All fail closed: when the engine cannot list or
inspect the containers, its inspect output is malformed, or a path cannot be
resolved, they exit 1. The engine's own messages go to stderr; malformed output
is reported as `riotbox-core: malformed container inspect output`.

| Invocation | Behaviour |
|---|---|
| `riotbox-core overlay-scan --lib-dir <dir> --engine <engine> <overlay-dir> <project-dir>` | Records of two NUL-terminated fields: `holder` and the name of a container that can write the overlay, once per container; or `sharer` and `<name> <source>` for each other mount that overlaps the project either way, the source cleaned with `terminal-clean.jq` from `--lib-dir`. Exit 1, printing nothing on stdout, when the engine cannot answer. `_overlay_scan_sessions` in `scripts/overlay.sh` reads the records with `mapfile -d ''` from a process substitution and checks the exit code with `wait "$!"`; a command substitution would drop the NULs. |

A container "can write" a path when its mount source is the path or inside it.
For a container with the `riotbox.session` label, a source above the path
counts too. A name is the container's name, or the first 12 characters of its
ID when it has none.

### Egress verbs

The verbs behind `RIOTBOX_EGRESS=1` and `riotbox egress`. `libexec/egress-lib.sh`
and `libexec/egress.sh` call them; [egress.md](egress.md) has the topology,
the state dir and the invariants. `--state-root` is `RIOTBOX_EGRESS_ROOT`
(`${XDG_DATA_HOME}/riotbox-egress`), `<name>` the agent container's name, and
`--system-conf`/`--user-conf` the two `egress.conf` paths. Failures print
`riotbox-core: egress: <error>` on stderr and exit 1. `--save-to` must name
the `--system-conf` or `--user-conf` file (compared after `filepath.Clean`),
the only files checked before anything changes; any other path is a usage
error (exit 2). `libexec/egress.sh` always passes the user file.

| Invocation | Behaviour |
|---|---|
| `riotbox-core egress-up … [--os-dir <dir>] [--project <dir>]... <name>` | Reads on stdin, at most 1 MiB, the agent's `egress_hosts`, then optionally a NUL and the variables the agent would get from the host as NUL-terminated `NAME=VALUE` records (`inject.ParseInput`; a record without its NUL, one that is not `NAME=VALUE`, or a repeated name is exit 1 before anything is created, and the error names the record by number, a repeated one also by its name, never its value). Injects the provider keys among them (`internal/egress/inject`), prints `egress: these keys still enter the container: …` on stderr for the rest, and drops the injected names from its own environment. With a key to inject it needs a private tmpfs runtime dir (`$XDG_RUNTIME_DIR`, else `/run/user/<uid>`: a 0700 dir the user owns on tmpfs; `state.RuntimeBase`) and exits 1 before creating anything when there is none, saying why each was refused. Loads the OS plugins in `--os-dir` (`state.LoadOS`, [os-contract.md](os-contract.md)) and exits 1 before creating anything when one is invalid; none when the option is left out. Saves their groups as the session's `os.conf`. Records the `--project` dirs in `projects.json` for `egress-list`, writes the session's secrets (in `<runtime>/riotbox-egress/<name>/secrets`), CA certificate and injection record, starts the session's networks, pod and Envoy, waits for readiness, and prints the agent's engine flags, one per line (with injected keys also the CA mount, `NODE_EXTRA_CA_CERTS`, `RIOTBOX_EGRESS_CA` and `-e NAME=riotbox-egress-placeholder` per key). Removes what it created, secrets included, when a step fails. A `--owner-pid` that is not a positive integer is a usage error (exit 2). |
| `riotbox-core egress-down --engine <engine> --state-root <dir> <name>` | Removes the session's proxy, pod and networks, each only if present, then its secrets dir under every qualifying runtime dir (and any an earlier build left in the state dir), and prints `egress: N denied request(s), see <log>` when any were. Carries on past a failed step; exit 1 if any failed. |
| `riotbox-core egress-sweep --engine <engine> --state-root <dir>` | Removes the egress objects of sessions whose launch is gone, the secrets (on the runtime tmpfs and in the state dir) of any session no running one uses once it has been idle for an hour, and state dirs unused for 7 days. It cleans under every qualifying runtime dir (`$XDG_RUNTIME_DIR` and `/run/user/<uid>`); without one, the state dirs' secrets only. Leaves alone anything it cannot prove orphaned. |
| `riotbox-core egress-list --engine <engine> --state-root <dir>` | For each running session: its name, then `started:` (its proxy's start, local time), `owner:` (`PID <n>` of the launch), one `project:` line per recorded project dir, `log:` and the access log path, `strict:` and the strict setting it enforces with its source (`on (user conf)`, `off (default)`; `unknown` for a session an older release started or an unrecognised record), one `inject:` line per injected key (`VARIABLE → host`, never a value), and one `allow:` line per entry it enforces. Each value is `unknown` when the engine or the session did not record it; paths are quoted as `printf %q` would when they hold unsafe bytes. `No egress sessions are running.` when none. A `projects.json` or injection record that cannot be read shows `project: unreadable` or `inject:  unreadable`, says why on stderr, and does not fail the list. |
| `riotbox-core egress-allow\|egress-deny … [--session <name>] [--save-to <file>] [--] <entry \| @group>` | Records the entry or group in the session overlay (a group as its reference, re-resolved at every reload; the changed line goes last, so the latest command wins) and applies it live, under the session's lock, undoing the overlay change if the reload fails. Without `--session` it acts on the only running session, and fails when there are none or several. An `@group` no file or built-in defines is refused before anything changes. `--save-to` also writes it into that conf file's last `[allow]` section, replacing any line for it. `deny` notes each host (each member, for a group) a wildcard still allows. An empty `--session` is a usage error (exit 2); a leading `-` is refused. |
| `riotbox-core egress-reload … [--session <name>]` | Re-reads the conf files into the named session, or into every running one. Exit 1 if any failed; the others are still reloaded. |
| `riotbox-core egress-strict … [--session <name>] [--save-to <file>] [--] on\|off\|clear` | Sets (`on`, `off`) or removes (`clear`) the session overlay's strict setting and applies it live, as `egress-allow` does, printing `egress: <name>: strict <on\|off> (<source>)`. Prints the lock-out warning on stderr whenever the session is left strict without all of `@agent`, `clear` falling back to a strict conf file included. `--save-to` writes `strict = on\|off` into that file's preamble, replacing any strict line, or with `clear` removes it. Any other positional is a usage error (exit 2). |
| `riotbox-core egress-groups --engine <engine> --state-root <dir> --system-conf <file> --user-conf <file> [--os-dir <dir>]` | Prints every group, sorted, as `@name (<source>)` (`built-in`, `os`, `system conf`, `user conf`) and one indented host per line, references expanded; `@agent` once per running session as `@agent (<session>)` with that session's agent hosts, or `@agent (per session)` when none runs. Exit 1 when a conf file does not resolve, an OS plugin in `--os-dir` is invalid, or the engine cannot list sessions. |

## Calling it from bash

- Call it only through an adapter that runs `riotbox_core_require` first and
  then `"${RIOTBOX_CORE}" <verb> [--option <value>]... -- "$@"`, as
  `session_key` and `compute_multi_project_identity` in
  `scripts/mount-projects.sh` do. Every adapter passes the engine and the
  `.jq` directory as options and puts `--` before the positionals, so a path
  that starts with `-` is never read as an option. The
  require check fails with a fix hint when the binary is missing, not
  executable, exits non-zero, or prints a version other than the app tree's
  `VERSION`. A binary from another release would compute keys by that
  release's rules. `install.sh --binary` from a checkout ahead of its release
  is how that pairing would happen, so it refuses a git checkout that is not
  exactly the commit tagged `v<VERSION>` with clean tracked files.
- Capture the output with `x="$(adapter …)" || return 1`. Read it through a
  process substitution (`< <(...)`) only when the output holds NULs, which a
  command substitution drops, and then check `wait "$!" || return 1` right
  after: the redirection itself ignores the command's exit code, so without
  the `wait` a refused or failed binary would look like empty output.
- The check runs on every call. The adapters run inside command substitutions,
  so a cache in a shell variable would never be reused.
- A verb that prints text a container chose takes `--lib-dir`, and the adapter
  passes `"${_RIOTBOX_CORE_ROOT}/scripts/lib"`, where `terminal-clean.jq`
  lives. The binary does not look for the filter on its own.
- `is_session` is the one adapter without the require check. The session
  commands call it once per directory, and `libexec/list-sessions.sh`,
  `remove-session.sh` and `reset-session.sh` run `riotbox_core_require` once,
  before their loops, instead; `migrate-session.sh` has passed it in
  `resolve_projects` by the time it asks. Without that, a missing or mismatched binary
  would make every directory read as "not a session": `session-list` would
  report no sessions and exit 0. A new caller of `is_session` must run the
  check first too. A binary that cannot run still makes `is_session` return
  non-zero, so nothing is ever taken for a session.

`riotbox doctor` runs the same check (`preflight_check_riotbox_core` in
`scripts/preflight.sh`) and reports a failure as
`riotbox-core matches this install`, exit code 25.

## Why `legacy_session_key` is still bash

`legacy_session_key` reproduces the keys of releases before 0.6 so that
`migrate_session_key` can pass them to `riotbox-core migrate-key`, which finds
and moves their sessions. Its output depends on
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

## The one deliberate difference in session keys

`Key` and `Identity` match v0.7.0's bash byte for byte with one exception: a
newline in the basename of a set's bytewise-first path. v0.7.0 sanitized that
basename with sed, which works line by line, so the newline survived and split
`compute_multi_project_identity`'s three-line output. Go maps the newline to `-`
like any other disallowed byte. Such a set gets a new key, and a v0.7.0 session
for it is not found under that key. A newline in a single project's path, or in
a later member of a set, still produces v0.7.0's key.

## Differences from the bash it replaced

Every other ported function matches the bash it replaced in messages, return
codes and resulting trees, except for the deliberate differences below. Most
of them are security fixes; the rest are display details.

Security fixes and stricter checks:

- Names a container chose are cleaned before printing. The migration's
  warning for each entry under a moved `overlay/` that is not a real directory,
  and the first line of the headroom notice, printed the overlay name raw, so a
  planted name could carry terminal escape sequences. They now go through
  `terminal-clean.jq`, with each newline shown as `?` so the name stays on its
  line. When `jq` is missing or fails, the line shows `(name not shown)` and
  says why; the entry is still removed. The commands in the notice quote the
  path, as before. Mount sources get the same treatment
  (`display.CleanName`) in the running check's `ERROR: container … mounts`
  lines and in `overlay-scan`'s sharer records, which the overlay commands'
  sharer warning prints: a container can shape the path a source resolves to
  through links in a directory it writes, and the bash printed it raw.
- An overlay tree that cannot be listed is an error. After moving a legacy
  `overlay/`, the cleanup removes every child that is not a real directory.
  When the container had made the tree unlistable (mode 0300, say), the bash's
  `find` failed, nothing was removed, and the pair was recorded as done, so
  planted links stayed in trusted state. `migrate-state` now says what to fix
  and exits 1, leaving the pair unrecorded until a later run can clean it.
- Symlink expansion is capped at 40 links. A link that grows the path it
  expands to (`q -> q/../q`) makes GNU `realpath -m` loop forever, so a
  container with a read-write mount could hang every command that runs the
  running check. `realpath.Canonical` follows at most 40 links, Linux's
  `MAXSYMLINKS`, then fails with `ELOOP`, and the callers fail closed. A path
  that needs more links than that cannot be opened by any process.
- A path that cannot be checked counts as present. Before a move, an
  `lstat` error other than "does not exist" (`EACCES` on a parent, say) means
  something may be there, so the move is refused as when both copies exist.
  The bash's `[[ -e || -L ]]` took such a path as absent.
- The check for data left in a legacy dir neither follows a link nor blocks.
  The bash listed the dir with `find -mindepth 1 -maxdepth 1` after its `-d`
  test; the port opens it itself, with `O_DIRECTORY|O_NOFOLLOW`
  (`listsEntries` in `internal/migrate/fs.go`). A FIFO or link the container
  swaps in after the `lstat` makes that open fail at once and counts as no
  data, so it can neither hang every later launch of the session behind
  `.migrate.lock` nor have a link's target listed, as a plain `open` would.
- `migrate-key` refuses a `--legacy-key` that is empty, `.`, `..` or contains
  `/`, before touching anything: a one-line reason, the usage text, exit 2.
  The bash computed the key itself and never checked it; the binary takes it
  as an argument, so the check stops a direct caller from pointing the move at
  the data dir itself or outside it. The rule is `valid_session_key`'s.
- The migrate lock's descriptor is close-on-exec. A child that outlives
  the caller cannot keep the lock. A `flock` error other than contention is
  returned, where the bash would have waited.

Display:

- Paths in printed commands are quoted in the C locale. The `mv -T`,
  `diff -rq`, `rm -rf`, `cp -a` and `git -C` lines in migration warnings and the
  headroom notice used bash's `printf %q` in the user's locale. `display.Quote`
  always quotes as `LC_ALL=C printf %q` does, which is what `quote_words`
  already did, so a non-ASCII path prints as `$'caf\303\251'` rather than
  `café`. Pasted back, it is the same path.
- Enumeration is in byte order. `migrate-all` takes sessions, and the
  headroom notice takes overlay uppers, in bytewise name order. The bash glob
  sorted by the caller's `LC_COLLATE`, so under a locale other than C the
  messages could come in another order, and so could which sessions ran before
  one that failed.

Two things look like they could have changed and did not. Moves still run
`mv -T --`, not `rename(2)`: a state dir the user linked to another disk makes
`rename(2)` fail with `EXDEV`, where `mv` copies. Removals of entries that are
not directories use `unlink(2)` with no `rmdir` fallback, as `rm -f` did.

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

### Differential specs

Some ports are pinned to the program they replace by running both.
`internal/display` checks `Quote` against bash's `LC_ALL=C printf %q` on every
byte from 1 to 255 (alone, first, inside a word, after `:` and after a tab) and
on a set of awkward words, and `CleanLines` against bash's `terminal_clean
line`. `internal/realpath` checks `Canonical` and `Lexical` against GNU
`realpath -m` and `-ms`. These suites need bash, `jq` and GNU `realpath` on the
host that runs `task go:test`.

Venom cases that called a bash function now inside `riotbox-core` (the
migration, the key move and the running scan) were rewritten as Ginkgo specs
covering the same scenarios. Each symlink and race defence in `internal/migrate`
has a spec that fails when the defence is removed.

### Venom suites and helpers

`tests/riotbox-core.venom.yml` covers the bash side: the adapters
delegate to the binary; a missing, mismatched, non-executable or failing
binary is refused; `resolve_projects` stops instead of using an empty key;
preflight exits 25. `tests/session-commands.venom.yml` checks that each
session command fails once, with the fix hint, without a usable binary.
`tests/install-rootless.venom.yml` and `tests/setup.venom.yml` cover the
install flags. They use these helpers in `tests/lib/`:

| Helper | Purpose |
|---|---|
| `go-stub.sh` | A fake `go` that answers `go build … -o <out>` by copying the host-built binary, or fails the way a too-old Go does. The test image has no Go toolchain |
| `fake-release.sh` | Fake `curl` and `cosign` that serve a release from a local directory, with variants for a duplicated checksum line, a missing member and a symlink member, and a configurable `cosign version`. Real Sigstore verification happens only against a real release |
| `answer-prompts.sh` | Drives `setup.sh`'s interactive prompts, answering `[b/r]` and taking each y/n default. `ANSWER_PROMPTS_TIMEOUT` (default 60 seconds) bounds a run |
| `libexec-glob-coverage.sh` | Fails when a `libexec/` entry is not a top-level `*.sh` file |
| `engine-stub.sh`, `engine-stub/podman` | A fake container engine. `install_stub_engine` points `CONTAINER_CMD` at the executable `engine-stub/podman`; the `STUB_*` variables documented in `engine-stub.sh` set which containers run and what they mount. It is an executable, not a shell function, because `riotbox-core` runs the engine itself. It is committed in the tree because `/dev/shm`, which the whiteout cases use, is mounted `noexec`, and named `podman` because overlay mode refuses any other engine |

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
