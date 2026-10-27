# How the egress proxy works

Maintainer-facing reference for `RIOTBOX_EGRESS=1`: what a launch builds, why
the agent cannot get around it, how the allowlist changes while a session
runs, and the invariants a change must keep.

- **Using the feature** → [README § Egress proxy](../../README.md#egress-proxy)
- **Why it was built this way** → [decisions/egress-proxy.md](decisions/egress-proxy.md)
- **Its place in the threat model** → [THREAT_MODEL § Egress proxy](../../THREAT_MODEL.md#egress-proxy-opt-in-feature)

## Where the code is

| Path | What it does |
|---|---|
| `libexec/egress-lib.sh` | The launch side: the gates (`egress_gate`, `egress_gate_mounts`, `egress_gate_env`), start (`egress_start`), the teardown trap, and the pinned image (`RIOTBOX_EGRESS_DEFAULT_IMAGE`) |
| `libexec/egress.sh` | `riotbox egress list\|groups\|allow\|deny\|strict\|reload`: parses the command line and calls the core; `--save` always passes the user `egress.conf` as `--save-to` |
| `cmd/riotbox-core/egress.go` | The nine `egress-*` verbs (see [riotbox-core.md](riotbox-core.md#egress-verbs)) |
| `internal/egress/policy` | Entry grammar (`policy.go`), `egress.conf` grammar (`conf.go`), built-in groups and OS group validation (`groups.go`), resolution (`resolve.go`) |
| `internal/egress/envoyconfig` | Entries and intercepts → Envoy's four JSON files, including the 403 rewrite and the credential hosts' TLS interception; `RenderCredential`, the SDS file of one key |
| `internal/egress/state` | One session's host directory: config files, overlay, logs, lock, the stale-dir rule, the injection's secrets, CA certificate and record, and the OS plugins (`os.go`: `LoadOS`, `os.conf`) |
| `internal/egress/pod` | The engine side: create, wait for readiness, remove, list running sessions, sweep orphans |
| `internal/egress/inject` | Credential injection: the provider table (`providers.go`), `egress-up`'s stdin framing (`input.go`), the inject/pass-through decision and notice (`plan.go`), the per-session CA and leaves (`certs.go`) |
| `os/` | OS plugins: each distro's mirrors as `@<ID>` and the repo rewrite ([os-contract.md](os-contract.md)) |
| `scripts/lib/egress-os.sh` | Runs the distro's repo rewrite at session start (`egress_os_apply`), called from `container/entrypoint.sh` |
| `scripts/lib/egress-trust.sh` | The combined CA bundle for curl and Python (`egress_trust_apply`), called from `container/entrypoint.sh` |
| `agents/<name>/manifest.sh` | `agent_<name>_egress_hosts`, the agent's API hosts ([agent-contract.md](agent-contract.md#agent_name_egress_hosts)) |
| `scripts/lib/egress-prompt.sh` | The egress section of each agent's system prompt (`egress_prompt_apply`, `egress_prompt_apply_shared`), called from each manifest's `container_setup` |
| `scripts/configs/egress.conf` | The commented template installed as the system and user `egress.conf` |

## Topology

One set of objects per launch, named after the agent container `<name>`:

| Object | What | Why |
|---|---|---|
| `<name>-int` | `podman network create --internal --disable-dns` | The agent's only network. No default route and no DNS server; on podman 6.1 it also has no gateway address on the host. |
| `<name>-ext` | a normal bridge network, DNS enabled | Envoy's way out, and its only resolver (its `resolv.conf` lists this network's aardvark-dns alone). The default `podman` network has DNS disabled and the internal network has none, so without this Envoy cannot resolve upstreams (`503`, flag `DF`). |
| `<name>-pod` | `podman pod create --infra=false` | Lifecycle only. Without an infra container the pod shares no namespaces, which is what lets its two members sit on different networks. |
| `<name>-egress` | Envoy, digest-pinned distroless image, on both networks | Listens on `:3128`. No admin interface: nothing uses it, and an allowlisted name that resolves to loopback could reach it. Runs as the invoking user (`--userns=keep-id`), `--read-only`, `--cap-drop=ALL`, `no-new-privileges`, `--ulimit core=0` (it holds injected keys in memory; no core file may write them out), `--log-driver=none`. Config dir mounted read-only, log dir read-write; with injected keys, the secrets dir on the runtime tmpfs read-only. |
| `<name>` | the agent, on `<name>-int` only, in the pod | Gets `HTTP(S)_PROXY` and `http(s)_proxy` = `http://<name>-egress:3128`, `NO_PROXY=localhost,127.0.0.1` (headroom's loopback proxy), `RIOTBOX_EGRESS_SESSION=<name>` (for the [prompt section](#telling-the-agent-about-denials)), `--cap-drop=NET_ADMIN,NET_RAW`, `--dns none` (no `/etc/resolv.conf`), and `--add-host <name>-egress:<ip>`, Envoy's address on `<name>-int` as `podman container inspect` reports it once Envoy is ready, refused unless it parses as an IP literal. |

Every object carries `riotbox.egress=<name>`, `riotbox.session=<key>`,
`riotbox.owner-pid=<launch.sh PID>` and `riotbox.owner-pidns=<PID namespace>`;
Envoy also carries `riotbox.egress-role=gateway`. A session counts as running
while a container with that role label, named `<name>-egress`, runs.
`riotbox egress list` takes each session's start (`StartedAt`) and owner PID
from that container in `podman ps --format json`; the project dirs, which
the engine does not hold apart from the agent's other mounts, come from
`projects.json`.

Tunnels: the route timeout is off (`0s`; the default 15 s would cut a
half-closed tunnel) and the stream idle timeout is one hour (the default five
minutes would cut a quiet model stream).

## The security argument, and what must not change

1. **`--internal` is enforced by routing alone.** On rootless netavark a
   process with `CAP_NET_ADMIN` on an internal network that has a gateway
   address can add a default route via it and reach the internet. With DNS
   disabled, podman 6.1 gives `<name>-int` no gateway address, but other
   versions may, so the boundary is the agent's capability bounding set.
   Neither the normal nor the nested-mode set holds `NET_ADMIN`;
   `--cap-drop=NET_ADMIN,NET_RAW` makes that explicit. The E2E suite proves
   `EPERM` as root and with the nested flags, with a `NET_ADMIN` positive
   control that adds the route (and, where the network has a gateway,
   reaches the internet through it). **Any new flag that grants
   capabilities or networks to the agent in egress mode breaks this.**
2. **The gate refuses what could undo (1) or hand the agent the host engine.**
   `egress_gate` runs before any side effect and refuses docker,
   `RIOTBOX_SOCKET=1` (the agent could start an unrestricted container),
   `RIOTBOX_NETWORK=none`, and these words in `RIOTBOX_EXTRA_ARGS`:
   `--privileged`, `--cap-add`, `--network`, `--net`, `--pod`, `--userns`,
   `--rootfs` (a host root may hold a socket), `--volumes-from`,
   `--init-path` (podman bind-mounts that host file into the agent, and
   RiotBox never sets it), each as `--x` or `--x=v`. It also checks every mount, because a bind-mounted
   engine socket works across network isolation:
   - It reads `RIOTBOX_EXTRA_ARGS` split on whitespace, as `launch.sh` passes
     it to the engine, and finds `-v`/`--volume`/`--mount` in every spelling
     podman accepts: `--x v`, `--x=v`, `-v v`, `-v=v`, `-vVALUE` and grouped
     short flags such as `-itv v` (podman's boolean short flags `d i P q t`
     are skipped).
   - A `-v` source that starts with `/` or `.` is a host path; anything else
     is a volume name. A `--mount` is read as one CSV record: only
     `type=bind` has a host source (`src=`/`source=`); `volume-opt=` (which
     can bind any host path), `type=glob` and any `"` are refused as
     uncheckable.
   - A host source is refused when, resolved with `realpath -m`, it is a Unix
     socket, or is a directory (or a path that does not exist yet, which
     podman would create as one) that is, lies under, or is an ancestor of a
     protected runtime dir: always `/run/user/<uid>`, plus `$XDG_RUNTIME_DIR`
     when it is absolute (a relative value is ignored, as the XDG spec
     requires). A resolved regular file is allowed anywhere, so a credential
     file a secret manager keeps under `$XDG_RUNTIME_DIR` still mounts: a
     file cannot carry a socket. The same rule keeps the injected keys'
     secrets dir (under the runtime dir, see
     [Credential injection](#credential-injection)) out of the agent,
     whether named directly or through an ancestor such as `$HOME`.
   - `egress_gate_mounts` (run from `launch.sh` once `MOUNTS`,
     `PROJECT_VOLUME_FLAGS` and `CREDFILE_FLAGS` exist, before `egress_start`)
     applies the same `-v` check to the mounts RiotBox builds from
     `mounts.conf` (and the fixed auto-detected ones), project directories and
     credential files, naming which one in the error. A relative source
     resolves against `launch.sh`'s cwd, so nothing between the gate and
     `podman run` may change directory.
   - **Known limits, accepted:** a mounted directory elsewhere that contains a
     socket is not caught, nor is a named volume created earlier with a bind
     option. `RIOTBOX_EXTRA_ARGS` is the user's own configuration; the gate
     stops mistakes that would let the agent escape, it is not a sandbox for
     a hostile config.
3. **The agent cannot change its allowlist.** Policy files live on the host
   and are mounted read-only into Envoy only. `~/.config/riotbox`, where the
   user `egress.conf` normally lives, is mounted into the agent read-only.
   The per-session state root (`RIOTBOX_EGRESS_ROOT`, below) holds every
   session's `rds.json`, which Envoy reloads live, and is writable by the
   host user, whom the agent runs as (keep-id). A mount that reaches it
   (`riotbox ~`, a `mounts.conf` entry for `~/.local/share`) would let the
   agent rewrite its own allowlist (issue #48). `egress_mask_data` (run from
   `launch.sh` after `egress_gate_mounts`, before `egress_start`) therefore
   reads every bind mount the agent gets (project volumes, `mounts.conf` and
   auto-detected mounts, credential files, `RIOTBOX_EXTRA_ARGS`, in every
   spelling the gate reads) and, for each whose source's real path is or
   holds the root's real path, adds
   `--mount type=tmpfs,"destination=<dst><rest of the root's real path>",notmpcopyup`
   after all other mounts: an empty tmpfs over the root at that container
   path. A source inside the root is masked whole, at its destination; a
   file inside it is refused, since a tmpfs cannot cover a file, as is a
   `-v … :O` whose `upperdir=` or `workdir=` is in or above the root
   (podman shows the upperdir at the destination and writes to both). Only real
   paths count: a link to the root inside a mount resolves in the
   container, where the target is absent unless another mount reaches it,
   and that mount gets its own mask. Destinations are CSV-quoted (`"`
   doubled), which podman's `--mount` parser accepts with commas and
   newlines in the path, and listed once. Checked on podman 6.1:
   - without `notmpcopyup` podman copies the hidden directory's contents
     into the tmpfs, so the agent could still read every session's config
     and logs (not write them);
   - podman orders mounts by destination, so the mask takes effect whatever
     its place in the argv; it goes last anyway;
   - the tmpfs belongs to the container's root and takes the hidden
     directory's mode (0700), so under keep-id the agent can neither list
     nor write it, nor unmount it (no `CAP_SYS_ADMIN`).
   - **Nested mode is refused instead.** With `RIOTBOX_NESTED=1` the agent
     has `CAP_SYS_ADMIN` (and `unmask=ALL`) in its user namespace, where
     the mask is not `MNT_LOCKED`: it can `umount` the mask, or bind-mount
     the parent elsewhere, and rewrite `rds.json` (reproduced on podman
     6.1). So under nested mode any mount that would need a mask stops the
     launch, before `egress_start`, naming the mount; nested mode with
     mounts that do not reach the root is unaffected.
   `tests/egress-e2e.venom.yml` proves it on real podman with a positive
   control; `tests/egress-launch.venom.yml` covers the mapping.
4. **Values are validated before Envoy sees them** (`internal/egress/policy`):
   printable ASCII checked before lowercasing (Unicode case folding maps some
   non-ASCII letters to ASCII ones), RFC 1123 labels, at least two labels, IP
   literals refused in every form a resolver might read as one (decimal, `0x`
   hex, IPv6), and the JSON produced by `encoding/json`, never by splicing
   text.
5. **Matching keeps the port.** Entries match the CONNECT authority as
   `host:port`; the connection manager must never set
   `strip_any_host_port` or `strip_matching_host_port`, or every entry would
   allow every port (a spec pins this). It speaks HTTP/1 only
   (`codec_type: HTTP1`): cleartext HTTP/2 lets an authority holding
   `; $ ( ' &` into the denial text's `riotbox egress allow` line, which
   HTTP/1's codec refuses (a spec pins this too).
6. **Logs are untrusted.** The proxy can write anything into `log/`. The host
   opens those files refusing links and non-regular files, and reads at most
   1 MiB per line or tail (`state.CountDenied`, `Dir.EnvoyLogTail`); the
   lines it prints are reduced to printable ASCII.
7. **Names, not addresses.** An allowed name can resolve to a private or
   loopback address (DNS rebinding, a wildcard over someone else's DNS);
   Envoy would connect to it, so the agent reaches anything Envoy's rootless
   network namespace can route to: the host LAN, pasta's mapping of the host
   itself, link-local metadata addresses. Not prevented; keep wildcards
   narrow.
8. **The agent has no resolver.** Some aardvark-dns and CNI versions forward
   an internal network's queries for outside names upstream, which would be
   a channel past the proxy (data encoded in the names queried). So
   `<name>-int` is created with `--disable-dns`, the agent runs with
   `--dns none`, and it finds Envoy through the `--add-host` entry in its
   `/etc/hosts`; the proxy URL keeps the name. Only Envoy resolves names, on
   `<name>-ext`. The E2E suite proves the agent has no `resolv.conf`, cannot
   resolve an outside name, and gets no answer from the host's nameservers,
   `<name>-ext`'s resolver, Envoy or the internal network's gateway (when it
   has one), with a positive control on `<name>-ext`.
   **Do not give the internal network DNS or the agent a `--dns` server.**

## Per-session state

`${XDG_DATA_HOME:-~/.local/share}/riotbox-egress/<name>/`, each directory
mode 0700 (`state.Dir.Create` refuses a link in place of the session,
`config` or `log` dir):

| Entry | What |
|---|---|
| `config/` | `bootstrap.json` (LDS and CDS from files), `cds.json` (cluster `egress`, a dynamic forward proxy), `lds.json` (the CONNECT listener, which loads its routes from `rds.json`), `rds.json` (the allowlist). Mounted read-only into Envoy |
| `log/` | `access.log` (one JSON line per request) and `envoy.log` (Envoy's `--log-path`). Mounted read-write; emptied at each start |
| `agent.conf` | The active agent's `egress_hosts` output, saved at start |
| `os.conf` | The OS plugins' groups, loaded from `egress-up --os-dir` at start and saved as `[group]` sections; later commands read them from here. Absent for a session an older release started: it has no OS groups |
| `projects.json` | The launch's project dirs (`egress-up --project`), a JSON list so any path reads back whole; `riotbox egress list` shows them. Absent for a session an older release started, which `list` shows as `unknown` |
| `session.conf` | The overlay `riotbox egress allow\|deny\|strict` writes, in the `egress.conf` grammar: an optional `strict = on\|off` line, then one entry or `@group` line per change, the latest last. No sections |
| `applied.conf` | The allowlist last written to `rds.json`; `riotbox egress list` shows this |
| `applied-strict` | The strict setting last applied, as `list` shows it (`on (user conf)`); absent for a session an older release started, which `list` shows as `unknown`, as it does any value it does not recognise |
| `secrets/` | Only in sessions an earlier build started: the secrets dir now lives on the runtime tmpfs (below). `RemoveSecrets`, and so `egress-down` and the sweep, still delete it |
| `ca.crt` | The session CA's certificate (0600; the agent runs as the owning uid), mounted read-only into the agent at `/run/riotbox-egress/ca.crt`. Its key is never written |
| `injected` | One `VARIABLE host header` line per injected key, never a value. `WriteConfig` and `Reload` render the interception from it; `list` prints it |
| `.lock` | Serialises the commands that change the session |

**The secrets dir is not here.** The proxy's per credential host
`<host>.crt`, `<host>.key` (the leaf and its PKCS#8 EC key) and
`<host>.credential.json` (the SDS generic secret: the whole header value,
prefix included) live in `<runtime>/riotbox-egress/<name>/secrets/`, mode
0700 (as are `riotbox-egress/` and `<name>/`; a link in place of either is
refused or replaced, never written through), files 0600, mounted read-only
into Envoy alone at `/etc/riotbox-egress-secrets`. `state.RuntimeBase`
picks `<runtime>`: `$XDG_RUNTIME_DIR` when absolute, else
`/run/user/<uid>`, the first that is a directory owned by the uid, mode
0700, on tmpfs (`statfs` type `TMPFS_MAGIC`). So the keys are kept on tmpfs
and never written to persistent disk, unless the system swaps them out (use encrypted swap), and the mount gate's runtime-dir rule keeps it from the agent. With
keys to inject and neither qualifying, `egress-up` exits 1 before creating
anything, saying why each was refused; with none, it needs no runtime dir.
`state.Dir.WithRuntime` gives a `Dir` its base; `egress-up` resolves it
afresh, and `egress-down` and `egress-sweep` clean under every candidate
that qualifies (`state.RuntimeBases`), so a launch that saw another
`$XDG_RUNTIME_DIR` is still cleaned up; finding none, they clean only the
state dirs' legacy `secrets/`. The CA certificate and the
`injected` record (public, names only) stay in the state dir. Removed by
`egress-down`, by `Up`'s rollback, and by the sweep (see
[Lifecycle](#lifecycle)), together with `<name>/` when that is left empty.

**Why the allowlist is RDS, not part of the listener:** Envoy swaps a route
configuration with no effect on open connections. A listener change drains
the old listener and closes its connections when the drain time runs out,
which would cut long model streams. So `lds.json` is never rewritten after
start, and a spec pins it byte-identical across policies.

**How a live change lands:** `state.WriteAtomic` writes a temp file in the
config dir and renames it over `rds.json`. Envoy watches the directory
(`watched_directory`) and reloads on the rename. The directory, not the file,
is bind-mounted: inotify does not see a host-side rename over a single-file
bind mount.

## egress.conf grammar

`policy.ParseFile`. Line-oriented; `#` starts a comment, blank lines are
skipped, a trailing CR is ignored. A preamble, then sections:

- **Preamble**: the setting `strict`, `strict = on` or `strict = off`
  (blanks around `=` optional, values lowercase), and `[allow]` lines. A
  file with no sections, as every `egress.conf` was before sections
  existed, is all preamble, so it parses unchanged.
- **`[allow]`**: `host[:port]`, `*.domain[:port]`, `-entry`, `@group`,
  `-@group`, one per line (`policy.ParseItem`). Several `[allow]` sections
  concatenate.
- **`[group NAME]`**: `NAME` matches `^[a-z0-9][a-z0-9-]{0,62}$`; members are
  `host[:port]` or `*.domain[:port]`, at least one, no `-` or `@`.

Every error is `file:line: reason`: an unknown section; an unknown setting
or a `strict` value other than `on`/`off`; a setting after the first
section; an empty group; a group defined twice in one file; `-` or `@` in a
group; `[group agent]`; an invalid entry or group name. An `@name` that no
group defines is caught by resolution, which knows every file's groups.
`agent.conf` and `applied.conf` are plain host lists (`policy.ParseList`:
the same grammar, entries only).

## Resolution

`state.Dir.Policy` gathers the inputs and `policy.Resolve` combines them:

1. **Group table** (`policy.Groups`): the built-ins (`groups.go`, each with
   the vendor documentation its hosts come from), then `os.conf`'s OS
   groups, replaced by the system file's `[group]`s, replaced by the user
   file's; `agent.conf` as `@agent`, which no file may define. `@registries`
   and `@forges` are expanded against the final table, so a user's
   `[group pypi]` changes it too. `@os` is the union of the OS groups'
   members in that final table (a user's `[group centos]` shows in it); it
   is empty without OS plugins, which allows nothing and is not an error,
   and a file's `[group os]` replaces it. It is opt-in, outside
   `@registries`. Only built-ins nest, one level, and none nests `@os`; user
   groups list hosts.
2. **Strict**: `session.conf`'s setting, else the user file's, else the
   system file's, else off (`StrictFrom` records which).
3. **Conf merge**: every addition of the two files, plus `@registries` and
   `@agent` unless strict is on, minus every removal in either file (a
   removal wins whichever file it is in; `-@g` removes each member). A
   removal matches an entry exactly. `agent.conf` holds only the active
   agent's hosts, never the union across agents.
4. **Overlay**: `session.conf`'s lines on top, in file order. `SetOverlay`
   keeps one line per entry or group and puts the changed one last, so the
   latest `allow` or `deny` wins, including re-allowing what a conf file
   removed. An overlay `@g` stays a reference, re-resolved at every reload.
   File order matters because one overlay can both add and remove a host
   (`allow @pypi`, then `deny pypi.org`); see
   [decisions/egress-proxy.md](decisions/egress-proxy.md#amendments-while-the-branch-was-open).

With strict off and no conf files the result is exactly the allowlist
every session had before strict mode existed (a spec pins this). Strict and
groups are decided per session at launch and at every
`allow`/`deny`/`strict`/`reload`, from the files as they are then.

`Resolved.LockoutWarning` is the warning printed when strict mode leaves out
any `@agent` host: by `Up` once the proxy is ready (so it sits next to
`egress_start`'s `egress: session …` line), and by `egress-strict` whenever
the change leaves the session strict, including `clear` falling back to a
strict conf file. It is never a refusal.

`riotbox egress allow|deny|strict` holds the session lock around
(`applyChange`): checking that the conf files resolve (and, for `@g`, that
the group exists), changing the overlay, reloading (`rds.json`,
`applied.conf`, `applied-strict`), and checking that the session still
runs. If the reload or the check fails, it restores the overlay and reloads
again, so a rejected change does not linger.

An overlay `@g` or `-@g` whose group was since deleted from the conf files
fails every resolve; `Dir.Policy` turns that `policy.UnknownGroupError`
into one naming the recovery command. It is never skipped: skipping a
`-@g` would widen the allowlist unasked. The recovery is `forgetGroup`:
`allow`/`deny @g` for an unknown `g` that the overlay names
(`Dir.Dangles`) drops those lines (`DropOverlayGroup`) and reloads instead
of changing anything else. The drop is kept even when that reload fails
(another dangling line): the line could never resolve again, and the proxy
keeps what it last applied. With `--save` it refuses and changes nothing.

## Saving

`--save` (core: `--save-to`) edits a conf file under a lock file beside it
(`state.editConf`), line by line, keeping every other line and comment.
`--save-to` must equal, after `filepath.Clean`, `--system-conf` or
`--user-conf`, the only files checked before anything changes, or the verb
exits 2; the bash CLI always passes the user file.

- `state.SaveItem` drops every line in the preamble or an `[allow]` section
  that names the same entry or group, with either sign, and writes one new
  line, keeping the dropped line's comment. The new line ends the last
  `[allow]` section; a file with only `[group]` sections gets a new
  `[allow]` section at its end; a file with no sections, or no file, gets a
  bare last line. A saved allow therefore undoes a saved deny.
- `state.SaveStrict` drops every `strict` line in the preamble and writes
  one `strict = on|off` line where the first was (keeping its comment), or
  after the file's leading comment and blank lines; `clear` only drops
  them. A missing file is created only to set a value.

## Telling the agent about denials

Clients drop the body of a refused CONNECT: curl prints `CONNECT tunnel
failed, response 403` and nothing else. An agent that sees only that
retries, or tries other hosts, IPs and proxies. Two things tell it better.

**Envoy's 403** (`envoyconfig.localReply`). The HCM's `local_reply_config`
rewrites every 403 the proxy answers; every route that refuses does so
with 403. Two mappers, first match wins, each adding
`x-riotbox-egress: denied %REQ(:AUTHORITY)%` and a `text/plain` body:

- a refused CONNECT (`:method` is `CONNECT`): the authority is not on the
  session's allowlist, it is not a network fault, and the agent should stop
  and ask the user; "If the user agrees after checking the host, they run on
  the host: `riotbox egress allow --session <name> <authority>`";
- any other 403 (plain HTTP, never proxied): use HTTPS; allowing the host
  will not help.

The status is unchanged and the mappers have no `runtime_key`, so nothing
outside the config can change them. `%REQ(:AUTHORITY)%` is chosen by the
client, that is the agent, which is why the text has the user check the
host before running the command. The body holds no secret. The listener
carries the mappers, so they are fixed for the session's life; the session
name comes from `state.Dir`, whose names hold no `%`.

**The system prompt** (`scripts/lib/egress-prompt.sh`). `Up` passes
`RIOTBOX_EGRESS_SESSION=<name>` to the agent; `container/entrypoint.sh`
sources the script before the agents' `container_setup`, and each one calls
one of two functions on the prompt file its agent reads:

| Agent | File | Function | Form |
|---|---|---|---|
| Claude | `${RIOTBOX_MANAGED_POLICY_DIR:-/etc/claude-code}/CLAUDE.md` | `egress_prompt_apply` | Fresh in each container. In egress mode the section names the session; otherwise an old section is stripped. |
| Pi | `~/.pi/agent/AGENTS.md` | `egress_prompt_apply_shared` | Static, session-agnostic text that applies only while `$RIOTBOX_EGRESS_SESSION` is set and tells the agent to pass its value as `--session`. Installed or refreshed at every start, egress or not, and never stripped. |
| opencode | `~/.config/opencode/AGENTS.md` (loaded through `opencode.json`'s `instructions`) | `egress_prompt_apply_shared` | As Pi. |

The shared form exists because Pi's and opencode's files are shared by every
session of a project, which the user runs concurrently: each launch's sync
replaces the file, opencode re-reads it on every model call (verified on
opencode 1.19.3), and Pi's resource loader reloads it at startup and on
`/reload`, `/new`, resume or session switch, and fork (verified on
`@earendil-works/pi-coding-agent` 1.3.0). A per-session section would name the
wrong session, and a normal start stripping it would take it away from an
egress session running beside it.

The section sits between `<!-- riotbox:egress begin -->` and
`<!-- riotbox:egress end -->` lines; both functions remove any such section
before writing. A begin marker with no end marker after it is the user's
text: it is kept, with a warning. A trailing CR is ignored when matching
markers. The new content goes to a temp file beside the target (mode copied)
and is renamed over it, so a link at the path is replaced, not written
through. A link, FIFO or other non-regular file at the path is not read
either (its target could leak into the prompt, a FIFO would block the
start): nothing riotbox does puts one there, so it is replaced by the
section alone, with a warning. `egress_prompt_apply` refuses a `RIOTBOX_EGRESS_SESSION` that is
not a session name, since the name is printed into the prompt. Every
failure is a warning and returns 1; the session still starts and the 403
still explains itself.

## Credential injection

With a provider key in the agent's environment, the session's proxy holds
the key and the agent the placeholder `riotbox-egress-placeholder`
(`inject.Placeholder`; `EGRESS_PLACEHOLDER` in `egress-lib.sh` must equal
it).

**Flow.** `egress_start` takes the `-e NAME` words of `PASSTHROUGH_FLAGS`
(the variables the agent would get from the host, deduplicated) and pipes
them to `egress-up` with `RIOTBOX_HEADROOM`. Stdin framing: the agent's
hosts as text, then one NUL, then NUL-terminated `NAME=VALUE` records,
written with bash's `printf` builtin so no value is ever on a command line.
No NUL means hosts only. `egress-up` reads at most 1 MiB;
`inject.ParseInput` refuses a record without its NUL, one that is not
`NAME=VALUE` with a shell variable name, or a repeated name, naming the
record by number (a repeated one by its name), never by its value, before
anything is created.
`inject.Decide` picks the keys to inject (`inject.Providers`; the base-URL
rule is in its comment) and `Plan.Notice` names the rest in one line on
stderr. `egress-up` unsets the injected names in its own environment, so
the engine commands `Up` runs never inherit a key. `pod.Up` →
`state.Dir.WriteInjection` makes the CA and leaves (`inject.NewCerts`),
writes the secrets dir (on the runtime tmpfs; `egress-up` has already
failed when there is none), `ca.crt` and `injected` before any engine
call, and
the config is rendered from `injected`. The agent's flags gain the CA
mount, `NODE_EXTRA_CA_CERTS` and `RIOTBOX_EGRESS_CA` naming it, and
`-e NAME=riotbox-egress-placeholder` per key. `egress_start` then exports,
for every `-e NAME=VALUE` flag whose name it sent, `VALUE` over `NAME`:
the run command's later `-e NAME` from `PASSTHROUGH_FLAGS` is read from
that environment, so egress's value wins. That covers the placeholders
and also a user-forwarded `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (and
lowercase forms), always, and `NODE_EXTRA_CA_CERTS` when keys are injected
(without them egress-up returns no such flag, so the user's value passes
unchanged). With keys injected, `egress_trust_apply` also overwrites
`SSL_CERT_FILE`, `CURL_CA_BUNDLE` and `REQUESTS_CA_BUNDLE`. **Known limit:**
a corporate or TLS-inspection CA forwarded through any of those four is
then not trusted. Envoy verifies upstream TLS only for the intercepted
credential hosts; every other host is a tunnel the agent's own client
verifies, against the image's roots plus the session CA. So TLS-inspecting
networks are unsupported in egress mode with injected keys.

**The gate on `RIOTBOX_EXTRA_ARGS`.** `egress_gate_env` runs after
`egress_start` (it needs `EGRESS_INJECTED`, the names whose returned
value is the placeholder) and fails the launch, through the EXIT trap
that removes the pod, when `RIOTBOX_EXTRA_ARGS` holds `-e`/`--env
NAME=…` for an injected name (every spelling `_egress_split_args` parses,
grouped short flags included), any `--env-file`, or any `--secret` with
`type=env` (its target defaults to the secret's name, so any could set a
key). Each would replace the placeholder with a value of the user's
choosing. A bare `-e NAME` is allowed: it reads the exported placeholder.
A `--pid` other than `private` (`host`, `container:…`, `ns:…`, either
spelling) is refused too: `launch.sh` is a host process that keeps the real keys in its
environment for the whole session, and an agent in a shared PID namespace,
running as the same uid, could read `/proc/<pid>/environ`. Without
injected keys none of these is refused.

**Limits of the decision and the notice.** `egress-up` sees only the
variables `egress_start` sends: those `PASSTHROUGH_FLAGS` forwards by name.
A variable added by a bare `-e NAME` in `RIOTBOX_EXTRA_ARGS` enters the
container without being named in the pass-through notice, and a base URL
set there (`-e ANTHROPIC_BASE_URL=…`) is not seen by `inject.Decide`: the
key is injected for the provider's host and the agent sends the
placeholder to the other URL, which then fails to authenticate.

**In Envoy.** For each credential host, `lds.json` has an internal listener
`intercept-<host>` (tls_inspector; one filter chain whose `server_names`
is the host, so a tunnel to one credential host cannot reach another's
chain with a different SNI; the leaf; ALPN `h2`, `http/1.1`; an HCM with
`codec_type: AUTO` running `envoy.filters.http.credential_injector` with
the generic credential, `overwrite: true`, reading `<host>.credential.json`
over SDS) and `cds.json` the clusters `intercept-<host>` (the internal
listener) and `upstream-<host>` (`LOGICAL_DNS`, the host on 443 over TLS:
SNI the host, verified against the image's
`/etc/ssl/certs/ca-certificates.crt`, SAN must be the host). The route
pins `host_rewrite_literal` to the host, so a `Host:` header naming
another domain inside the tunnel still reaches the provider (no domain
fronting with the key). The bootstrap gains
`envoy.bootstrap.internal_listener`. `rds.json` routes a CONNECT to
`host:443` into `intercept-<host>`, from a virtual host of its own, only
while the allowlist allows it (exactly or by wildcard); otherwise the host
is denied as before, so `allow`/`deny` turn interception on and off live
while `lds.json` and `cds.json` stay fixed. The outer listener is
unchanged: still HTTP/1 only, still the same access log. The internal
listeners keep no access log, so no log holds a request header and an
upstream 403 is not counted as a denial.

**Certificates.** `inject.NewCerts` makes an ECDSA P-256 CA with critical
name constraints (`PermittedDNSDomains` = the credential hosts, every IPv4
and IPv6 address excluded) and one leaf per host, all valid from 5 minutes
before the start (`CertBackdate`, for clock skew) for 30 days
(`CertValidity`), and drops the CA key: it is never written, and Envoy
needs none because keys are read once and no leaf is signed later. A
session older than 30 days fails TLS to its credential hosts until it is
restarted. A subdomain of a listed host is permitted by RFC 5280, but
nobody holds the key to sign one.

**Trust.** Claude Code and opencode run on Bun, Pi on Node; both add
`NODE_EXTRA_CA_CERTS` to their roots. curl and Python's `ssl`, requests
and httpx take a bundle that replaces their roots, as does headroom
(Python: `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` first, falling back to
`NODE_EXTRA_CA_CERTS`), so `egress_trust_apply` writes the image's bundle plus the CA to
`/tmp/riotbox-egress-ca-bundle.pem` and exports `SSL_CERT_FILE`,
`CURL_CA_BUNDLE` and `REQUESTS_CA_BUNDLE`; a failure is a warning and the
session still starts. The image's system store is root-owned. git is not
pointed at the bundle: forges are tunnelled, not intercepted.

**What was verified** (Envoy 1.40.1, 2026-10-26; the implementation plan
lists the commands): the shape above validates and runs live; the injected
value replaces the agent's header and is added when it sent none; h2 and
HTTP/1.1 both work inside; a mismatched SNI gets no chain; an upstream
verification failure is a 503. Claude Code 2.1.304, opencode 1.19.3 and
Pi 1.3.0 accept the placeholder and trust the CA through
`NODE_EXTRA_CA_CERTS`; curl, Node, Bun and Python reject a leaf for a host
outside the CA's list. `ANTHROPIC_AUTH_TOKEN` is not a row: see
[decisions/egress-proxy.md](decisions/egress-proxy.md#credential-injection-b-2026-10-26).

## Lifecycle

- **Gate** (`launch.sh` → `egress_gate`), before any side effect.
- **Mask** (`egress_mask_data`), after `egress_gate_mounts`: hides the
  state root from the agent wherever its mounts reach it (invariant 3). A
  mount of a file in it stops the launch before the pod starts.
- **Start** (`egress_start`), after every launch check that can abort, so an
  abort leaves nothing to clean up. It requires `riotbox-core` and the agent
  registry, and fails the launch when the agent is unknown or has no
  `egress_hosts` verb. It runs `egress-sweep` (a failure is a warning) with
  every forwarded variable unset (`env -u`) but `XDG_RUNTIME_DIR` and
  `HOME`, which it needs, since it runs before the placeholders replace the
  keys, sets
  the EXIT trap, then `egress-up`: create the state dir, save `agent.conf`
  and `projects.json` (from `PROJECT_DIRS`, one `--project` each), write the
  injection (see [Credential injection](#credential-injection); a failure
  stops the launch before any engine call), write the config, empty the logs, pull the image if absent, create the
  networks, the pod and Envoy, wait for readiness, and print the agent's
  flags. A failed step removes what was created. Once it succeeds,
  `egress_start` prints the session's name on stderr, the name
  `riotbox egress --session` takes. `launch.sh` then runs `egress_gate_env`.
- **Readiness**: `egress-up` polls `envoy.log` for
  `all dependencies initialized. starting workers` (logged once CDS, LDS and
  the listener's RDS are loaded), checking each time that the container still
  runs, for up to 30 s; on failure it prints the log's last 20 lines. It does
  not use `podman logs`: the default log driver varies by host, and journald
  was unreadable in the dev container.
- **Stop**: the EXIT trap (INT exits through it with 130, TERM with 143)
  ignores INT, TERM and HUP and runs `egress-down`, then exits with the
  launch's status. INT and HUP stay ignored in `egress-down`, so a second
  Ctrl-C cannot cut teardown short. Go does not keep an inherited ignored
  TERM, so a TERM still stops `egress-down` and leaves the pod for the next
  launch's sweep. `egress-down` stops Envoy with SIGTERM (so it flushes the
  access log), removes the pod, then each network if it exists
  (`network rm --ignore` is missing from older podman), then the secrets
  dir, and reports denials.
  It carries on past a failed step and is safe to repeat.
- **Sweep** (`egress-sweep`, each egress launch): removes the pods and
  networks of sessions whose owner PID is dead *in the sweeper's own PID
  namespace*. A session is judged over all its objects and spared if any has
  a live owner, an owner in another namespace, or a missing or malformed
  owner label. It is also spared while its agent container (named `<name>`)
  runs in `<name>-pod`, or when the engine cannot list that pod's
  containers: a launch killed with SIGKILL leaves its agent running. So a
  live session is never torn down. An object whose name
  does not match its `riotbox.egress` label is ignored with a warning. State
  dirs of sessions not running whose `envoy.log` (else the dir) is more than
  7 days old are deleted, with their runtime secrets. The secrets of a
  state dir no live session uses, on the runtime tmpfs and any legacy
  `secrets/` in the state dir, are deleted once that dir has been idle for
  an hour (`secretsGrace`, longer than any launch's gap between writing
  secrets and creating its first engine object, image pull included), so a
  session whose engine objects are gone does not keep keys for 7 days. A
  runtime `<name>/` whose state dir is gone, not live, and an hour old is
  deleted too.

A project holding the egress state root (for example `riotbox ~`) would
mount the session's `config/` writable into the agent; `egress_mask_data`
hides the root there (invariant 3, issue #48). That predates credential
injection and never reached the keys: they are on the runtime tmpfs, which
the gate refuses.

## Testing

| Layer | Where | Proves |
|---|---|---|
| Ginkgo | `internal/egress/*`, `cmd/riotbox-core/egress_test.go` | grammar, groups, resolution, section-aware saving, JSON shape (403 rewrite included), state files, engine call sequences and rollback (fake engine) |
| Venom, fake engine | `tests/egress-launch.venom.yml`, `tests/egress-cli.venom.yml` (`tests/lib/egress-fake-engine`) | the gate, flags, trap teardown and signals, the CLI |
| Venom | `tests/egress-os.venom.yml` | the OS plugin registry, each repo rewrite against fixture trees (idempotence, required repos, the CA-bundle refusal, symlinks), the entrypoint helper |
| Ginkgo | `internal/egress/state/os_test.go`, `internal/egress/policy/os_test.go` | loading OS plugins, their refusals, `os.conf`, their place in the group table |
| Venom | `tests/egress-manifests.venom.yml` | every registered agent declares well-formed `egress_hosts` |
| Venom | `tests/egress-prompt.venom.yml` | the prompt section: both forms, append once, strip, CRLF, unmatched markers, links, FIFOs, failures, each agent's `container_setup` |
| Ginkgo (`e2e` label) and Venom, real podman | `task test:egress-e2e`; a step of CI's `test` job on the host runner | the boundary, live reload with an open tunnel, teardown, sweep, strict mode and a live `allow @pypi`, both 403 texts, `RIOTBOX_EGRESS_SESSION` in the agent, `envoy --mode validate` on a static rendering, each distro's package manager through its own group (and not without it) |
| Ginkgo | `internal/egress/inject`, `internal/egress/state/injection_test.go`, `internal/egress/state/runtime_test.go`, `internal/egress/envoyconfig/intercept_test.go` | the provider table (against the agents' `env_vars`), stdin framing, the decision and notice, the CA's constraints and validity, the runtime dir's resolution (each fallback, owner, mode, tmpfs, failure), the secrets layout on it and that the CA key is written nowhere, the interception's JSON shape and that no config file or access log holds a key |
| Ginkgo, fake engine | `internal/egress/pod`, `cmd/riotbox-core/egress_test.go` | `Up` refusing keys without a runtime dir before creating anything, `egress-up` failing so with the actionable message and starting without keys, the secrets mount from the runtime dir, `Down` and the sweep cleaning runtime and legacy secrets, the proxy's `--ulimit core=0` |
| Venom, fake engine | `tests/egress-launch.venom.yml` (injection cases) | the key is in no engine argv, environment (the sweep's included) or the agent's env; the placeholder is, and equals `EGRESS_PLACEHOLDER`; the pass-through notice; no key → nothing intercepted and no runtime dir needed; the `RIOTBOX_EXTRA_ARGS` env and `--pid` refusals; the runtime secrets dir refused as a mount |
| Venom | `tests/egress-trust.venom.yml` | the combined bundle, its failures, and that the entrypoint applies it before the agents |
| Ginkgo (`e2e` label) | `internal/egress/pod/inject_e2e_test.go`, `internal/egress/inject/vouch_e2e_test.go` (part of `task test:egress-e2e`) | the key reaches a public header echo (`postman-echo.com`) in place of the placeholder (curl, Node), a fronted `Host:` still reaches the provider host, plain tunnels elsewhere, the key absent from the agent, clients refusing an out-of-list leaf |

The E2E specs skip unless `RIOTBOX_EGRESS_E2E=1`, which the task sets; with
it set, a missing prerequisite fails rather than skips. The venom test
container cannot create networks, so the E2E suite runs on the host.

## Bumping Envoy

Change `RIOTBOX_EGRESS_DEFAULT_IMAGE` in `libexec/egress-lib.sh` (tag and
digest, from `podman pull` then
`podman image inspect --format '{{.Digest}}'`), and the commented default in
`scripts/configs/config`. Run `task test:egress-e2e`: it reads the image from
`egress-lib.sh`, validates the config with the new Envoy, and fails if the
readiness line changed. The validate spec also renders an interception: a
new Envoy must still ship `envoy.filters.http.credential_injector`,
`envoy.http.injected_credentials.generic`, the internal listener bootstrap
extension and `/etc/ssl/certs/ca-certificates.crt`.
