# How host config protection works

Maintainer-facing reference for `scripts/lib/host-config.sh`: why the host
config is guarded and what each function guarantees.

- **Using it** → [README § Config file security](../../README.md#config-file-security)
- **Its place in the threat model** → [THREAT_MODEL § Host config](../../THREAT_MODEL.md#host-config-sourced-as-bash)

## The problem

`$XDG_CONFIG_HOME/riotbox/config` and `$RIOTBOX_SYSCONF_DIR/config` are bash
that riotbox sources as the user. The agent also runs as the user, so any
path where it can write one, or move a name on the way to one, is code
execution on the host at the next launch. Two gaps, two functions.

## `riotbox_config_vet`

Called by the five sourcers: `libexec/launch.sh`, `libexec/hub.sh`,
`scripts/preflight.sh`, `scripts/mount-projects.sh` and
`scripts/detect-mounts.sh`. `tests/host-config.venom.yml` checks that each calls
it and sources no config path except through a loop over
`RIOTBOX_CONFIG_FILES`.

- It sets `RIOTBOX_CONFIG_FILES` to the resolved paths and the **caller**
  sources them. A `source` inside the function would define the config's
  variables in the function's scope, not the caller's.
- `_config_walk` resolves the path component by component, as the kernel
  does (absolute link target restarts at `/`, `..` pops the resolved
  directory, 40 links at most). `realpath` is not used: it resolves `..`
  lexically in `-s` mode and diverges from the kernel.
- It checks the real file, the directory holding it, **and the directory
  holding every link on the path**. A link in a group-writable directory
  lets its writer repoint it at a config of their own, so the target's
  directory alone is not enough.
- Check-then-source is one race window. Every path checked is owned by the
  user or root and not group/other-writable, so only they could win it.
- Ancestors above those directories are not checked (a writable `/home`
  could rename a directory in it). Accepted, and listed in the threat model.

## `config_protect_mounts`

Called once in `libexec/launch.sh`, after `agent_bind_mounts`'s inputs
(`PROJECT_VOLUME_FLAGS`, `MOUNTS`, `CREDFILE_FLAGS`, `RIOTBOX_EXTRA_ARGS`)
are final. It sets `CONFIG_PROTECT_FLAGS`.

- **Reaching.** `F` is the config's real file, `P` its directory. A mount
  reaches `F` when its real source is `P` or inside it, or holds `F`, a
  directory the walk passed through or a link it met.
- **Pins, not a lone read-only bind.** A read-only bind of `P` alone lets the
  agent rename a directory above `P` and recreate `P` at its host path
  (verified on podman, 2026-11-17). A mount point cannot be renamed, so each
  walked directory under the source is bind-mounted onto itself, outermost
  first, and `P` gets `readonly`. Dotfile links work because the walk's
  directories include the link target's.
- **Skipped destinations.** A destination an agent mount already uses is
  skipped: it is a mount point already and podman refuses a duplicate.
- **Refused, not protected.** A read-write mount holding a link on the path
  (the agent could repoint it), or `P` or anything in it; an overlay
  `upperdir`/`workdir` that could hold the path (podman writes there); a
  `--mount` that `mount_unreadable_why` flags (quoted field, `volume-opt`,
  `type=glob`); a relative config path or a link loop; a walked directory
  that does not exist and cannot be pinned.
- **Elevated launches.** With `RIOTBOX_NESTED=1`, `--privileged` or
  `--cap-add` `SYS_ADMIN`/`ALL` in `RIOTBOX_EXTRA_ARGS`, the agent could
  unmount a pin, so any mount reaching `F` is refused, read-only ones too.
  This mirrors `egress_guard_conf` in `libexec/egress-lib.sh`.
- **Flags.** Emitted as `--mount type=bind,"source=…","destination=…"` with
  CSV quoting, with `readonly` and never `rw`, the spelling Docker's
  `--mount` grammar takes too. Only podman is verified.

## Tests

- `tests/host-config.venom.yml`: unit cases for both functions.
- `tests/bind-mounts.venom.yml`: the parser and `mount_unreadable_why`.
- `tests/config-protect-e2e.venom.yml`: real podman, run by
  `task test:config-e2e`. CI runs it (`.github/workflows/test.yml`).
