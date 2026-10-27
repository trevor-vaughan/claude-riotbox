# OS plugin contract

In an egress session (`RIOTBOX_EGRESS=1`) the agent reaches the network only
through its proxy, which allows HTTPS to the hosts on an allowlist and never
forwards plain HTTP. Stock package-manager configs do not fit: dnf's
metalinks answer with third-party mirrors, many over plain HTTP, and Debian
and Ubuntu fetch over plain HTTP. An OS plugin names its distro's own HTTPS
mirrors as an egress group and points the package manager at them.

## Layout

```text
os/
  registry.sh      discovery, os_detect, os_call, os_hosts, os_resolve
  lib/dnf.sh       os_dnf_set_baseurl (CentOS, Fedora)
  lib/apt.sh       os_apt_https (Debian, Ubuntu)
  <ID>/
    egress-hosts   required: the group @<ID>
    manifest.sh    optional: os_<ID>_repo_rewrite
```

A plugin is a directory holding `egress-hosts`. Its name is the `ID` that
`/etc/os-release` gives the distro, matched exactly; `ID_LIKE` is ignored,
so a derivative (Rocky, Alma, Mint) matches no plugin and keeps its stock
mirrors. Names starting `_` or `.` are skipped, and a symlinked plugin
directory is followed (a dangling link is skipped). A directory with neither
file (`lib/`) is not a plugin; one with `manifest.sh` but no `egress-hosts`
stops every egress launch (`state.LoadOS`).

Every plugin's hosts also join the built-in `@os` (`policy.Groups` builds it
from the OS groups it is given, so it follows a conf's override of one
`@<ID>`); it is opt-in and empty without plugins. A plugin named `os` is
refused (`policy.OSGroup`), as is any built-in's name.

To add a distro: create `os/<ID>/egress-hosts`, and `manifest.sh` if its
stock config needs a change. Nothing else lists the plugins.

## `egress-hosts`

One entry per line (`host`, `host:port`, `*.domain`), the grammar of
`agent.conf`: no settings, sections, `@` references or removals. A
`# Source:` comment above each host cites the vendor page or stock config
file that names it; a host no source names is left out.

`riotbox-core egress-up --os-dir` reads every plugin's file as the group
`@<ID>` (`state.LoadOS`, `policy.OSGroup`) and saves them in the session's
state as `os.conf`, as it saves `agent.conf`. Later commands read the
snapshot and are trusted to find it unchanged: the state root is masked from
the agent. `riotbox egress groups --os-dir` shows the groups with source
`os`. An `<ID>` that is not a group name, is `agent`, or is a built-in
group's name stops the launch, as does an empty or invalid file. A
`[group <ID>]` in an `egress.conf` replaces the plugin's group, as it
replaces a built-in.

## `os_<ID>_repo_rewrite`

```bash
os_<ID>_repo_rewrite() { ... }
```

Points the package manager at the hosts of `@<ID>`, over HTTPS. Runs once
per session start, as root, in the container, from
`scripts/lib/egress-os.sh` (`egress_os_apply`, called by
`container/entrypoint.sh`), and only in an egress session. The helper runs
it directly when the entrypoint is root, else under `sudo -n`; sudo resets
the environment, so the rewrite receives only the registry path and the
plugin name. It must be idempotent, keep everything it does not need to
change, and return non-zero with a message on stderr when it cannot do its
job; the entrypoint then prints `WARNING: egress: ...` and the session
starts anyway. A distro with no plugin also warns and starts. Omit the
function when the stock config already uses only the group's hosts over
HTTPS (`rhel`, `arch`).

Every path a plugin touches is under `${OS_ROOT}`, which tests set to a
fixture tree. A plugin resolves every file it reads or rewrites with
`os_resolve`, which fails when `OS_ROOT` is set and the file resolves
outside it: an absolute symlink would otherwise reach the host's own files.

The shared helpers:

- `os_dnf_set_baseurl [--optional] REPO-ID URL` replaces a dnf repo's
  `metalink=`, `mirrorlist=` and `baseurl=` with one `baseurl=URL`, editing
  the `.repo` file directly (dnf4 and dnf5 `config-manager` differ). A
  header with trailing blanks or a CR still matches. A symlinked `.repo`
  has its target rewritten and the link kept. A missing repo is an error
  unless `--optional`.
- `os_apt_https HOST...` switches `http://HOST/` to `https://HOST/` in
  `sources.list` and every `sources.list.d/*.list` and `*.sources`. It
  refuses, changing nothing, with no host or an empty one, with no sources
  file, and without a non-empty `/etc/ssl/certs/ca-certificates.crt`
  (resolved with `os_resolve`): apt cannot verify HTTPS without a CA
  bundle, and the stock Debian and Ubuntu images have none. The files are
  rewritten one by one, so a failure part-way leaves the earlier ones
  rewritten.

## The plugins

| ID | `@<ID>` | Rewrite |
|---|---|---|
| `centos` | `mirror.stream.centos.org`, `dl.fedoraproject.org` | `baseos`, `appstream`, `crb`, `extras-common` to `mirror.stream.centos.org`; `epel` (once `epel-release` is installed) to `dl.fedoraproject.org` |
| `fedora` | `dl.fedoraproject.org` | `fedora`, `updates` to `dl.fedoraproject.org` |
| `rhel` | `cdn-ubi.redhat.com`, `cdn.redhat.com` | none |
| `debian` | `deb.debian.org`, `security.debian.org` | apt sources to HTTPS (needs `ca-certificates`) |
| `ubuntu` | `archive.ubuntu.com`, `security.ubuntu.com`, `ports.ubuntu.com` | apt sources to HTTPS (needs `ca-certificates`) |
| `arch` | `geo.mirror.pkgbuild.com`, `fastly.mirror.pkgbuild.com` | none |

## Limits

- A rewritten dnf repo no longer checks `repomd.xml` against the metalink's
  checksum; packages stay GPG-checked, and TLS to the project's own mirror
  stands in for the metalink.
- Fedora moves releases past end of life to `/pub/archive/`, which the
  rewrite does not cover.
- The project mirrors serve every session, with no choice by location.
- Containers the agent starts with nested podman are not rewritten.

## Tests

`tests/egress-os.venom.yml` (registry, each rewrite against fixture trees,
the entrypoint helper), `internal/egress/state/os_test.go` and
`internal/egress/policy/os_test.go` (loading and the group table), and the
OS cases of `tests/egress-e2e.venom.yml` (each distro's package manager
through its group alone on real podman and Envoy, with a control).
