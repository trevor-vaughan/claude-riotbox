# Socket mode — manual end-to-end walkthrough

Socket mode (`RIOTBOX_SOCKET=1`) bind-mounts the host's podman API socket
into the agent container. In-container `podman` calls then run against the
host engine, which means the host's image cache, registry auth, and running
containers are visible to the session. The automated suite at
`tests/socket.venom.yml` covers the flag-builder helper and the launch-time
guards, but it cannot exercise a real host socket. This walkthrough is the
manual gate that has to pass on a real machine before the feature is
declared healthy.

Run these tests once after any change to `libexec/socket-vars.sh`,
the socket-related `launch.sh` wiring, or the `session:socket-*` recipes in
`Taskfile.yml`. They take about 10 minutes total on a warm machine.

## Prerequisites

- A Linux host with rootless podman 5.x or newer. Confirm with
  `podman --version`.
- The user-level podman socket enabled and running:
  ```bash
  systemctl --user enable --now podman.socket
  loginctl enable-linger "$USER"   # keeps it up across logouts
  ```
- The RiotBox container image built:
  ```bash
  riotbox build
  ```
  Confirm the image is present: `podman images | grep riotbox`.
- The `riotbox` launcher on `PATH` (see README.md §Setup), or
  invoke the equivalent `./bin/riotbox socket-*` commands from a repo clone.

## Setup verification

Before any test, prove the host side is healthy. From a normal terminal on
the host (no RiotBox container running):

```bash
podman --url "unix://${XDG_RUNTIME_DIR}/podman/podman.sock" info
```

The command must succeed and print the host engine's `graphRoot`,
`runRoot`, and version. If it fails with "connection refused" or "no such
file", stop here — the socket unit is not running, and every test below
will fail.

## Test 1: positive smoke

Goal: confirm in-container `podman` is talking to the host engine.

```bash
RIOTBOX_SOCKET=1 riotbox shell
# (equivalently: RIOTBOX_SOCKET=1 riotbox socket-shell)
```

On first launch inside a git repo, RiotBox prompts for a session-branch
name (`Create session branch 'riotbox/...'?`). Either answer the prompt or
prefix the command with `SESSION_BRANCH=0` to skip it for these smoke tests.

Inside the container:

```bash
podman info | grep -E "graphRoot|runRoot| kernel:"
podman pull alpine:latest
```

`graphRoot` and `runRoot` should point at the host user's
`~/.local/share/containers/storage` and `${XDG_RUNTIME_DIR}/containers`,
not at any container-local path.

Exit the container, then on the host:

```bash
podman images | grep alpine
```

The `alpine:latest` image pulled from inside the container must show up in
the host's image list. That round-trip is the load-bearing proof of socket
mode.

## Test 2: auth pass-through

Goal: confirm registry credentials configured on the host are honored
inside the container without re-login.

On the host, log in to a registry that has a private image you can pull:

```bash
podman login ghcr.io
```

Then enter a socket-mode session and pull the private image:

```bash
RIOTBOX_SOCKET=1 riotbox shell
# inside:
podman pull ghcr.io/<your-org>/<private-image>:<tag>
```

The pull must succeed without prompting for credentials and without
running `podman login` inside the container. If it fails with 401/403,
the auth file is not being reached by the host engine — check
`~/.config/containers/auth.json` on the host.

## Test 3: concurrency

Goal: confirm two socket-mode sessions share state (the headline reason
for socket mode).

Open two terminals on the host. In each:

```bash
RIOTBOX_SOCKET=1 riotbox socket-shell
```

In terminal A:

```bash
podman pull busybox:latest
podman run -d --name socket-test-a busybox:latest sleep 600
```

In terminal B:

```bash
podman images | grep busybox     # busybox is cached, no re-pull
podman ps | grep socket-test-a   # the container is visible
```

Both checks must pass. Clean up from either terminal:

```bash
podman rm -f socket-test-a
```

## Test 4: mutual exclusion

Goal: confirm `RIOTBOX_NESTED=1` and `RIOTBOX_SOCKET=1` cannot both be
set. The guard must fire before any container is started.

```bash
RIOTBOX_SOCKET=1 RIOTBOX_NESTED=1 riotbox shell
echo "exit=$?"
```

Expected: exit code 1, stderr contains the phrase "mutually exclusive",
no container appears in `podman ps`. If the script reaches the run
command and starts a container, the guard has regressed.

## Test 5: no-socket failure

Goal: confirm the failure mode when the host socket is missing is loud
and actionable.

On the host, temporarily stop the user-level podman socket:

```bash
systemctl --user stop podman.socket
```

Then:

```bash
RIOTBOX_SOCKET=1 riotbox shell
echo "exit=$?"
```

Expected: exit code 1, stderr names the missing socket and prints the
exact `systemctl --user enable --now podman.socket` remediation. The
script must not fall back to default mode silently.

Restore the socket before continuing:

```bash
systemctl --user start podman.socket
```

## Test 6: cleanup semantics

Goal: confirm that in-container side effects in socket mode persist on
the host (the same property that makes socket mode useful for caching
also means there is no per-session reset).

```bash
RIOTBOX_SOCKET=1 riotbox shell
# inside:
podman pull hello-world:latest
podman run -d --name socket-persist-test hello-world:latest
exit
```

On the host, after exiting the container:

```bash
podman images | grep hello-world      # still cached
podman ps -a | grep socket-persist-test
```

Both must still be present. Contrast with nested mode (`RIOTBOX_NESTED=1`),
where storage is per-session and these would be gone. Clean up:

```bash
podman rm -f socket-persist-test
podman rmi hello-world:latest
```

## Troubleshooting

- **`podman info` inside the container hangs or returns "permission denied"**
  on the bind-mounted socket. The container UID does not match the socket
  owner. Check `ls -l ${XDG_RUNTIME_DIR}/podman/podman.sock` on the host and
  confirm the launch is running as the same user. SELinux can also block
  this — `journalctl --user -u podman.socket -e` and `ausearch -m AVC -ts
  recent` are the usual entry points.
- **Socket disappears after logout.** Run `loginctl enable-linger "$USER"`
  once. Without it the user systemd manager (and the socket unit) shuts
  down at the last logout.
- **`mutually exclusive` does not appear in Test 4.** The guard in
  `libexec/launch.sh` runs early; if it does not fire, the
  most likely cause is a stale shell sourcing an older copy of the
  script. Re-clone or `git status` to confirm the working tree matches
  `main`.
- **Auth pass-through in Test 2 fails.** The host engine reads
  `${XDG_RUNTIME_DIR}/containers/auth.json` and
  `~/.config/containers/auth.json`. The container does not need a copy.
  If pulls fail, run `podman login` on the host (not inside) and retry.
- **Concurrency in Test 3 shows divergent state.** The two sessions
  should be hitting the same socket. Inside each, `echo
  $CONTAINER_HOST` must print `unix:///run/podman/podman.sock` — if one
  is empty, that session is not in socket mode.
